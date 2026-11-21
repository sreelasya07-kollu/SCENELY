import Foundation
#if os(iOS)
import CoreVideo
import ImageIO
import Vision
#endif

/// Face redaction v1 (consent redaction_mode "faces"). Port of the Kotlin Redactor (ADR 0037): best effort, in memory, on the
/// pixels right before the JPEG is encoded, so no unredacted keyframe pixels reach disk when it is on. Solid fill, fails closed.
/// The pure part (regions, padding, un-rotation, NV12 fill, the redaction.json log) is host-tested; `FaceRedactor` (Vision) is iOS only.

/// Pixel rectangle, half-open (x0..<x1, y0..<y1), in keyframe (sensor-orientation) pixels.
public struct RedactionRegion: Equatable {
    public let x0: Int, y0: Int, x1: Int, y1: Int
    public init(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
}

public enum RedactionMath {
    /// Solid fill: luma dark, chroma neutral.
    public static let fillY: UInt8 = 0x20
    public static let fillC: UInt8 = 0x80

    /// Grows `r` by `fraction` of its size on every side, clamps to w x h and snaps to even bounds (the half-resolution chroma plane
    /// is then covered exactly). Nil when nothing is left.
    public static func pad(_ r: RedactionRegion, w: Int, h: Int, fraction: Double) -> RedactionRegion? {
        let px = Int(Double(r.x1 - r.x0) * fraction), py = Int(Double(r.y1 - r.y0) * fraction)
        let x0 = max(0, r.x0 - px) & ~1, y0 = max(0, r.y0 - py) & ~1
        let x1 = min(w, (r.x1 + px + 1) & ~1), y1 = min(h, (r.y1 + py + 1) & ~1)
        return (x1 > x0 && y1 > y0) ? RedactionRegion(x0, y0, x1, y1) : nil
    }

    /// Maps a rect found in a base image rotated by `rot` degrees (0, 90 = clockwise, 270 = counter-clockwise; the rotated image is
    /// bh x bw wide x high for 90/270) back to the unrotated base image of bw x bh.
    public static func unrotate(_ rot: Int, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, bw: Int, bh: Int) -> RedactionRegion {
        switch rot {
        case 90: return RedactionRegion(y0, bh - x1, y1, bh - x0)
        case 270: return RedactionRegion(bw - y1, x0, bw - y0, x1)
        default: return RedactionRegion(x0, y0, x1, y1)
        }
    }

    /// A Vision bounding box (normalised, ORIGIN LOWER-LEFT, relative to the image as oriented for `rot`) -> pixel region of the
    /// unrotated `bufW` x `bufH` buffer. Nil when empty after clamping.
    public static func region(visionBox x: Double, _ y: Double, _ w: Double, _ h: Double, rot: Int, bufW: Int, bufH: Int) -> RedactionRegion? {
        let ow = (rot == 90 || rot == 270) ? bufH : bufW
        let oh = (rot == 90 || rot == 270) ? bufW : bufH
        func clamp(_ v: Double, _ hi: Int) -> Int { min(max(Int(v), 0), hi) }
        let ox0 = clamp((x * Double(ow)).rounded(.down), ow), ox1 = clamp(((x + w) * Double(ow)).rounded(.up), ow)
        let oy0 = clamp(((1 - y - h) * Double(oh)).rounded(.down), oh), oy1 = clamp(((1 - y) * Double(oh)).rounded(.up), oh)
        if ox1 <= ox0 || oy1 <= oy0 { return nil }
        return unrotate(rot, ox0, oy0, ox1, oy1, bw: bufW, bh: bufH)
    }

    /// Solid fill of `r` (even bounds) in a bi-planar NV12 buffer: `y` luma plane, `cbcr` interleaved half-height chroma plane.
    public static func fillNV12(y: UnsafeMutablePointer<UInt8>, yStride: Int, cbcr: UnsafeMutablePointer<UInt8>, cStride: Int, _ r: RedactionRegion) {
        for row in r.y0..<r.y1 { (y + row * yStride + r.x0).update(repeating: fillY, count: r.x1 - r.x0) }
        // Interleaved CbCr: one chroma row covers two luma rows and `x1 - x0` bytes cover the same columns.
        for row in (r.y0 / 2)..<(r.y1 / 2) { (cbcr + row * cStride + r.x0).update(repeating: fillC, count: r.x1 - r.x0) }
    }
}

/// What was done to each keyframe, written as privacy/redaction.json (same shape as the Android Redactor).
/// Thread-safe. With `bundleDir` set the json is also rewritten every `flushEvery` entries so a killed session keeps most of them.
public final class RedactionLog {
    public struct Entry: Equatable {
        public let file: String
        public let id: Int
        public let dropped: Bool
        public let regions: [RedactionRegion]
    }

    public static let flushEvery = 10
    public static let failingAfter = 5

    private let detectorName: String
    private let bundleDir: URL?
    private let onFailing: (() -> Void)?
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var failStreak = 0

