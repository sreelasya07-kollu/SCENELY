package dev.capturekit.capture

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Pre-scan "hold still" measurement (ADR 0036, contract C1). Pure: the shell feeds gyro, uncalibrated-gyro and
 * accelerometer samples with their `t_ns` (SensorEvent.timestamp base) from the sensor thread; the UI thread reads
 * [state] / [progress] / [needsTableHint]. Thread-safe (every entry point is synchronized; ~400 calls/s).
 *
 * Window rule: the phone must stay still for [Config.windowNs] (2.0 s). Still = gyro RMS <= [Config.gyroRmsMax],
 * |mean accel norm - 9.80665| <= [Config.accelNormTol], accel norm std <= [Config.accelStdMax] (all guesses, tune on
 * device), checked on the running window; a single gyro sample above [Config.gyroSpikeMax] also counts. Any violation
 * restarts the window at the next sample. The bias is only RECORDED (gyro mean; drift mean when the uncalibrated sensor
 * exists), never subtracted: SensorBridge stays raw and Part 2 decides.
 *
 * States: [State.HOLD_STILL] (collecting), [State.MOVING] (violated within [Config.movingHoldNs]), [State.READY].
 * RESETTING_AR is a UI state (the AR session is being recreated) and lives in the activity.
 */
class StillnessCalibrator(private val startNs: Long, private val cfg: Config = Config()) {
    data class Config(
        val windowNs: Long = 2_000_000_000L,
        val gyroRmsMax: Double = 0.02,
        val gyroSpikeMax: Double = 0.10,
        val accelNormTol: Double = 0.25,
        val accelStdMax: Double = 0.05,
        /** After this long without becoming ready the hint asks to rest the phone on a table. */
        val hintAfterNs: Long = 10_000_000_000L,
        /** MOVING stays reported for this long after a violation. */
        val movingHoldNs: Long = 500_000_000L,
        /** Samples per sensor needed before the running statistics are judged. */
        val minSamples: Int = 20,
    )

    enum class State { HOLD_STILL, MOVING, READY }

    /** The values of contract C1 (rad/s, m/s^2, seconds). [drift] is null when the platform has no uncalibrated gyro. */
    class Result(
        val gyroBias: DoubleArray, val drift: DoubleArray?,
        val durationS: Double, val gyroRms: Double, val accelNorm: Double, val accelStd: Double,
    ) {
        /** Session config keys `calib.*` for `SessionManager.start` (the core records them as capture_settings.stillness_calibration). */
        fun toSessionConfig(): Map<String, Any> = buildMap {
            put("calib.gyro_bias_x", gyroBias[0]); put("calib.gyro_bias_y", gyroBias[1]); put("calib.gyro_bias_z", gyroBias[2])
            drift?.let { put("calib.drift_x", it[0]); put("calib.drift_y", it[1]); put("calib.drift_z", it[2]) }
            put("calib.duration_s", durationS); put("calib.gyro_rms", gyroRms)
            put("calib.accel_norm", accelNorm); put("calib.accel_std", accelStd)
        }
    }

    private val lock = Any()
    private var windowStartNs = -1L
    private var ignoreUpToNs = Long.MIN_VALUE      // samples at or before the last violation never join a window
    private var lastViolationNs = Long.MIN_VALUE
    private var lastSampleNs = startNs
    private var result: Result? = null

    private var gyroN = 0
    private val gyroSum = DoubleArray(3)
    private var gyroSq = 0.0
    private var accN = 0
    private var accMean = 0.0
    private var accM2 = 0.0
    private var driftN = 0
    private val driftSum = DoubleArray(3)

    fun onGyro(tNs: Long, x: Double, y: Double, z: Double) = synchronized(lock) {
        if (!accept(tNs)) return@synchronized
        val sq = x * x + y * y + z * z
        if (sq > cfg.gyroSpikeMax * cfg.gyroSpikeMax) return@synchronized violate(tNs)
        gyroN++; gyroSum[0] += x; gyroSum[1] += y; gyroSum[2] += z; gyroSq += sq
        if (gyroN >= cfg.minSamples && sqrt(gyroSq / gyroN) > cfg.gyroRmsMax) return@synchronized violate(tNs)
        tryFinish(tNs)
    }

    /** TYPE_GYROSCOPE_UNCALIBRATED: only the platform's drift estimate values[3..5] is used (the rate itself is the gyro's job). */
    fun onGyroUncalibrated(tNs: Long, driftX: Double, driftY: Double, driftZ: Double) = synchronized(lock) {
        if (!accept(tNs)) return@synchronized
        driftN++; driftSum[0] += driftX; driftSum[1] += driftY; driftSum[2] += driftZ
    }

