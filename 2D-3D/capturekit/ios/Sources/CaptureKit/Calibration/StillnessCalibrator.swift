import Foundation

/// Pre-scan "hold still" measurement (ADR 0036, contract C1). Pure: the shell feeds samples with their `tNs` (one monotonic base,
/// CMLogItem.timestamp * 1e9) from the motion queue; the UI reads `state` / `progress` / `needsTableHint`. Thread-safe (every entry
/// point takes a lock; ~400 calls/s). Port of the Kotlin StillnessCalibrator (ADR 0037).
///
/// iOS mapping of C1 (design choice, axis frame UNVERIFIED on device): `onGyro` takes `CMDeviceMotion.rotationRate` (Core Motion
/// already removed its bias estimate, the analogue of Android's drift-compensated TYPE_GYROSCOPE); the bias recorded is the mean of
/// that over the window. `onRawGyro` takes the raw `CMGyroData.rotationRate`; the platform drift is mean(raw) - mean(deviceMotion)
/// (the analogue of the uncalibrated sensor's drift estimate). `onGyroUncalibrated` accepts a drift estimate directly (parity with
/// Android and its tests). `onAccel` takes m/s^2 (CMAccelerometerData * 9.80665).
///
/// Window rule: the phone must stay still for `windowNs` (2.0 s). Still = gyro RMS <= gyroRmsMax, |mean accel norm - 9.80665| <=
/// accelNormTol, accel norm std <= accelStdMax (all guesses, tune on device), checked on the running window; a single gyro sample
/// above gyroSpikeMax also counts. Any violation restarts the window at the next sample. The bias is only RECORDED, never subtracted.
public final class StillnessCalibrator {
    public struct Config {
        public var windowNs: Int64 = 2_000_000_000
        public var gyroRmsMax: Double = 0.02
        public var gyroSpikeMax: Double = 0.10
        public var accelNormTol: Double = 0.25
        public var accelStdMax: Double = 0.05
        /// After this long without becoming ready the hint asks to rest the phone on a table.
        public var hintAfterNs: Int64 = 10_000_000_000
        /// MOVING stays reported for this long after a violation.
        public var movingHoldNs: Int64 = 500_000_000
        /// Samples per sensor needed before the running statistics are judged.
        public var minSamples: Int = 20
        public init() {}
    }

    public enum State { case holdStill, moving, ready }

    /// The values of contract C1 (rad/s, m/s^2, seconds). `drift` is nil when the platform gives no drift estimate.
    public struct Result {
        public let gyroBias: [Double]
        public let drift: [Double]?
        public let durationS: Double
        public let gyroRms: Double
        public let accelNorm: Double
        public let accelStd: Double

        /// Session config keys `calib.*` for `ck_session_create` (the core records them as capture_settings.stillness_calibration).
        public func toSessionConfig() -> SessionConfig {
            var m = SessionConfig()
            m["calib.gyro_bias_x"] = .double(gyroBias[0]); m["calib.gyro_bias_y"] = .double(gyroBias[1]); m["calib.gyro_bias_z"] = .double(gyroBias[2])
            if let d = drift {
                m["calib.drift_x"] = .double(d[0]); m["calib.drift_y"] = .double(d[1]); m["calib.drift_z"] = .double(d[2])
            }
            m["calib.duration_s"] = .double(durationS); m["calib.gyro_rms"] = .double(gyroRms)
            m["calib.accel_norm"] = .double(accelNorm); m["calib.accel_std"] = .double(accelStd)
            return m
        }
    }

    public static let gravity = 9.80665

    private let startNs: Int64
    private let cfg: Config
    private let lock = NSLock()
    private var windowStartNs: Int64 = -1
    private var ignoreUpToNs = Int64.min   // samples at or before the last violation never join a window
    private var lastViolationNs = Int64.min
    private var lastSampleNs: Int64
    private var result: Result?

    private var gyroN = 0
    private var gyroSum = [0.0, 0.0, 0.0]
    private var gyroSq = 0.0
    private var accN = 0
    private var accMean = 0.0
    private var accM2 = 0.0
    private var driftN = 0
    private var driftSum = [0.0, 0.0, 0.0]
    private var rawN = 0
    private var rawSum = [0.0, 0.0, 0.0]

    public init(startNs: Int64, config: Config = Config()) {
        self.startNs = startNs
        self.cfg = config
        self.lastSampleNs = startNs
    }

    /// Bias-removed rotation rate (CMDeviceMotion.rotationRate; Android: TYPE_GYROSCOPE).
    public func onGyro(_ tNs: Int64, _ x: Double, _ y: Double, _ z: Double) {
        lock.lock(); defer { lock.unlock() }
        if !accept(tNs) { return }
        let sq = x * x + y * y + z * z
        if sq > cfg.gyroSpikeMax * cfg.gyroSpikeMax { violate(tNs); return }
        gyroN += 1; gyroSum[0] += x; gyroSum[1] += y; gyroSum[2] += z; gyroSq += sq
        if gyroN >= cfg.minSamples && (gyroSq / Double(gyroN)).squareRoot() > cfg.gyroRmsMax { violate(tNs); return }
        tryFinish(tNs)
    }

    /// Raw rotation rate (CMGyroData.rotationRate): only its window mean is used, as mean(raw) - mean(onGyro) = platform drift.
    public func onRawGyro(_ tNs: Int64, _ x: Double, _ y: Double, _ z: Double) {
        lock.lock(); defer { lock.unlock() }
        if !accept(tNs) { return }
        rawN += 1; rawSum[0] += x; rawSum[1] += y; rawSum[2] += z
    }

