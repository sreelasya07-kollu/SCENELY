import Foundation

/// One segmented object of one run. `box` is in camera-image pixels, (`cx`, `cy`) is the centroid of its mask (the pixel the
/// 3D centre is cast through). Masks themselves are not kept (never drawn).
public struct Instance: Equatable {
    public let coco: Int
    public let label: String
    public let score: Float
    public let box: Box2
    public let cx: Float
    public let cy: Float
    public init(coco: Int, label: String, score: Float, box: Box2, cx: Float, cy: Float) {
        self.coco = coco; self.label = label; self.score = score; self.box = box; self.cx = cx; self.cy = cy
    }
}

/// One segmentation run: the camera at capture time (for the raycast and the box scaling) and its instances. Never saved to the bundle.
public struct SegResult {
    public let tNs: Int64
    public let camera: CameraSnapshot
    public let instances: [Instance]
    public init(tNs: Int64, camera: CameraSnapshot, instances: [Instance]) { self.tNs = tNs; self.camera = camera; self.instances = instances }
}

public enum LiveState: String { case visible, remembered }

/// Contract C2 (in memory, never recorded): one object of this scan.
public struct LiveObject: Equatable {
    public let trackId: Int
    public let label: String
    public let cocoId: Int
    public let score: Float
    public let boxImg: Box2?
    public let centreWorld: Vec3?
    public let seenCount: Int
    public let firstSeenNs: Int64
    public let lastSeenNs: Int64
    public let state: LiveState

    /// Scanned (ADR 0038): located in 3D and seen at least `LiveObjectTracker.scannedMinSightings` times. Derived, so immutable.
    public var scanned: Bool { centreWorld != nil && seenCount >= LiveObjectTracker.scannedMinSightings }
}

/// One box to draw this frame, in camera-image pixels: `solid` = seen in the last result, else remembered (dashed, "seen" tag).
/// `scanned` = see `LiveObject.scanned` (drawn green with a check, else amber).
public struct DrawBox: Equatable {
    public let trackId: Int
    public let text: String
    public let box: Box2
    public let solid: Bool
    public let scanned: Bool
    public init(trackId: Int, text: String, box: Box2, solid: Bool, scanned: Bool = false) {
        self.trackId = trackId; self.text = text; self.box = box; self.solid = solid; self.scanned = scanned
    }
}

public enum MaskMath {
    /// Image box of a core object's 3D box (footprint w x d rotated by yaw, floor to h), clipped to the image; nil when < 2 corners project.
    public static func objectBox(_ cam: CameraSnapshot, _ o: ObjectBox, floorY: Float) -> Box2? {
        let a = Double(o.yawDeg) * Double.pi / 180
        let ca = Float(cos(a)), sa = Float(sin(a))
        var x0 = Float.greatestFiniteMagnitude, y0 = Float.greatestFiniteMagnitude
        var x1 = -Float.greatestFiniteMagnitude, y1 = -Float.greatestFiniteMagnitude
        var n = 0
        for sx in [Float(-0.5), 0.5] {
            for sz in [Float(-0.5), 0.5] {
                for yy in [Float(0), Float(o.h)] {
                    let lx = sx * Float(o.w), lz = sz * Float(o.d)
                    let p = Vec3(Float(o.x) + lx * ca - lz * sa, floorY + yy, Float(o.z) + lx * sa + lz * ca)
                    guard let uv = cam.project(p) else { continue }
                    n += 1
                    x0 = min(x0, uv.u); y0 = min(y0, uv.v); x1 = max(x1, uv.u); y1 = max(y1, uv.v)
                }
            }
        }
        if n < 2 { return nil }
        let wf = Float(cam.w), hf = Float(cam.h)
        let b = Box2(min(max(x0, 0), wf), min(max(y0, 0), hf), min(max(x1, 0), wf), min(max(y1, 0), hf))
        return b.area > 0 ? b : nil
    }
}

/// Live objects of one scan (ADR 0035): turns each segmentation result into tracks and draws them every frame. Main/AR queue only
/// (the raycast needs the current ARFrame); `objects` / `drawBoxes` are cheap. Identity = `TrackMemory` (same label, 3D centre <= 0.5 m
/// or box IoU >= 0.3, LRU 48), so an object that leaves the view and returns keeps its id.
///
/// Every frame, each track is drawn as follows: with a 3D centre it is projected into the CURRENT camera and drawn with the last box
/// size scaled by lastDepth / currentDepth (a centre behind the camera or outside the image gives no box); without a centre only for
/// `noCentreMs` after its result. A lifted core object box (same class, centre within `coreMatchM`) replaces the box.
public final class LiveObjectTracker {
    /// A track without a 3D centre stays drawn this long after its result.
    public static let noCentreMs: Int64 = 500
    /// A result older than this no longer counts as "seen in the last result" (paused, tracking lost, worker stalled).
    public static let freshMs: Int64 = 1500
    /// Core object box and track match when their centres are this close (metres).
    public static let coreMatchM: Float = 0.6
    /// An object counts as scanned once it was seen this many times and has a 3D centre (ADR 0038).
    public static let scannedMinSightings = 3

    /// Box geometry relative to the centroid pixel, in pixels at the time of the result, plus when it arrived.
    private struct Extra { let halfW: Float, halfH: Float, offX: Float, offY: Float, depth: Double, appliedMs: Int64 }

