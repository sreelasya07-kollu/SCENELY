import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin RecalibrationTest (4 cases).
final class RecalibrationTests: XCTestCase {
    private func recal(_ text: String) -> CoreEvent {
        .instruction(id: 7, type: "RECALIBRATE", speakText: "Turn your phone slowly in a small circle.", longText: text, priority: 3,
                     haptic: "double", overlayHint: "recalibrate")
    }
    private let lost = CoreEvent.trackingLost(tNs: 2_000_000_000, trackingState: 2, reason: 3, degradedS: 2.0)
    private let reset = CoreEvent.trackingReset(tNs: 5_000_000_000, lostS: 3.5, driftM: 0.25, driftDeg: 4.0)

    func testLostShowsResetHidesAndKeepsTheDriftDelta() {
        var r = Recalibration()
        XCTAssertFalse(r.active)
        r = r.on(lost)
        XCTAssertTrue(r.active)
        XCTAssertEqual(Recalibration.fallback, r.prompt)   // no RECALIBRATE text yet
        r = r.on(recal("Tracking lost. Slowly turn your phone in a small circle to recalibrate."))
        XCTAssertEqual("Tracking lost. Slowly turn your phone in a small circle to recalibrate.", r.prompt)
        r = r.on(reset)
        XCTAssertFalse(r.active)
        XCTAssertEqual(1, r.resets)
        XCTAssertEqual(0.25, r.lastReset!.driftM, accuracy: 1e-12)
    }

    func testInstructionAloneNeverOpensThePromptAndOtherEventsAreIgnored() {
        let r = Recalibration().on(recal("x"))
        XCTAssertFalse(r.active)   // visibility follows the core's tracking events only
        let other = CoreEvent.instruction(id: 1, type: "MOVE_TO", speakText: "Walk ahead.", longText: "", priority: 2, haptic: "tap", overlayHint: "")
        let s = Recalibration(active: true, text: "t")
        XCTAssertEqual(s, s.on(other))
        XCTAssertEqual(s, s.on(lost))   // already active: unchanged
        XCTAssertEqual(s, s.on(.keyframeRequest(frameId: 1, file: "keyframes/000001.jpg")))
    }

    func testSessionEndClearsAndRepeatedLossesCount() {
        var r = Recalibration().on(lost).on(reset).on(lost)
        XCTAssertTrue(r.active)
        r = r.on(.stateChange(from: "SCANNING", to: "PAUSED", reason: "user"))
        XCTAssertTrue(r.active)   // a user pause does not end the recovery
        r = r.on(reset)
        XCTAssertEqual(2, r.resets)
        XCTAssertEqual(Recalibration(), r.on(lost).on(.stateChange(from: "SCANNING", to: "FINALIZING", reason: "stop")))
    }

    func testParsedCoreLinesDriveIt() {
        let lines = """
        {"degraded_s":2,"reason":3,"t_ns":1234567890123,"tracking_state":2,"type":"tracking_lost"}
        {"type":"tracking_reset","t_ns":1234567899999,"lost_s":3.5,"drift_m":0.12,"drift_deg":7.5}

        """
        let ev = EventParser.parse(lines)
        XCTAssertEqual(2, ev.count)
        var r = Recalibration().on(ev[0])
        XCTAssertTrue(r.active)
        r = r.on(ev[1])
        XCTAssertFalse(r.active)
        XCTAssertEqual(7.5, r.lastReset!.driftDeg, accuracy: 1e-12)
    }
}