    /// `onFailing` fires once per streak of `failingAfter` consecutive detector failures.
    public init(detectorName: String, bundleDir: URL? = nil, onFailing: (() -> Void)? = nil) {
        self.detectorName = detectorName; self.bundleDir = bundleDir; self.onFailing = onFailing
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public func record(_ e: Entry) {
        lock.lock()
        entries.append(e)
        if !e.dropped { failStreak = 0 } else {
            failStreak += 1
            if failStreak == Self.failingAfter { onFailing?() }
        }
        let flush = bundleDir != nil && entries.count % Self.flushEvery == 0
        lock.unlock()
        if flush, let d = bundleDir { writeJson(to: d) }
    }

    public func toJson() -> String {
        lock.lock(); defer { lock.unlock() }
        var s = "{\"version\":1,\"mode\":\"faces\",\"best_effort\":true,\"detector\":\(SessionConfigJSON.quote(detectorName))"
        s += ",\"fill\":\"solid\",\"coords\":\"keyframe_pixels_x0y0x1y1\",\"keyframes\":["
        s += entries.map { e in
            let regions = e.regions.map { "[\($0.x0),\($0.y0),\($0.x1),\($0.y1)]" }.joined(separator: ",")
            return "{\"id\":\(e.id),\"file\":\(SessionConfigJSON.quote(e.file)),\"status\":\"\(e.dropped ? "dropped_detector_failure" : "ok")\",\"regions\":[\(regions)]}"
        }.joined(separator: ",")
        return s + "]}"
    }

    /// Writes privacy/redaction.json under `dir`: stale tmp deleted, tmp written and synced, then moved over the target.
    /// Never throws (returns false). Call before finalize.
    @discardableResult
    public func writeJson(to dir: URL) -> Bool {
        let fm = FileManager.default
        let target = dir.appendingPathComponent("privacy/redaction.json")
        let tmp = dir.appendingPathComponent("privacy/redaction.json.tmp")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: nil) else { return false }
            let fh = try FileHandle(forWritingTo: tmp)
            try fh.write(contentsOf: Data(toJson().utf8))
            try fh.synchronize()
            try fh.close()
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: target) }
            return true
        } catch { return false }
    }
}

#if os(iOS)
/// Vision face finder + solid fill on ARKit's bi-planar YCbCr (NV12) buffers. Phones hold the sensor sideways, so the buffer is scanned
/// upright and rotated both ways (Vision orientations .up, .right, .left), like the Android detector. Recall and latency are
/// UNVERIFIED on a device (Mac/iPhone check): the log says best effort. Called from the serial encode queue only.
public final class FaceRedactor {
    public static let detectorName = "Vision.VNDetectFaceRectanglesRequest"

    public let log: RedactionLog
    private let padFraction: Double

    /// Vision face boxes are tight, so the pad is a bit more generous than the Android one (0.15).
    public init(bundleDir: URL?, padFraction: Double = 0.25, onFailing: (() -> Void)? = nil) {
        self.log = RedactionLog(detectorName: Self.detectorName, bundleDir: bundleDir, onFailing: onFailing)
        self.padFraction = padFraction
    }

    /// Redacts faces in `pb` IN PLACE (pass a private copy) and records them. Returns false when the keyframe must NOT be written
    /// (detector or buffer failure: fail closed, recorded as dropped_detector_failure). Never throws.
    public func redact(_ pb: CVPixelBuffer, id: Int, file: String) -> Bool {
        guard CVPixelBufferGetPlaneCount(pb) == 2, let found = detect(pb) else {
            recordDropped(id: id, file: file)
            return false
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let padded = found.compactMap { RedactionMath.pad($0, w: w, h: h, fraction: padFraction) }
        guard fill(pb, padded) else { recordDropped(id: id, file: file); return false }
        log.record(RedactionLog.Entry(file: file, id: id, dropped: false, regions: padded))
        return true
    }

    public func recordDropped(id: Int, file: String) {
        log.record(RedactionLog.Entry(file: file, id: id, dropped: true, regions: []))
    }

    @discardableResult
    public func writeJson(to dir: URL) -> Bool { log.writeJson(to: dir) }

    private func detect(_ pb: CVPixelBuffer) -> [RedactionRegion]? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var out: [RedactionRegion] = []
        for (rot, orientation) in [(0, CGImagePropertyOrientation.up), (90, .right), (270, .left)] {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
            do { try handler.perform([request]) } catch { return nil }
            for obs in request.results ?? [] {
                let b = obs.boundingBox
                if let r = RedactionMath.region(visionBox: Double(b.origin.x), Double(b.origin.y), Double(b.size.width), Double(b.size.height),
                                                rot: rot, bufW: w, bufH: h) { out.append(r) }
            }
        }
        return out
    }

    private func fill(_ pb: CVPixelBuffer, _ regions: [RedactionRegion]) -> Bool {
        if regions.isEmpty { return true }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for r in regions {
            RedactionMath.fillNV12(y: yBase.assumingMemoryBound(to: UInt8.self), yStride: yStride,
                                   cbcr: cBase.assumingMemoryBound(to: UInt8.self), cStride: cStride, r)
        }
        return true
    }
}
#endif
