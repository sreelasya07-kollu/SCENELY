import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin StillnessCalibratorTest (+ the iOS raw-gyro drift mapping).
final class StillnessCalibratorTests: XCTestCase {
    private let ms: Int64 = 1_000_000

    /// Feeds [fromMs, toMs) of a resting phone at 200 Hz: gyro = bias + tiny deterministic noise, accel ~ gravity on z.
    private func feedStill(_ c: StillnessCalibrator, _ fromMs: Int64, _ toMs: Int64, uncal: Bool = true, bias: Double = 0.002) {
        var t = fromMs
        while t < toMs {
            let n = sin(Double(t) * 0.7) * 0.001
            c.onGyro(t * ms, bias + n, -bias + n, 0.5 * bias)
            if uncal { c.onGyroUncalibrated(t * ms, 0.01, 0.0, 0.0) }
            c.onAccel(t * ms, 0.02 + n, 0.03, 9.80 + n * 5)
            t += 5
        }
    }

    func testStillPhoneBecomesReadyAfterTheWindowWithTheMeasuredValues() throws {
        let c = StillnessCalibrator(startNs: 0)
        XCTAssertEqual(.holdStill, c.state)
        XCTAssertEqual(0.0, c.progress)
        feedStill(c, 0, 1000)
        XCTAssertEqual(.holdStill, c.state)
        XCTAssertEqual(0.5, c.progress, accuracy: 0.02)
        XCTAssertNil(c.finalResult())
        feedStill(c, 1000, 2100)
        XCTAssertEqual(.ready, c.state)
        XCTAssertEqual(1.0, c.progress)
        let r = try XCTUnwrap(c.finalResult())
        XCTAssertEqual(2.0, r.durationS, accuracy: 0.02)
        XCTAssertEqual(0.002, r.gyroBias[0], accuracy: 5e-4)
        XCTAssertEqual(-0.002, r.gyroBias[1], accuracy: 5e-4)
        XCTAssertEqual(0.01, r.drift![0], accuracy: 1e-9)
        XCTAssertTrue(r.gyroRms < 0.02)
        XCTAssertEqual(9.80, r.accelNorm, accuracy: 0.02)
        XCTAssertTrue(r.accelStd < 0.05)
        // Frozen: later samples (even a shake) do not change the result or the state.
        c.onGyro(3_000 * ms, 5, 5, 5)
        XCTAssertEqual(.ready, c.state)
        XCTAssertEqual(r.gyroBias, try XCTUnwrap(c.finalResult()).gyroBias)
        // The C1 keys: whole bias + drift triples and the four scalars.
        let cfg = r.toSessionConfig()
        XCTAssertEqual(Set(["calib.gyro_bias_x", "calib.gyro_bias_y", "calib.gyro_bias_z", "calib.drift_x", "calib.drift_y", "calib.drift_z",
                            "calib.duration_s", "calib.gyro_rms", "calib.accel_norm", "calib.accel_std"]), Set(cfg.keys))
    }

    func testMovingRestartsTheWindow() throws {
        let c = StillnessCalibrator(startNs: 0)
        feedStill(c, 0, 1800)                    // almost done ...
        XCTAssertTrue(c.progress > 0.85)
        c.onGyro(1800 * ms, 0.5, 0, 0)           // ... a shake
        XCTAssertEqual(.moving, c.state)
        XCTAssertEqual(0.0, c.progress)
        feedStill(c, 1805, 2200)                 // samples right after the shake: still MOVING for movingHoldNs
        XCTAssertEqual(.moving, c.state)
        XCTAssertNil(c.finalResult())
        feedStill(c, 2200, 3700)
        XCTAssertEqual(.holdStill, c.state)      // < 2 s since the restart
        feedStill(c, 3700, 4000)
        XCTAssertEqual(.ready, c.state)
        XCTAssertEqual(2.0, try XCTUnwrap(c.finalResult()).durationS, accuracy: 0.03)
    }

    func testSlowSwayOrTiltedAccelAlsoRestarts() {
        // Sustained 0.05 rad/s rotation: no single spike, but the running RMS is over the limit.
        let c = StillnessCalibrator(startNs: 0)
        var t: Int64 = 0
        while t < 3000 { c.onGyro(t * ms, 0.05, 0, 0); c.onAccel(t * ms, 0, 0, 9.8); t += 5 }
        XCTAssertNil(c.finalResult())
        // Accel mean far from 1 g (phone in free fall / being carried): not still.
        let d = StillnessCalibrator(startNs: 0)
        t = 0
        while t < 3000 { d.onGyro(t * ms, 0.001, 0, 0); d.onAccel(t * ms, 0, 0, 10.4); t += 5 }
        XCTAssertNil(d.finalResult())
        // Noisy accel (walking): std over the limit.
        let e = StillnessCalibrator(startNs: 0)
        t = 0
        while t < 3000 { e.onGyro(t * ms, 0.001, 0, 0); e.onAccel(t * ms, 0, 0, 9.8 + ((t / 5) % 2 == 0 ? 0.3 : -0.3)); t += 5 }
        XCTAssertNil(e.finalResult())
    }

