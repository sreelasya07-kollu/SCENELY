import Foundation

/// Image access for `RfDetr.preprocess`: opaque ARGB (0xAARRGGBB) of pixel (x, y); out-of-range indices are clamped by the caller.
public protocol SegImage {
    var w: Int { get }
    var h: Int { get }
    func argb(_ x: Int, _ y: Int) -> UInt32
}

/// Host math of RF-DETR-Seg Nano (litert-community/RF-DETR-Seg-Nano-LiteRT, ADR 0035), all pure so it is host-tested on synthetic
/// tensors. The two graphs only do the network; the proposal grid, the top-100 gather, the reference-point reparametrisation, the
/// thresholding and the NMS run here. Image [1,3,312,312] RGB, /255, ImageNet mean/std, NCHW. Port of the Kotlin RfDetr (ADR 0037).
public enum RfDetr {
    public static let side = 312
    public static let grid = 26
    public static let cells = grid * grid          // 676
    public static let classes = 91                 // index = COCO category id (0 unused)
    public static let queries = 100
    public static let mask = 78
    public static let dim = 256
    public static let embed = 384

    // Float counts of every graph buffer (converter slot order is arbitrary: the device code resolves slots by these).
    public static let nImage = 3 * side * side
    public static let nClsPos = embed
    public static let nPosPatch = cells * embed
    public static let nEncClass = cells * classes
    public static let nEncDelta = cells * 4
    public static let nMemory = cells * dim
    public static let nRef = queries * 4
    public static let nQueryFeat = queries * dim
    public static let nBoxes = queries * 4
    public static let nLogits = queries * classes
    public static let nMasks = queries * mask * mask

