package dev.capturekit.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sin

class StillnessCalibratorTest {
    private val ms = 1_000_000L

    /** Feeds [fromMs, toMs) of a resting phone at 200 Hz: gyro = bias + tiny deterministic noise, accel ~ gravity on z. */
    private fun feedStill(c: StillnessCalibrator, fromMs: Long, toMs: Long, uncal: Boolean = true, bias: Double = 0.002) {
        var t = fromMs
        while (t < toMs) {
            val n = sin(t * 0.7) * 0.001
            c.onGyro(t * ms, bias + n, -bias + n, 0.5 * bias)
            if (uncal) c.onGyroUncalibrated(t * ms, 0.01, 0.0, 0.0)
            c.onAccel(t * ms, 0.02 + n, 0.03, 9.80 + n * 5)
            t += 5
        }
    }

    @Test fun stillPhoneBecomesReadyAfterTheWindowWithTheMeasuredValues() {
        val c = StillnessCalibrator(0)
        assertEquals(StillnessCalibrator.State.HOLD_STILL, c.state)
        assertEquals(0.0, c.progress, 0.0)
        feedStill(c, 0, 1000)
        assertEquals(StillnessCalibrator.State.HOLD_STILL, c.state)
        assertEquals(0.5, c.progress, 0.02)
        assertNull(c.result())
        feedStill(c, 1000, 2100)
        assertEquals(StillnessCalibrator.State.READY, c.state)
        assertEquals(1.0, c.progress, 0.0)
        val r = c.result()!!
        assertEquals(2.0, r.durationS, 0.02)
        assertEquals(0.002, r.gyroBias[0], 5e-4)
        assertEquals(-0.002, r.gyroBias[1], 5e-4)
        assertEquals(0.01, r.drift!![0], 1e-9)
        assertTrue(r.gyroRms < 0.02)
        assertEquals(9.80, r.accelNorm, 0.02)
        assertTrue(r.accelStd < 0.05)
        // Frozen: later samples (even a shake) do not change the result or the state.
        c.onGyro(3_000 * ms, 5.0, 5.0, 5.0)
        assertEquals(StillnessCalibrator.State.READY, c.state)
        assertTrue(c.result() === r)
        // The C1 keys: whole bias + drift triples and the four scalars.
        val cfg = r.toSessionConfig()
        assertEquals(setOf("calib.gyro_bias_x", "calib.gyro_bias_y", "calib.gyro_bias_z", "calib.drift_x", "calib.drift_y", "calib.drift_z",
            "calib.duration_s", "calib.gyro_rms", "calib.accel_norm", "calib.accel_std"), cfg.keys)
    }

    @Test fun movingRestartsTheWindow() {
        val c = StillnessCalibrator(0)
        feedStill(c, 0, 1800)                    // almost done ...
        assertTrue(c.progress > 0.85)
        c.onGyro(1800 * ms, 0.5, 0.0, 0.0)       // ... a shake
        assertEquals(StillnessCalibrator.State.MOVING, c.state)
        assertEquals(0.0, c.progress, 0.0)
        feedStill(c, 1805, 2200)                 // samples right after the shake: still MOVING for movingHoldNs
        assertEquals(StillnessCalibrator.State.MOVING, c.state)
        assertNull(c.result())
        feedStill(c, 2200, 3700)
        assertEquals(StillnessCalibrator.State.HOLD_STILL, c.state)   // < 2 s since the restart
        feedStill(c, 3700, 4000)
        assertEquals(StillnessCalibrator.State.READY, c.state)
        assertEquals(2.0, c.result()!!.durationS, 0.03)
    }