    private let memory: TrackMemory
    private var extras: [Int: Extra] = [:]
    private var lastIds: Set<Int> = []
    private var lastResultMs: Int64?

    public init(memory: TrackMemory = TrackMemory()) { self.memory = memory }

    /// True once at least one result was applied.
    public var any: Bool { lastResultMs != nil }

    /// Applies one result. `hit` returns the first world hit of the ray (origin, unit direction), or nil; it is called with the ray of
    /// the camera that TOOK the image (`SegResult.camera`), never the current camera. `nowMs` is a monotonic ms clock.
    public func apply(_ res: SegResult, nowMs: Int64, hit: (Vec3, Vec3) -> Vec3?) {
        let prompts: [SegPrompt] = res.instances.map { i in
            let ray = res.camera.ray(i.cx, i.cy)
            let centre = hit(ray.origin, ray.direction)
            return SegPrompt(key: nil, kind: .object, label: i.label, x: i.cx, y: i.cy, box: i.box, centre: centre, cocoId: i.coco, score: i.score)
        }
        let tracks = memory.assign(prompts, tNs: res.tNs)
        for (k, t) in tracks.enumerated() {
            let i = res.instances[k]
            let bx = (i.box.x0 + i.box.x1) / 2, by = (i.box.y0 + i.box.y1) / 2
            let depth = prompts[k].centre.map { res.camera.depthOf($0) } ?? 0.0
            extras[t.id] = Extra(halfW: (i.box.x1 - i.box.x0) / 2, halfH: (i.box.y1 - i.box.y0) / 2, offX: bx - i.cx, offY: by - i.cy,
                                 depth: depth, appliedMs: nowMs)
        }
        let alive = Set(memory.snapshot().map { $0.id })
        extras = extras.filter { alive.contains($0.key) }
        lastIds = Set(tracks.map { $0.id })
        lastResultMs = nowMs
    }

    /// Every remembered track as C2 objects (`.visible` = seen in the last result, which is at most `freshMs` old).
    public func objects(nowMs: Int64) -> [LiveObject] {
        let fresh = lastResultMs.map { nowMs - $0 <= LiveObjectTracker.freshMs } ?? false
        return memory.snapshot().map { t in
            LiveObject(trackId: t.id, label: t.label, cocoId: t.cocoId, score: t.score, boxImg: t.box, centreWorld: t.centre,
                       seenCount: t.seenCount, firstSeenNs: t.firstSeenNs, lastSeenNs: t.lastSeenNs,
                       state: (fresh && lastIds.contains(t.id)) ? .visible : .remembered)
        }
    }

    /// Boxes to draw for the camera `cam` right now. `core` = lifted core objects with `floorY` (nil floor = no core boxes).
    public func drawBoxes(_ cam: CameraSnapshot, nowMs: Int64, core: [ObjectBox] = [], floorY: Float? = nil) -> [DrawBox] {
        var out: [DrawBox] = []
        for o in objects(nowMs: nowMs) {
            guard let ex = extras[o.trackId] else { continue }
            let solid = o.state == .visible
            let text = solid ? "\(o.label) #\(o.trackId)" : "\(o.label) #\(o.trackId) seen"
            var box: Box2?
            if let c = o.centreWorld {
                if let uv = cam.project(c), cam.inImage(uv.u, uv.v, marginFrac: 0) {
                    box = coreBoxFor(o, c, cam, core, floorY) ?? scaled(cam, c, uv, ex)
                }
            } else if nowMs - ex.appliedMs <= LiveObjectTracker.noCentreMs, let b = o.boxImg {
                box = b
            }
            if let b = box { out.append(DrawBox(trackId: o.trackId, text: text, box: b, solid: solid, scanned: o.scanned)) }
        }
        return out
    }

    private func scaled(_ cam: CameraSnapshot, _ c: Vec3, _ uv: (u: Float, v: Float), _ ex: Extra) -> Box2 {
        let d = cam.depthOf(c)
        let s: Float = (ex.depth > 0 && d > 0) ? Float(ex.depth / d) : 1
        let cx = uv.u + ex.offX * s, cy = uv.v + ex.offY * s
        return Box2(cx - ex.halfW * s, cy - ex.halfH * s, cx + ex.halfW * s, cy + ex.halfH * s)
    }

    private func coreBoxFor(_ o: LiveObject, _ c: Vec3, _ cam: CameraSnapshot, _ core: [ObjectBox], _ floorY: Float?) -> Box2? {
        guard let fy = floorY, !core.isEmpty, o.cocoId != 0 else { return nil }
        let cls = LabelMap.coreName(LabelMap.fromCocoCategory(o.cocoId))
        var best: ObjectBox?
        var bestD = LiveObjectTracker.coreMatchM
        for b in core where b.cls == cls {
            let d = c.dist(Vec3(Float(b.x), fy + Float(b.h) / 2, Float(b.z)))
            if d <= bestD { bestD = d; best = b }
        }
        return best.flatMap { MaskMath.objectBox(cam, $0, floorY: fy) }
    }

    public func clear() { memory.clear(); extras.removeAll(); lastIds = []; lastResultMs = nil }
}