    /// Default thresholds (guesses; tune on device): sigmoid score, per-class NMS IoU, max instances per run.
    public static let scoreThreshold: Float = 0.4
    public static let nmsIou: Float = 0.5
    public static let maxInstances = 20

    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]

    /// Little-endian float32 values of a host constant (.bin); nil when the size is not exactly `count` floats.
    public static func loadFloats(_ bytes: [UInt8], count: Int) -> [Float]? {
        if bytes.count != count * 4 { return nil }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let b = UInt32(bytes[4 * i]) | UInt32(bytes[4 * i + 1]) << 8 | UInt32(bytes[4 * i + 2]) << 16 | UInt32(bytes[4 * i + 3]) << 24
            out[i] = Float(bitPattern: b)
        }
        return out
    }

    /// Slot of each wanted float count among buffers of the given float counts (converter slot order is arbitrary, so slots are
    /// resolved by size). Each wanted count takes the first not yet used buffer with exactly that count. Nil when one finds no slot.
    public static func resolveSlots(bufferCounts: [Int], wanted: [Int]) -> [Int]? {
        var used = Set<Int>()
        var out: [Int] = []
        for w in wanted {
            guard let i = bufferCounts.indices.first(where: { !used.contains($0) && bufferCounts[$0] == w }) else { return nil }
            used.insert(i); out.append(i)
        }
        return out
    }

    /// Quarter turns (clockwise, 0..3) that make the sensor-oriented image upright, from where the image +x axis points on screen
    /// (`dxView`, `dyView`, view y down): right = 0, down = 1, left = 2, up = 3.
    public static func quarterTurns(dxView: Float, dyView: Float) -> Int {
        abs(dxView) >= abs(dyView) ? (dxView >= 0 ? 0 : 2) : (dyView >= 0 ? 1 : 3)
    }

    /// Normalised point (u, v) of the UPRIGHT (rotated clockwise by `turns`) image -> normalised point of the original image.
    public static func unrotate(_ turns: Int, _ u: Float, _ v: Float) -> (Float, Float) {
        switch ((turns % 4) + 4) % 4 {
        case 0: return (u, v)
        case 1: return (v, 1 - u)
        case 2: return (1 - u, 1 - v)
        default: return (1 - v, u)
        }
    }

    /// Camera image -> [1,3,312,312] NCHW into `out` (nearest-neighbour squash of the image rotated by `turns`).
    public static func preprocess(_ img: SegImage, turns: Int, out: inout [Float]) {
        precondition(out.count == nImage)
        let plane = side * side
        for yy in 0..<side {
            for xx in 0..<side {
                let (x, y) = unrotate(turns, (Float(xx) + 0.5) / Float(side), (Float(yy) + 0.5) / Float(side))
                let c = img.argb(min(max(Int(x * Float(img.w)), 0), img.w - 1), min(max(Int(y * Float(img.h)), 0), img.h - 1))
                let i = yy * side + xx
                out[i] = ((Float((c >> 16) & 0xFF) / 255) - mean[0]) / std[0]
                out[plane + i] = ((Float((c >> 8) & 0xFF) / 255) - mean[1]) / std[1]
                out[2 * plane + i] = ((Float(c & 0xFF) / 255) - mean[2]) / std[2]
            }
        }
    }

    /// memory = memory2 * 0.5 (the graph emits it doubled).
    public static func memory(_ memory2: [Float]) -> [Float] { memory2.map { $0 * 0.5 } }

    /// The 100 proposals graph B starts from: `cell` indices and ts = [cx, cy, w, h] per proposal (flat [100*4]).
    public struct Proposals: Equatable {
        public let cell: [Int]
        public let ts: [Float]
    }

    /// Proposal grid G=26 (row-major, cell = gy * 26 + gx): prop = ((gx+.5)/26, (gy+.5)/26); cxcy = delta[:2] * 0.05 + prop;
    /// wh = exp(delta[2:]) * 0.05. The top 100 cells by max class logit (ties: lower cell first), best first.
    public static func proposals(encClass: [Float], encDelta: [Float]) -> Proposals {
        precondition(encClass.count == nEncClass && encDelta.count == nEncDelta)
        var best = [Float](repeating: -Float.infinity, count: cells)
        for c in 0..<cells {
            var m = -Float.infinity
            for k in 0..<classes { m = max(m, encClass[c * classes + k]) }
            best[c] = m
        }
        let order = Array((0..<cells).sorted { best[$0] != best[$1] ? best[$0] > best[$1] : $0 < $1 }.prefix(queries))
        var ts = [Float](repeating: 0, count: nRef)
        for (n, c) in order.enumerated() {
            let gx = c % grid, gy = c / grid
            ts[4 * n] = encDelta[4 * c] * 0.05 + (Float(gx) + 0.5) / Float(grid)
            ts[4 * n + 1] = encDelta[4 * c + 1] * 0.05 + (Float(gy) + 0.5) / Float(grid)
            ts[4 * n + 2] = exp(encDelta[4 * c + 2]) * 0.05
            ts[4 * n + 3] = exp(encDelta[4 * c + 3]) * 0.05
        }
        return Proposals(cell: order, ts: ts)
    }

    /// ref = [rp[:2] * ts.wh + ts.cxcy, exp(rp[2:]) * ts.wh] with rp = refpoint_embed [100,4]; flat [100*4].
    public static func refPoints(ts: [Float], refpointEmbed: [Float]) -> [Float] {
        precondition(ts.count == nRef && refpointEmbed.count == nRef)
        var ref = [Float](repeating: 0, count: nRef)
        for n in 0..<queries {
            let cx = ts[4 * n], cy = ts[4 * n + 1], w = ts[4 * n + 2], h = ts[4 * n + 3]
            ref[4 * n] = refpointEmbed[4 * n] * w + cx
            ref[4 * n + 1] = refpointEmbed[4 * n + 1] * h + cy
            ref[4 * n + 2] = exp(refpointEmbed[4 * n + 2]) * w
            ref[4 * n + 3] = exp(refpointEmbed[4 * n + 3]) * h
        }
        return ref
    }

    public static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// One candidate before NMS, in normalised coordinates of the UPRIGHT image.
    public struct Candidate: Equatable {
        public let query: Int
        public let coco: Int
        public let score: Float
        public let x0: Float, y0: Float, x1: Float, y1: Float
    }

    /// Per query: the best class 1..90 with sigmoid score >= `threshold` and a non-empty box.
    public static func candidates(boxes: [Float], logits: [Float], threshold: Float = scoreThreshold) -> [Candidate] {
        precondition(boxes.count == nBoxes && logits.count == nLogits)
        var out: [Candidate] = []
        for q in 0..<queries {
            var k = 1
            var m = -Float.infinity
            for c in 1..<classes {
                let l = logits[q * classes + c]
                if l > m { m = l; k = c }
            }
            let s = sigmoid(m)
            if s < threshold || LabelMap.cocoName(k).isEmpty { continue }
            let cx = boxes[4 * q], cy = boxes[4 * q + 1], w = boxes[4 * q + 2], h = boxes[4 * q + 3]
            let x0 = min(max(cx - w / 2, 0), 1), x1 = min(max(cx + w / 2, 0), 1)
            let y0 = min(max(cy - h / 2, 0), 1), y1 = min(max(cy + h / 2, 0), 1)
            if x1 - x0 <= 0 || y1 - y0 <= 0 { continue }
            out.append(Candidate(query: q, coco: k, score: s, x0: x0, y0: y0, x1: x1, y1: y1))
        }
        return out
    }

    private static func iou(_ a: Candidate, _ b: Candidate) -> Float {
        let iw = min(a.x1, b.x1) - max(a.x0, b.x0), ih = min(a.y1, b.y1) - max(a.y0, b.y0)
        if iw <= 0 || ih <= 0 { return 0 }
        let inter = iw * ih
        let union = (a.x1 - a.x0) * (a.y1 - a.y0) + (b.x1 - b.x0) * (b.y1 - b.y0) - inter
        return union > 0 ? inter / union : 0
    }

    /// Per-class greedy NMS, best score first; at most `max` survivors overall.
    public static func nms(_ c: [Candidate], iouMax: Float = nmsIou, max maxKept: Int = maxInstances) -> [Candidate] {
        var kept: [Candidate] = []
        for a in c.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.query < $1.query }) {
            if kept.count >= maxKept { break }
            if !kept.contains(where: { $0.coco == a.coco && iou($0, a) > iouMax }) { kept.append(a) }
        }
        return kept
    }

    /// Candidate -> `Instance` in pixels of the ORIGINAL (`w` x `h`) image: box corners are un-rotated by `turns`; the centroid is that
    /// of the mask pixels (logit > 0) inside the box (mask = 78 x 78 over the upright image), the box centre when the mask is empty there.
    public static func toInstance(_ c: Candidate, masks: [Float]?, turns: Int, w: Int, h: Int) -> Instance {
        let (ax, ay) = unrotate(turns, c.x0, c.y0)
        let (bx, by) = unrotate(turns, c.x1, c.y1)
        let box = Box2(min(ax, bx) * Float(w), min(ay, by) * Float(h), max(ax, bx) * Float(w), max(ay, by) * Float(h))
        var cu = (c.x0 + c.x1) / 2, cv = (c.y0 + c.y1) / 2
        if let m = masks, m.count == nMasks {
            let off = c.query * mask * mask
            func clampIdx(_ f: Float) -> Int { min(max(Int(f * Float(mask)), 0), mask - 1) }
            let mx0 = clampIdx(c.x0), mx1 = clampIdx(c.x1), my0 = clampIdx(c.y0), my1 = clampIdx(c.y1)
            var sx = 0, sy = 0, n = 0
            if mx0 <= mx1 && my0 <= my1 {
                for y in my0...my1 { for x in mx0...mx1 where m[off + y * mask + x] > 0 { sx += x; sy += y; n += 1 } }
            }
            if n > 0 { cu = (Float(sx) / Float(n) + 0.5) / Float(mask); cv = (Float(sy) / Float(n) + 0.5) / Float(mask) }
        }
        let (ox, oy) = unrotate(turns, cu, cv)
        return Instance(coco: c.coco, label: LabelMap.cocoName(c.coco), score: c.score, box: box, cx: ox * Float(w), cy: oy * Float(h))
    }

    /// Graph B outputs -> instances (threshold, per-class NMS, un-rotation).
    public static func decode(boxes: [Float], logits: [Float], masks: [Float]?, turns: Int, w: Int, h: Int,
                              threshold: Float = scoreThreshold, iouMax: Float = nmsIou, max maxKept: Int = maxInstances) -> [Instance] {
        nms(candidates(boxes: boxes, logits: logits, threshold: threshold), iouMax: iouMax, max: maxKept)
            .map { toInstance($0, masks: masks, turns: turns, w: w, h: h) }
    }
}
