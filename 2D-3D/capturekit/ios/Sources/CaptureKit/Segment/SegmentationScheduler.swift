import Foundation

/// Seam for the model (ADR 0035/0037) so the worker is host-testable. Promptless: every object the model finds. Called on the
/// segmentation queue only. Returns the instances (possibly empty), or nil when the run failed.
public protocol Segmenter: AnyObject {
    var name: String { get }
    func segment(_ image: SegImage, quarterTurns: Int) -> [Instance]?
    func close()
}

/// One run's input: the image, the camera it was taken with and the quarter turns (clockwise) that make the image upright for the model.
public struct SegJob {
    public let tNs: Int64
    public let image: SegImage
    public let camera: CameraSnapshot
    public let quarterTurns: Int
    public init(tNs: Int64, image: SegImage, camera: CameraSnapshot, quarterTurns: Int = 0) {
        self.tNs = tNs; self.image = image; self.camera = camera; self.quarterTurns = quarterTurns
    }
}

/// Runs segmentation off the ARKit queue (ADR 0035/0037; port of the Kotlin SegmentationScheduler, with LATEST-WINS instead of
/// drop-new). `shouldCapture` is asked by ONE thread (the AR delegate queue) for each candidate frame: at most one run per
/// `minIntervalNs / mlRateScale` of frame time (<= 5 Hz at scale 1; a guess, tune on device), only while tracking is normal.
/// `submit` keeps ONE pending job: while a run is in flight a newer job replaces the pending one (the older is a counted, logged drop).
/// The model is opened lazily on the worker by `open` (nil = model missing or GPU not available: the feature turns itself off, no CPU
/// fallback); after `giveUpAfter` consecutive failures the worker disables itself. Identity (TrackMemory) is applied by the consumer on
/// the main queue, where the 3D centre is known. Nothing here blocks the caller.
public final class SegmentationScheduler {
    public static let giveUpAfter = 5
    /// <= 5 Hz at ml_rate_scale 1.
    public static let defaultIntervalNs: Int64 = 200_000_000

    private let open: () -> Segmenter?
    private let sink: (SegResult) -> Void
    private let minIntervalNs: Int64
    private let post: (@escaping () -> Void) -> Void
    private let onDisabled: () -> Void
    private let log: (String) -> Void

    private let lock = NSLock()
    private var lastRunNs = Int64.min     // gate: AR delegate queue only
    private var pending: SegJob?
    private var running = false
    private var closed = false
    private var _disabled = false
    private var droppedCount = 0
    private var processedCount = 0
    private var failedCount = 0
    private var segmenter: Segmenter?     // worker only
    private var opened = false            // worker only
    private var failStreak = 0            // worker only

    /// `post` runs a closure on the worker (a serial queue); the default is a private serial utility queue.
    public init(open: @escaping () -> Segmenter?, sink: @escaping (SegResult) -> Void,
                minIntervalNs: Int64 = SegmentationScheduler.defaultIntervalNs,
                post: ((@escaping () -> Void) -> Void)? = nil,
                onDisabled: @escaping () -> Void = {}, log: @escaping (String) -> Void = { NSLog("CK/Segment: %@", $0) }) {
        self.open = open; self.sink = sink; self.minIntervalNs = minIntervalNs; self.onDisabled = onDisabled; self.log = log
        if let post { self.post = post } else {
            let q = DispatchQueue(label: "dev.capturekit.segment", qos: .userInitiated)
            self.post = { work in q.async { work() } }
        }
    }

    public var dropped: Int { lock.lock(); defer { lock.unlock() }; return droppedCount }
    public var processed: Int { lock.lock(); defer { lock.unlock() }; return processedCount }
    public var failures: Int { lock.lock(); defer { lock.unlock() }; return failedCount }
    public var disabled: Bool { lock.lock(); defer { lock.unlock() }; return _disabled }
    public var busy: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// True when the caller should copy this frame and `submit` it. Counts the call as the run when it returns true.
    public func shouldCapture(tNs: Int64, mlRateScale: Double = 1.0, trackingNormal: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed || _disabled || !trackingNormal || !(mlRateScale > 0) { return false }
        if lastRunNs != Int64.min {
            if tNs < lastRunNs { lastRunNs = tNs; return false }   // clock went backwards: restart the interval
            if tNs - lastRunNs < Int64(Double(minIntervalNs) / mlRateScale) { return false }
        }
        lastRunNs = tNs
        return true
    }

    /// Queues `job` (latest wins). Never blocks. False when closed or disabled.
    @discardableResult
    public func submit(_ job: SegJob) -> Bool {
        lock.lock()
        if closed || _disabled { lock.unlock(); return false }
        var note: String?
        if pending != nil { droppedCount += 1; note = "segmentation busy: older pending frame replaced (total \(droppedCount))" }
        pending = job
        let start = !running
        if start { running = true }
        lock.unlock()
        if let note { log(note) }
        if start { post { [weak self] in self?.drain() } }
        return true
    }

    private func drain() {
        while true {
            lock.lock()
            let job = pending; pending = nil
            if job == nil || closed || _disabled { pending = nil; running = false; lock.unlock(); break }
            lock.unlock()
            runJob(job!)
        }
    }

    private func runJob(_ job: SegJob) {
        if !opened {
            opened = true
            segmenter = open()
            if segmenter == nil { log("segmentation off: model not available"); disable(); return }
        }
        guard let seg = segmenter else { return }
        guard let found = seg.segment(job.image, quarterTurns: job.quarterTurns) else {
            lock.lock(); failedCount += 1; lock.unlock()
            failStreak += 1
            if failStreak >= Self.giveUpAfter { log("segmenter failed \(failStreak) times in a row: disabled"); disable() }
            return
        }
        failStreak = 0
        lock.lock(); processedCount += 1; lock.unlock()
        sink(SegResult(tNs: job.tNs, camera: job.camera, instances: found))
    }

    /// Worker: turns the feature off and tells the host once (it hides the overlay and its chip).
    private func disable() {
        lock.lock()
        if _disabled { lock.unlock(); return }
        _disabled = true
        lock.unlock()
        onDisabled()
    }

    /// Stops accepting work and releases the model on the worker. Idempotent.
    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; pending = nil
        lock.unlock()
        post { [weak self] in
            guard let self else { return }
            self.segmenter?.close(); self.segmenter = nil
        }
    }
}
