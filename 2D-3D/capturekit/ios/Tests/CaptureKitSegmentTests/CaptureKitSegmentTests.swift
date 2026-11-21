import XCTest
@testable import CaptureKitSegment

final class CaptureKitSegmentTests: XCTestCase {
    func testRuntimeName() {
        XCTAssertEqual(CaptureKitSegment.runtime, "LiteRT-Swift 2.3.0")
    }
}
