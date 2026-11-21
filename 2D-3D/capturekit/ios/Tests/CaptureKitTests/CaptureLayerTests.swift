import XCTest
@testable import CaptureKit

/// Pure parts of the iOS capture layer (phase P2): session config assembly, segmentation worker, YCbCr conversion.
final class SessionConfigBuilderTests: XCTestCase {
    private let consent: SessionConfig = ["consent_version": "1", "consent_at": "2026-01-01T00:00:00Z", "redaction_mode": "faces"]

    func testNoConsentNoConfig() {
        XCTAssertNil(SessionConfigBuilder.build(flags: FeatureFlags.Flags.defaults, consent: nil, calibration: nil))
    }

    func testFlagsConsentAndCalibrationAreMerged() {
        var f = FeatureFlags.Flags.defaults
        f.understanding = 2; f.recordImu = true
        let calib = StillnessCalibrator.Result(gyroBias: [0.001, 0.002, 0.003], drift: nil, durationS: 2.0, gyroRms: 0.01, accelNorm: 9.8, accelStd: 0.01)
        let m = SessionConfigBuilder.build(flags: f, consent: consent, calibration: calib, extra: ["threaded": 1])!
        XCTAssertEqual(m["guide.understanding"], .int(2))
        XCTAssertEqual(m["record_imu"], .int(1))
        XCTAssertEqual(m["consent_version"], .string("1"))
        XCTAssertEqual(m["redaction_mode"], .string("faces"))
        XCTAssertEqual(m["calib.gyro_bias_y"], .double(0.002))
        XCTAssertNil(m["calib.drift_x"])
        XCTAssertEqual(m["threaded"], .int(1))
    }

    func testRecordImuOffWritesNoKeyAndUnderstandingZeroIsKept() {
        var f = FeatureFlags.Flags.defaults
        f.understanding = 0
        let m = SessionConfigBuilder.build(flags: f, consent: consent, calibration: nil)!
        XCTAssertNil(m["record_imu"])
        XCTAssertEqual(m["guide.understanding"], .int(0))
        XCTAssertNil(m["calib.gyro_bias_x"])
    }
}

final class YCbCrTests: XCTestCase {
    func testNeutralChromaIsGrayAndExtremesClamp() {
        XCTAssertEqual(YCbCr.argb(100, 128, 128), 0xFF64_6464)
        XCTAssertEqual(YCbCr.argb(255, 128, 255), 0xFFFF_A4FF)   // r clamps to 255, g = 255 - 0.714136 * 127 = 164, b clamps
        XCTAssertEqual(YCbCr.argb(0, 128, 128), 0xFF00_0000)
    }

    func testRedAndBlueDirections() {
        let red = YCbCr.argb(128, 128, 255)    // Cr high -> red up, green down
        XCTAssertGreaterThan((red >> 16) & 0xFF, 200)
        XCTAssertLessThan((red >> 8) & 0xFF, 128)
        let blue = YCbCr.argb(128, 255, 128)   // Cb high -> blue up
        XCTAssertGreaterThan(blue & 0xFF, 200)
    }
}

final class SegmentationSchedulerTests: XCTestCase {
    private struct Img: SegImage { let w = 4, h = 4; func argb(_ x: Int, _ y: Int) -> UInt32 { 0xFF00_0000 } }
    private let cam = CameraSnapshot(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 0, tz: 0, fx: 100, fy: 100, cx: 2, cy: 2, w: 4, h: 4)
    private func job(_ t: Int64) -> SegJob { SegJob(tNs: t, image: Img(), camera: cam) }
    private func inst() -> Instance { Instance(coco: 1, label: "chair", score: 0.9, box: Box2(0, 0, 1, 1), cx: 0.5, cy: 0.5) }

    private final class Fake: Segmenter {
        let name = "fake"
        var result: [Instance]?
        var calls = 0, closed = false
        init(_ r: [Instance]?) { result = r }
        func segment(_ image: SegImage, quarterTurns: Int) -> [Instance]? { calls += 1; return result }
        func close() { closed = true }
    }

    /// A worker whose queue the test pumps by hand.
    private final class Pump {
        var queue: [() -> Void] = []
        func post(_ w: @escaping () -> Void) { queue.append(w) }
        func run() { while !queue.isEmpty { queue.removeFirst()() } }
    }

