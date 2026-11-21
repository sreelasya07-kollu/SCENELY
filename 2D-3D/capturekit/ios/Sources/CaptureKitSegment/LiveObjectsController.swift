#if os(iOS) && canImport(ARKit)
import ARKit
import CaptureKit
import Foundation

/// Glue between the capture session, the RF-DETR segmenter and the live-object tracker (ADR 0035/0037).
///
/// Wiring (the SampleApp does this once per scan, before `CaptureSession.start`):
///     let live = LiveObjectsController(arSession: session.arSession, enabled: flags.segmentation)
///     session.segmentationGate = live.gate; session.segmentationSink = live.sink
///     // from CaptureSessionDelegate.didUpdatePolicy: live.mlRateScale = p.ml_rate_scale
///
/// Threads: `gate` / `sink` run on ARKit's delegate queue and only do a rate check, a lock and a queue hop (AGENTS B.8: never block
/// it). The model runs on the scheduler's serial queue. Results are applied to the tracker on the MAIN queue, where the ARKit raycast
/// for each object's 3D centre is made (a world ray through the mask centroid from the camera that TOOK the image, first hit of
/// `.estimatedPlane`, any alignment). `tracker` and its `objects` / `drawBoxes` are main-queue only. UNVERIFIED on a device.
public final class LiveObjectsController {
    public let tracker: LiveObjectTracker
    /// True when the model files are packaged and the feature is on; flips to false when the worker gives up (model/GPU failure).
    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return _active }

    private let arSession: ARSession
    private let lock = NSLock()
    private var _active: Bool
    private var _mlRateScale = 1.0
    private var scheduler: SegmentationScheduler?
    private let onDisabled: () -> Void

    /// `enabled` false or missing model files -> inert (`isActive` false, `gate` always false). Creating it is cheap: the model is
    /// loaded on the worker at the first run. `onDisabled` runs on the main queue when the worker turns itself off.
    public init(arSession: ARSession, enabled: Bool, bundle: Bundle = .main, tracker: LiveObjectTracker = LiveObjectTracker(),
                onDisabled: @escaping () -> Void = {}) {
        self.arSession = arSession; self.tracker = tracker; self.onDisabled = onDisabled
        let on = enabled && RfDetrSegmenter.available(bundle: bundle)
        if enabled && !on { NSLog("CK/Segment: segmentation off: model files not in the app bundle (%@)", RfDetrSegmenter.graphA) }
        _active = on
        if on {
            scheduler = SegmentationScheduler(
                open: { RfDetrSegmenter.open(bundle: bundle) },
                sink: { [weak self] res in DispatchQueue.main.async { self?.apply(res) } },
                onDisabled: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.lock.lock(); self._active = false; self.lock.unlock()
                        self.onDisabled()
                    }
                })
        }
    }

    /// ml_rate_scale of the core policy (0 pauses the model). Any thread.
    public var mlRateScale: Double {
        get { lock.lock(); defer { lock.unlock() }; return _mlRateScale }
        set { lock.lock(); _mlRateScale = newValue; lock.unlock() }
    }

    /// For `CaptureSession.segmentationGate`.
    public var gate: (Int64, Bool) -> Bool {
        { [weak self] tNs, normal in
            guard let self, let s = self.scheduler else { return false }
            return s.shouldCapture(tNs: tNs, mlRateScale: self.mlRateScale, trackingNormal: normal)
        }
    }

    /// For `CaptureSession.segmentationSink`.
    public var sink: (SegmentationFrame) -> Void {
        { [weak self] f in
            guard let s = self?.scheduler, let img = PixelBufferSegImage(f.pixelBuffer) else { return }
            s.submit(SegJob(tNs: f.tNs, image: img, camera: f.camera, quarterTurns: f.quarterTurns))
        }
    }

    /// Monotonic ms clock shared by `objects(nowMs:)` / `drawBoxes(_:nowMs:)`.
    public static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Main queue.
    private func apply(_ res: SegResult) {
        tracker.apply(res, nowMs: Self.nowMs()) { [arSession] origin, dir in
            let q = ARRaycastQuery(origin: SIMD3<Float>(origin.x, origin.y, origin.z), direction: SIMD3<Float>(dir.x, dir.y, dir.z),
                                   allowing: .estimatedPlane, alignment: .any)
            guard let hit = arSession.raycast(q).first else { return nil }
            let c = hit.worldTransform.columns.3
            return Vec3(c.x, c.y, c.z)
        }
    }

    /// Stops the worker and releases the model. Call when the scan ends.
    public func close() {
        scheduler?.close(); scheduler = nil
        tracker.clear()
    }
}
#endif