    fun onAccel(tNs: Long, x: Double, y: Double, z: Double) = synchronized(lock) {
        if (!accept(tNs)) return@synchronized
        val norm = sqrt(x * x + y * y + z * z)
        accN++
        val d = norm - accMean
        accMean += d / accN
        accM2 += d * (norm - accMean)
        if (accN >= cfg.minSamples) {
            val std = sqrt(accM2 / accN)
            if (abs(accMean - GRAVITY) > cfg.accelNormTol || std > cfg.accelStdMax) return@synchronized violate(tNs)
        }
        tryFinish(tNs)
    }

    val state: State get() = synchronized(lock) {
        when {
            result != null -> State.READY
            lastViolationNs != Long.MIN_VALUE && lastSampleNs - lastViolationNs < cfg.movingHoldNs -> State.MOVING
            else -> State.HOLD_STILL
        }
    }

    /** 0..1: how much of the still window is collected (1 when ready). */
    val progress: Double get() = synchronized(lock) {
        when {
            result != null -> 1.0
            windowStartNs < 0 -> 0.0
            else -> ((lastSampleNs - windowStartNs).toDouble() / cfg.windowNs).coerceIn(0.0, 0.999)
        }
    }

    /** True once [Config.hintAfterNs] have passed since [startNs] without becoming ready ("Rest the phone on a table"). */
    fun needsTableHint(nowNs: Long): Boolean = synchronized(lock) { result == null && nowNs - startNs >= cfg.hintAfterNs }

    /** The frozen measurement once [state] is READY, else null. */
    fun result(): Result? = synchronized(lock) { result }

    // ---- internals (lock held) ----
    private fun accept(tNs: Long): Boolean {
        if (result != null || tNs <= ignoreUpToNs || tNs < startNs) return false
        if (tNs > lastSampleNs) lastSampleNs = tNs
        if (windowStartNs < 0) windowStartNs = tNs
        return true
    }

    private fun violate(tNs: Long) {
        lastViolationNs = tNs
        ignoreUpToNs = tNs
        windowStartNs = -1
        gyroN = 0; gyroSq = 0.0; gyroSum.fill(0.0)
        accN = 0; accMean = 0.0; accM2 = 0.0
        driftN = 0; driftSum.fill(0.0)
    }

    private fun tryFinish(tNs: Long) {
        if (windowStartNs < 0 || tNs - windowStartNs < cfg.windowNs) return
        if (gyroN < cfg.minSamples || accN < cfg.minSamples) return
        val gyroRms = sqrt(gyroSq / gyroN)
        val std = sqrt(accM2 / accN)
        if (gyroRms > cfg.gyroRmsMax || abs(accMean - GRAVITY) > cfg.accelNormTol || std > cfg.accelStdMax) return
        result = Result(
            gyroBias = DoubleArray(3) { gyroSum[it] / gyroN },
            drift = if (driftN > 0) DoubleArray(3) { driftSum[it] / driftN } else null,
            durationS = (tNs - windowStartNs) / 1e9, gyroRms = gyroRms, accelNorm = accMean, accelStd = std,
        )
    }

    companion object { const val GRAVITY = 9.80665 }
}

/** Contract C4: the states of the pre-scan hold-still card. */
enum class CalibrationUi { RESETTING_AR, HOLD_STILL, MOVING, READY }

/** Pure text + gating of the hold-still card (the activity only renders it). */
object CalibrationCard {
    fun ui(arResetting: Boolean, state: StillnessCalibrator.State?): CalibrationUi = when {
        arResetting || state == null -> CalibrationUi.RESETTING_AR
        state == StillnessCalibrator.State.READY -> CalibrationUi.READY
        state == StillnessCalibrator.State.MOVING -> CalibrationUi.MOVING
        else -> CalibrationUi.HOLD_STILL
    }

    /** Start is allowed only when still AND ARCore reports TRACKING (the hold-still step is never skippable). */
    fun startAllowed(ui: CalibrationUi, trackingState: String): Boolean = ui == CalibrationUi.READY && trackingState == "TRACKING"

    /** (headline, sub line). [tableHint]: 10 s without becoming still. */
    fun text(ui: CalibrationUi, progress: Double, tableHint: Boolean, trackingState: String): Pair<String, String> = when (ui) {
        CalibrationUi.RESETTING_AR -> "Getting ready..." to "Resetting the camera tracking"
        CalibrationUi.HOLD_STILL -> "Hold the phone still" to (if (tableHint) TABLE_HINT else "${(progress * 100).toInt().coerceIn(0, 99)}%")
        CalibrationUi.MOVING -> "Hold the phone still" to (if (tableHint) TABLE_HINT else "Moving: the count restarts")
        CalibrationUi.READY ->
            if (trackingState == "TRACKING") "Ready. Press Start, then move slowly around the room" to ""
            else "Calibrated" to "Point the camera at the room and move slowly until tracking starts"
    }

    const val TABLE_HINT = "Rest the phone on a table"
}