    func testPhonesWithoutTheUncalibratedGyroStillCalibrateWithoutDrift() throws {
        let c = StillnessCalibrator(startNs: 0)
        feedStill(c, 0, 2100, uncal: false)
        let r = try XCTUnwrap(c.finalResult())
        XCTAssertNil(r.drift)
        let keys = r.toSessionConfig().keys
        XCTAssertFalse(keys.contains { $0.hasPrefix("calib.drift") })
        XCTAssertTrue(keys.contains("calib.gyro_bias_x"))
    }

    /// iOS mapping: platform drift = mean(raw CMGyroData) - mean(CMDeviceMotion.rotationRate) over the still window.
    func testRawGyroGivesPlatformDriftAsRawMinusDeviceMotionMean() throws {
        let c = StillnessCalibrator(startNs: 0)
        var t: Int64 = 0
        while t < 2100 {
            c.onGyro(t * ms, 0.001, 0.0, -0.002)
            c.onRawGyro(t * ms, 0.011, 0.003, -0.002)
            c.onAccel(t * ms, 0.02, 0.03, 9.80)
            t += 5
        }
        let r = try XCTUnwrap(c.finalResult())
        XCTAssertEqual(0.010, r.drift![0], accuracy: 1e-9)
        XCTAssertEqual(0.003, r.drift![1], accuracy: 1e-9)
        XCTAssertEqual(0.0, r.drift![2], accuracy: 1e-9)
        XCTAssertEqual(0.001, r.gyroBias[0], accuracy: 1e-9)
    }

    func testNeverReadyWithoutBothSensors() {
        let c = StillnessCalibrator(startNs: 0)
        var t: Int64 = 0
        while t < 5000 { c.onGyro(t * ms, 0.001, 0, 0); t += 5 }   // no accelerometer
        XCTAssertNil(c.finalResult())
        XCTAssertTrue(c.progress < 1.0)
    }

    func testTableHintAfterTenSecondsWithoutBecomingReady() {
        let c = StillnessCalibrator(startNs: 100 * ms)
        XCTAssertFalse(c.needsTableHint(nowNs: 100 * ms))
        XCTAssertFalse(c.needsTableHint(nowNs: 100 * ms + 9_999 * ms))
        XCTAssertTrue(c.needsTableHint(nowNs: 100 * ms + 10_000 * ms))
        // Once ready the hint is gone for good.
        feedStill(c, 100, 2300)
        XCTAssertEqual(.ready, c.state)
        XCTAssertFalse(c.needsTableHint(nowNs: 100 * ms + 60_000 * ms))
    }

    func testCardStatesTextAndStartGate() {
        let all: [StillnessCalibrator.State] = [.holdStill, .moving, .ready]
        XCTAssertEqual(.resettingAr, CalibrationCard.ui(arResetting: true, state: .ready))
        XCTAssertEqual(.resettingAr, CalibrationCard.ui(arResetting: false, state: nil))
        XCTAssertEqual([.holdStill, .moving, .ready] as [CalibrationUi], all.map { CalibrationCard.ui(arResetting: false, state: $0) })
        XCTAssertEqual("50%", CalibrationCard.text(.holdStill, progress: 0.5, tableHint: false, trackingState: "PAUSED").1)
        XCTAssertEqual("Rest the phone on a table", CalibrationCard.text(.holdStill, progress: 0.1, tableHint: true, trackingState: "TRACKING").1)
        XCTAssertEqual("Rest the phone on a table", CalibrationCard.text(.moving, progress: 0.0, tableHint: true, trackingState: "TRACKING").1)
        // Start needs both: calibrated AND tracking.
        XCTAssertFalse(CalibrationCard.startAllowed(.ready, trackingState: "PAUSED"))
        XCTAssertFalse(CalibrationCard.startAllowed(.holdStill, trackingState: "TRACKING"))
        XCTAssertFalse(CalibrationCard.startAllowed(.moving, trackingState: "TRACKING"))
        XCTAssertTrue(CalibrationCard.startAllowed(.ready, trackingState: "TRACKING"))
    }

    func testSamplesBeforeTheStartAreIgnored() {
        let c = StillnessCalibrator(startNs: 1_000 * ms)
        feedStill(c, 0, 900)
        XCTAssertEqual(0.0, c.progress)
        XCTAssertNil(c.finalResult())
    }
}