    private func make(_ seg: Segmenter?, pump: Pump, results: ResultBox, disabled: DisabledBox = DisabledBox()) -> SegmentationScheduler {
        SegmentationScheduler(open: { seg }, sink: { results.list.append($0) }, post: { pump.post($0) },
                              onDisabled: { disabled.count += 1 }, log: { _ in })
    }
    private final class ResultBox { var list: [SegResult] = [] }
    private final class DisabledBox { var count = 0 }

    func testGateRateAndTracking() {
        let s = make(Fake([]), pump: Pump(), results: ResultBox())
        XCTAssertFalse(s.shouldCapture(tNs: 0, trackingNormal: false))
        XCTAssertFalse(s.shouldCapture(tNs: 0, mlRateScale: 0))
        XCTAssertTrue(s.shouldCapture(tNs: 0))
        XCTAssertFalse(s.shouldCapture(tNs: 100_000_000))
        XCTAssertTrue(s.shouldCapture(tNs: 200_000_000))
        XCTAssertFalse(s.shouldCapture(tNs: 250_000_000, mlRateScale: 1))
        XCTAssertTrue(s.shouldCapture(tNs: 300_000_000, mlRateScale: 2))     // scale 2 -> 100 ms interval
        XCTAssertFalse(s.shouldCapture(tNs: 100_000_000))                    // clock went backwards: interval restarts, no run
        XCTAssertTrue(s.shouldCapture(tNs: 300_000_000))
    }

    func testLatestWinsAndOlderFramesAreCountedDrops() {
        let pump = Pump(), box = ResultBox()
        let s = make(Fake([inst()]), pump: pump, results: box)
        XCTAssertTrue(s.submit(job(1)))
        XCTAssertTrue(s.submit(job(2)))
        XCTAssertTrue(s.submit(job(3)))
        XCTAssertTrue(s.busy)
        pump.run()
        XCTAssertEqual(box.list.map { $0.tNs }, [3])
        XCTAssertEqual(s.dropped, 2)
        XCTAssertEqual(s.processed, 1)
        XCTAssertFalse(s.busy)
        XCTAssertTrue(s.submit(job(4))); pump.run()
        XCTAssertEqual(box.list.map { $0.tNs }, [3, 4])
    }

    func testMissingModelTurnsTheFeatureOffOnce() {
        let pump = Pump(), dis = DisabledBox()
        let s = make(nil, pump: pump, results: ResultBox(), disabled: dis)
        XCTAssertTrue(s.submit(job(1))); pump.run()
        XCTAssertTrue(s.disabled)
        XCTAssertEqual(dis.count, 1)
        XCTAssertFalse(s.submit(job(2)))
        XCTAssertFalse(s.shouldCapture(tNs: 1_000_000_000))
    }

    func testGivesUpAfterFiveConsecutiveFailuresAndASuccessResetsTheStreak() {
        let pump = Pump(), dis = DisabledBox(), box = ResultBox()
        let fake = Fake(nil)
        let s = make(fake, pump: pump, results: box, disabled: dis)
        for i in 0..<4 { _ = s.submit(job(Int64(i))); pump.run() }
        XCTAssertFalse(s.disabled)
        fake.result = []
        _ = s.submit(job(10)); pump.run()                        // success resets the streak
        fake.result = nil
        for i in 0..<4 { _ = s.submit(job(Int64(20 + i))); pump.run() }
        XCTAssertFalse(s.disabled)
        _ = s.submit(job(30)); pump.run()
        XCTAssertTrue(s.disabled)
        XCTAssertEqual(dis.count, 1)
        XCTAssertEqual(s.failures, 9)
        XCTAssertEqual(box.list.count, 1)
    }

    func testCloseReleasesTheModelOnTheWorker() {
        let pump = Pump(), fake = Fake([])
        let s = make(fake, pump: pump, results: ResultBox())
        _ = s.submit(job(1)); pump.run()
        s.close(); s.close()
        pump.run()
        XCTAssertTrue(fake.closed)
        XCTAssertFalse(s.submit(job(2)))
    }
}