    @Test fun slowSwayOrTiltedAccelAlsoRestarts() {
        // Sustained 0.05 rad/s rotation: no single spike, but the running RMS is over the limit.
        val c = StillnessCalibrator(0)
        var t = 0L
        while (t < 3000) { c.onGyro(t * ms, 0.05, 0.0, 0.0); c.onAccel(t * ms, 0.0, 0.0, 9.8); t += 5 }
        assertNull(c.result())
        // Accel mean far from 1 g (phone in free fall / being carried): not still.
        val d = StillnessCalibrator(0)
        t = 0
        while (t < 3000) { d.onGyro(t * ms, 0.001, 0.0, 0.0); d.onAccel(t * ms, 0.0, 0.0, 10.4); t += 5 }
        assertNull(d.result())
        // Noisy accel (walking): std over the limit.
        val e = StillnessCalibrator(0)
        t = 0
        while (t < 3000) { e.onGyro(t * ms, 0.001, 0.0, 0.0); e.onAccel(t * ms, 0.0, 0.0, 9.8 + if ((t / 5) % 2 == 0L) 0.3 else -0.3); t += 5 }
        assertNull(e.result())
    }

    @Test fun phonesWithoutTheUncalibratedGyroStillCalibrateWithoutDrift() {
        val c = StillnessCalibrator(0)
        feedStill(c, 0, 2100, uncal = false)
        val r = c.result()!!
        assertNull(r.drift)
        val keys = r.toSessionConfig().keys
        assertFalse(keys.any { it.startsWith("calib.drift") })
        assertTrue("calib.gyro_bias_x" in keys)
    }

    @Test fun neverReadyWithoutBothSensors() {
        val c = StillnessCalibrator(0)
        var t = 0L
        while (t < 5000) { c.onGyro(t * ms, 0.001, 0.0, 0.0); t += 5 }   // no accelerometer
        assertNull(c.result())
        assertNotNull(c.state)
        assertTrue(c.progress < 1.0)
    }

    @Test fun tableHintAfterTenSecondsWithoutBecomingReady() {
        val c = StillnessCalibrator(100 * ms)
        assertFalse(c.needsTableHint(100 * ms))
        assertFalse(c.needsTableHint(100 * ms + 9_999 * ms))
        assertTrue(c.needsTableHint(100 * ms + 10_000 * ms))
        // Once ready the hint is gone for good.
        feedStill(c, 100, 2300)
        assertEquals(StillnessCalibrator.State.READY, c.state)
        assertFalse(c.needsTableHint(100 * ms + 60_000 * ms))
    }

    @Test fun cardStatesTextAndStartGate() {
        val s = StillnessCalibrator.State.values()
        assertEquals(CalibrationUi.RESETTING_AR, CalibrationCard.ui(true, StillnessCalibrator.State.READY))
        assertEquals(CalibrationUi.RESETTING_AR, CalibrationCard.ui(false, null))
        assertEquals(listOf(CalibrationUi.HOLD_STILL, CalibrationUi.MOVING, CalibrationUi.READY), s.map { CalibrationCard.ui(false, it) })
        assertEquals("50%", CalibrationCard.text(CalibrationUi.HOLD_STILL, 0.5, false, "PAUSED").second)
        assertEquals("Rest the phone on a table", CalibrationCard.text(CalibrationUi.HOLD_STILL, 0.1, true, "TRACKING").second)
        assertEquals("Rest the phone on a table", CalibrationCard.text(CalibrationUi.MOVING, 0.0, true, "TRACKING").second)
        // Start needs both: calibrated AND tracking.
        assertFalse(CalibrationCard.startAllowed(CalibrationUi.READY, "PAUSED"))
        assertFalse(CalibrationCard.startAllowed(CalibrationUi.HOLD_STILL, "TRACKING"))
        assertFalse(CalibrationCard.startAllowed(CalibrationUi.MOVING, "TRACKING"))
        assertTrue(CalibrationCard.startAllowed(CalibrationUi.READY, "TRACKING"))
    }

    @Test fun samplesBeforeTheStartAreIgnored() {
        val c = StillnessCalibrator(1_000 * ms)
        feedStill(c, 0, 900)
        assertEquals(0.0, c.progress, 0.0)
        assertNull(c.result())
    }
}
