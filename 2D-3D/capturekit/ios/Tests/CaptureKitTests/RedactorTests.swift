import XCTest
@testable import CaptureKit

/// Pure part of the face redaction (padding, un-rotation, Vision box mapping, NV12 fill, redaction.json). The Vision detector itself
/// (FaceRedactor) is iOS only and checked on a device. Cases follow the Kotlin RedactorTest.
final class RedactorTests: XCTestCase {
    func testPadGrowsSnapsToEvenAndClamps() {
        XCTAssertEqual(RedactionMath.pad(RedactionRegion(10, 10, 30, 30), w: 100, h: 100, fraction: 0.15), RedactionRegion(6, 6, 34, 34))
        XCTAssertEqual(RedactionMath.pad(RedactionRegion(0, 0, 100, 100), w: 100, h: 100, fraction: 0.15), RedactionRegion(0, 0, 100, 100))
        XCTAssertNil(RedactionMath.pad(RedactionRegion(200, 200, 210, 210), w: 100, h: 100, fraction: 0.15))
    }

    func testUnrotateMapsBackToTheBaseImage() {
        // base image 100 wide x 50 high; rotated 90 / 270 it is 50 wide x 100 high
        XCTAssertEqual(RedactionMath.unrotate(0, 10, 20, 30, 60, bw: 100, bh: 50), RedactionRegion(10, 20, 30, 60))
        XCTAssertEqual(RedactionMath.unrotate(90, 10, 20, 30, 60, bw: 100, bh: 50), RedactionRegion(20, 20, 60, 40))
        XCTAssertEqual(RedactionMath.unrotate(270, 10, 20, 30, 60, bw: 100, bh: 50), RedactionRegion(40, 10, 80, 30))
    }

    func testVisionBoxHasLowerLeftOriginAndIsUnrotatedPerOrientation() {
        // 200 x 100 buffer; box x=.25 y=.5 w=.25 h=.25 (normalised, origin lower-left)
        XCTAssertEqual(RedactionMath.region(visionBox: 0.25, 0.5, 0.25, 0.25, rot: 0, bufW: 200, bufH: 100), RedactionRegion(50, 25, 100, 50))
        XCTAssertEqual(RedactionMath.region(visionBox: 0.25, 0.5, 0.25, 0.25, rot: 90, bufW: 200, bufH: 100), RedactionRegion(50, 50, 100, 75))
        XCTAssertEqual(RedactionMath.region(visionBox: 0.25, 0.5, 0.25, 0.25, rot: 270, bufW: 200, bufH: 100), RedactionRegion(100, 25, 150, 50))
        XCTAssertNil(RedactionMath.region(visionBox: 0.5, 0.5, 0, 0.25, rot: 0, bufW: 200, bufH: 100))
    }

    func testFillNV12CoversLumaAndInterleavedChromaOnly() {
        let yStride = 10, cStride = 10
        var y = [UInt8](repeating: 0xFF, count: yStride * 4)
        var c = [UInt8](repeating: 0x00, count: cStride * 2)
        y.withUnsafeMutableBufferPointer { yp in
            c.withUnsafeMutableBufferPointer { cp in
                RedactionMath.fillNV12(y: yp.baseAddress!, yStride: yStride, cbcr: cp.baseAddress!, cStride: cStride, RedactionRegion(2, 0, 6, 2))
            }
        }
        for row in 0..<4 {
            for x in 0..<yStride {
                let inside = row < 2 && (2..<6).contains(x)
                XCTAssertEqual(y[row * yStride + x], inside ? RedactionMath.fillY : 0xFF, "luma row \(row) col \(x)")
            }
        }
        for row in 0..<2 {
            for x in 0..<cStride {
                let inside = row == 0 && (2..<6).contains(x)
                XCTAssertEqual(c[row * cStride + x], inside ? RedactionMath.fillC : 0x00, "chroma row \(row) col \(x)")
            }
        }
    }

    func testJsonShapeMatchesTheAndroidRedactor() {
        let log = RedactionLog(detectorName: "d")
        log.record(RedactionLog.Entry(file: "keyframes/000003.jpg", id: 3, dropped: false, regions: [RedactionRegion(1, 2, 3, 4)]))
        log.record(RedactionLog.Entry(file: "a\"b", id: 4, dropped: true, regions: []))
        let expected = #"{"version":1,"mode":"faces","best_effort":true,"detector":"d","fill":"solid","coords":"keyframe_pixels_x0y0x1y1","keyframes":[{"id":3,"file":"keyframes/000003.jpg","status":"ok","regions":[[1,2,3,4]]},{"id":4,"file":"a\"b","status":"dropped_detector_failure","regions":[]}]}"#
        XCTAssertEqual(log.toJson(), expected)
        XCTAssertEqual(log.count, 2)
    }

    func testOnFailingFiresOncePerStreakOfFive() {
        var fired = 0
        let log = RedactionLog(detectorName: "d", onFailing: { fired += 1 })
        let bad = RedactionLog.Entry(file: "f", id: 0, dropped: true, regions: [])
        let good = RedactionLog.Entry(file: "f", id: 0, dropped: false, regions: [])
        for _ in 0..<4 { log.record(bad) }
        XCTAssertEqual(fired, 0)
        log.record(bad); XCTAssertEqual(fired, 1)
        log.record(bad); XCTAssertEqual(fired, 1)
        log.record(good)
        for _ in 0..<5 { log.record(bad) }
        XCTAssertEqual(fired, 2)
    }

    func testWriteJsonCreatesPrivacyFileAndLeavesNoTmp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ck-redact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RedactionLog(detectorName: "d")
        log.record(RedactionLog.Entry(file: "k.jpg", id: 1, dropped: false, regions: []))
        XCTAssertTrue(log.writeJson(to: dir))
        XCTAssertTrue(log.writeJson(to: dir))   // second write replaces the first
        let text = try String(contentsOf: dir.appendingPathComponent("privacy/redaction.json"), encoding: .utf8)
        XCTAssertEqual(text, log.toJson())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("privacy/redaction.json.tmp").path))
    }

    func testPeriodicFlushWritesTheFileEveryTenEntries() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ck-redact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RedactionLog(detectorName: "d", bundleDir: dir)
        for i in 0..<9 { log.record(RedactionLog.Entry(file: "k\(i)", id: i, dropped: false, regions: [])) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("privacy/redaction.json").path))
        log.record(RedactionLog.Entry(file: "k9", id: 9, dropped: false, regions: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("privacy/redaction.json").path))
    }
}