    /// A drift estimate given directly (Android TYPE_GYROSCOPE_UNCALIBRATED values[3..5]); takes precedence over `onRawGyro`.
    public func onGyroUncalibrated(_ tNs: Int64, _ driftX: Double, _ driftY: Double, _ driftZ: Double) {
        lock.lock(); defer { lock.unlock() }
        if !accept(tNs) { return }
        driftN += 1; driftSum[0] += driftX; driftSum[1] += driftY; driftSum[2] += driftZ
    }

    /// Accelerometer in m/s^2 (gravity included).
    public func onAccel(_ tNs: Int64, _ x: Double, _ y: Double, _ z: Double) {
        lock.lock(); defer { lock.unlock() }
        if !accept(tNs) { return }
        let norm = (x * x + y * y + z * z).squareRoot()
        accN += 1
        let d = norm - accMean
        accMean += d / Double(accN)
        accM2 += d * (norm - accMean)
        if accN >= cfg.minSamples {
            let std = (accM2 / Double(accN)).squareRoot()
            if abs(accMean - Self.gravity) > cfg.accelNormTol || std > cfg.accelStdMax { violate(tNs); return }
        }
        tryFinish(tNs)
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        if result != nil { return .ready }
        if lastViolationNs != Int64.min && lastSampleNs - lastViolationNs < cfg.movingHoldNs { return .moving }
        return .holdStill
    }

    /// 0..1: how much of the still window is collected (1 when ready).
    public var progress: Double {
        lock.lock(); defer { lock.unlock() }
        if result != nil { return 1.0 }
        if windowStartNs < 0 { return 0.0 }
        return min(max(Double(lastSampleNs - windowStartNs) / Double(cfg.windowNs), 0), 0.999)
    }

    /// True once `hintAfterNs` have passed since `startNs` without becoming ready ("Rest the phone on a table").
    public func needsTableHint(nowNs: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil && nowNs - startNs >= cfg.hintAfterNs
    }

    /// The frozen measurement once `state` is `.ready`, else nil.
    public func finalResult() -> Result? {
        lock.lock(); defer { lock.unlock() }
        return result
    }

    // MARK: internals (lock held)

    private func accept(_ tNs: Int64) -> Bool {
        if result != nil || tNs <= ignoreUpToNs || tNs < startNs { return false }
        if tNs > lastSampleNs { lastSampleNs = tNs }
        if windowStartNs < 0 { windowStartNs = tNs }
        return true
    }

    private func violate(_ tNs: Int64) {
        lastViolationNs = tNs
        ignoreUpToNs = tNs
        windowStartNs = -1
        gyroN = 0; gyroSq = 0; gyroSum = [0, 0, 0]
        accN = 0; accMean = 0; accM2 = 0
        driftN = 0; driftSum = [0, 0, 0]
        rawN = 0; rawSum = [0, 0, 0]
    }

    private func tryFinish(_ tNs: Int64) {
        if windowStartNs < 0 || tNs - windowStartNs < cfg.windowNs { return }
        if gyroN < cfg.minSamples || accN < cfg.minSamples { return }
        let gyroRms = (gyroSq / Double(gyroN)).squareRoot()
        let std = (accM2 / Double(accN)).squareRoot()
        if gyroRms > cfg.gyroRmsMax || abs(accMean - Self.gravity) > cfg.accelNormTol || std > cfg.accelStdMax { return }
        let bias = (0..<3).map { gyroSum[$0] / Double(gyroN) }
        var drift: [Double]?
        if driftN > 0 {
            drift = (0..<3).map { driftSum[$0] / Double(driftN) }
        } else if rawN > 0 {
            drift = (0..<3).map { rawSum[$0] / Double(rawN) - bias[$0] }
        }
        result = Result(gyroBias: bias, drift: drift, durationS: Double(tNs - windowStartNs) / 1e9,
                        gyroRms: gyroRms, accelNorm: accMean, accelStd: std)
    }
}

/// Contract C4: the states of the pre-scan hold-still card.
public enum CalibrationUi { case resettingAr, holdStill, moving, ready }

/// Pure text + gating of the hold-still card (the view only renders it).
public enum CalibrationCard {
    public static let tableHint = "Rest the phone on a table"

    public static func ui(arResetting: Bool, state: StillnessCalibrator.State?) -> CalibrationUi {
        guard !arResetting, let s = state else { return .resettingAr }
        switch s {
        case .ready: return .ready
        case .moving: return .moving
        case .holdStill: return .holdStill
        }
    }

    /// Start is allowed only when still AND ARKit reports normal tracking (the hold-still step is never skippable).
    /// `trackingState` uses the Android names: "TRACKING" = ARKit `.normal`.
    public static func startAllowed(_ ui: CalibrationUi, trackingState: String) -> Bool { ui == .ready && trackingState == "TRACKING" }

    /// (headline, sub line). `tableHint`: 10 s without becoming still.
    public static func text(_ ui: CalibrationUi, progress: Double, tableHint hint: Bool, trackingState: String) -> (String, String) {
        switch ui {
        case .resettingAr: return ("Getting ready...", "Resetting the camera tracking")
        case .holdStill: return ("Hold the phone still", hint ? tableHint : "\(min(max(Int(progress * 100), 0), 99))%")
        case .moving: return ("Hold the phone still", hint ? tableHint : "Moving: the count restarts")
        case .ready:
            return trackingState == "TRACKING"
                ? ("Ready. Press Start, then move slowly around the room", "")
                : ("Calibrated", "Point the camera at the room and move slowly until tracking starts")
        }
    }
}
