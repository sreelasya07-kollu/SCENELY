import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin HapticMapTest (5 cases).
final class HapticMapTests: XCTestCase {
    func testNoneIsSilent() { XCTAssertTrue(HapticMap.pulses("none").isEmpty) }

    func testTapIsOneTick() {
        XCTAssertEqual([HapticMap.Pulse(.tick, 0)], HapticMap.pulses("tap"))
    }

    func testDoubleIsTwoTicksSpaced() {
        let p = HapticMap.pulses("double")
        XCTAssertEqual(2, p.count); XCTAssertEqual(0, p[0].delayMs); XCTAssertTrue((80...300).contains(p[1].delayMs))
        XCTAssertTrue(p.allSatisfy { $0.kind == .tick })
    }

    func testSuccessIsConfirm() {
        XCTAssertEqual([HapticMap.Pulse(.confirm, 0)], HapticMap.pulses("success"))
    }

    func testUnknownNameFallsBackToSilentUnlessUrgent() {
        XCTAssertTrue(HapticMap.pulses("weird", priority: 2).isEmpty)
        XCTAssertEqual(2, HapticMap.pulses("weird", priority: 3).count)
    }
}
