import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin StateAnswersTest.
final class StateAnswersTests: XCTestCase {
    private func snap(completeness: Double = 0.4, tracking: Int = 1, wall: Bool = true, floor: Bool = true,
                      ceiling: Bool = true, walls: [WallState] = [], sectors: Int = 4, gaps: [String] = []) -> ScanStateSnapshot {
        ScanStateSnapshot(completeness: completeness, tracking: tracking, wallFound: wall, floorFound: floor, ceilingFound: ceiling,
                          walls: walls, headingSectors: sectors, gaps: gaps)
    }

    private func overlay(_ line: String, file: StaticString = #filePath, ln: UInt = #line) -> OverlayEvent {
        guard case .overlay(let o)? = EventParser.parseLine(line) else { XCTFail("not an overlay", file: file, line: ln); return OverlayEvent() }
        return o
    }

    func testUnknownStateAbstains() {
        XCTAssertEqual(StateAnswers.abstain, StateAnswers.answer(.missing, nil).text)
        XCTAssertTrue(StateAnswers.answer(.missing, nil).abstained)
        let empty = snap(completeness: 0.0, tracking: 1, wall: false, floor: false, ceiling: false, walls: [], sectors: 0)
        XCTAssertFalse(empty.hasScanData)
        XCTAssertTrue(StateAnswers.answer(.missing, empty).abstained)
        XCTAssertTrue(StateAnswers.answer(.progress, empty).abstained)
        // Tracking not available: the snapshot is stale, do not describe it.
        XCTAssertTrue(StateAnswers.answer(.missing, snap(tracking: 3, walls: [WallState(id: 1, pct: 10)])).abstained)
        // Unknown question.
        let a = StateAnswers.answer(nil, snap(walls: [WallState(id: 1, pct: 10)]))
        XCTAssertTrue(a.abstained); XCTAssertEqual(StateAnswers.abstain, a.text); XCTAssertTrue(a.cites.isEmpty)
    }

    func testMissingNamesWeakWallsAndFloorFromSnapshotOnly() {
        let s = snap(floor: false, ceiling: true, walls: [WallState(id: 3, pct: 95), WallState(id: 2, pct: 40), WallState(id: 1, pct: 79)])
        let a = StateAnswers.answer(.missing, s)
        XCTAssertFalse(a.abstained)
        XCTAssertEqual("Missing: Wall 2, 40 percent; Wall 1, 79 percent; the floor.", a.text)
        XCTAssertEqual(["Wall 2", "Wall 1"], a.cites)
        XCTAssertTrue(Set(a.cites).isSubset(of: s.regions))
        XCTAssertFalse(a.text.contains("Wall 3"))
    }

    func testMissingCapsListAndCitesOnlySpoken() {
        let s = snap(floor: false, ceiling: false,
                     walls: [WallState(id: 1, pct: 10), WallState(id: 2, pct: 20), WallState(id: 3, pct: 30), WallState(id: 4, pct: 40)])
        let a = StateAnswers.answer(.missing, s)
        XCTAssertEqual("Missing: Wall 1, 10 percent; Wall 2, 20 percent; Wall 3, 30 percent; and 2 more.", a.text)
        XCTAssertEqual(["Wall 1", "Wall 2", "Wall 3"], a.cites)
    }

    func testMissingCitesGapsAsGiven() {
        let s = snap(completeness: 0.95, walls: [WallState(id: 1, pct: 90)], gaps: ["Window area behind you"])
        let a = StateAnswers.answer(.missing, s)
        XCTAssertEqual("Missing: Window area behind you.", a.text)
        XCTAssertEqual(["Window area behind you"], a.cites)
    }

    func testNothingMissing() {
        let done = snap(completeness: 0.95, walls: [WallState(id: 1, pct: 90), WallState(id: 2, pct: 85)])
        XCTAssertEqual("Nothing is missing. You can finish.", StateAnswers.answer(.missing, done).text)
        let early = snap(completeness: 0.3, walls: [WallState(id: 1, pct: 90)])
        XCTAssertEqual("Nothing specific yet. Keep scanning.", StateAnswers.answer(.missing, early).text)
    }

    func testNoWallYetButSomeDataIsAnswered() {
        let a = StateAnswers.answer(.missing, snap(completeness: 0.0, wall: false, floor: true, ceiling: false, sectors: 3))
        XCTAssertEqual("Missing: no wall found yet.", a.text)
        XCTAssertTrue(a.cites.isEmpty)
    }

    func testProgressTemplate() {
        XCTAssertEqual("Scan is 40 percent complete, 2 walls found.",
                       StateAnswers.answer(.progress, snap(walls: [WallState(id: 1, pct: 1), WallState(id: 2, pct: 2)])).text)
        XCTAssertEqual("Scan is 40 percent complete, 1 wall found.", StateAnswers.answer(.progress, snap(walls: [WallState(id: 5, pct: 1)])).text)
    }

    func testOnlyMissingIntentIsAStateQuestion() {
        XCTAssertEqual(.missing, StateAnswers.questionFor(.missing))
        for i in VoiceIntent.allCases where i != .missing { XCTAssertNil(StateAnswers.questionFor(i)) }
    }

    func testSnapshotFromOverlayUsesWallIdsAndFallsBackToPosition() {
        let e = overlay(#"{"ceiling_found":false,"completeness":0.42,"floor_found":true,"mode":"sweep","surfaces":"1.25,4.00,3.65,4.00,86,2;-0.5,0.00,-0.5,3.20,12,1","tracking":1,"type":"overlay","wall_found":true,"walls":2,"why_id":"a","why_text":"b","yaw_mask":2049}"#)
        let s = ScanStateSnapshot.fromOverlay(e)
        XCTAssertEqual([WallState(id: 2, pct: 86), WallState(id: 1, pct: 12)], s.walls)
        XCTAssertEqual(2, s.headingSectors)   // 2049 = 0x801 = bits 0 and 11
        XCTAssertEqual(0.42, s.completeness, accuracy: 1e-9)
    }

    func testV1CoreWallsGetPositionalNames() {
        let e = overlay(#"{"type":"overlay","completeness":0.1,"surfaces":"0,0,1,0,50;0,0,0,1,20","tracking":1}"#)
        XCTAssertEqual(["Wall 1", "Wall 2"], ScanStateSnapshot.fromOverlay(e).walls.map { $0.name })
    }

    func testFallbackWallIdsNeverCollideWithRealIds() {
        let e = overlay(#"{"type":"overlay","completeness":0.1,"surfaces":"0,0,1,0,50,2;0,0,0,1,20;0,0,0,2,30,1;0,0,0,3,40","tracking":1}"#)
        let ids = ScanStateSnapshot.fromOverlay(e).walls.map { $0.id }
        XCTAssertEqual([2, 3, 1, 4], ids)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testCeilingIsNeverListedAsMissing() {
        let a = StateAnswers.answer(.missing, snap(completeness: 0.95, floor: true, ceiling: false, walls: [WallState(id: 1, pct: 95)]))
        XCTAssertEqual("Nothing is missing. You can finish.", a.text)
        XCTAssertFalse(a.text.contains("ceiling"))
    }

    private func v3(_ surfaces: String, _ spans: String, walls: Int, extra: String = "") -> OverlayEvent {
        overlay("{\"type\":\"overlay\",\"completeness\":0.5,\"floor_found\":true,\"wall_found\":true,\"ceiling_found\":false,\(extra)\"shell\":\"\",\"shell_closed\":false,\"spans\":\"\(spans)\",\"surfaces\":\"\(surfaces)\",\"tracking\":1,\"walls\":\(walls)}")
    }

    func testV3SnapshotKeepsCoreIdsDropsInferredAndFullyBlockedWalls() {
        // ids 3, 1 real; id 0 = plane-less / hypothesised side; wall 2 is hidden behind furniture on every span.
        let e = v3("0,0,4,0,60,3;4,0,4,3,0,0;4,3,0,3,10,2;0,3,0,0,30,1", "3,0,0,4,0,o;2,4,3,2,3,b;2,2,3,0,3,b;1,0,3,0,0,o",
                   walls: 3, extra: "\"ceiling_seen\":true,")
        let s = ScanStateSnapshot.fromOverlay(e)
        XCTAssertEqual([WallState(id: 3, pct: 60), WallState(id: 1, pct: 30)], s.walls)
        XCTAssertEqual(3, s.wallCount)
        XCTAssertTrue(s.ceilingFound)
        XCTAssertEqual("Scan is 50 percent complete, 3 walls found.", StateAnswers.answer(.progress, s).text)
        // A partly blocked wall stays.
        let e2 = v3("0,0,4,0,10,2", "2,0,0,2,0,b;2,2,0,4,0,o", walls: 1)
        XCTAssertEqual([WallState(id: 2, pct: 10)], ScanStateSnapshot.fromOverlay(e2).walls)
    }

    func testNonFiniteCompletenessAndControlCharsAreSafeInJson() {
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            var e = overlay(#"{"type":"overlay","surfaces":"","tracking":1}"#)
            e.completeness = bad
            XCTAssertEqual(0.0, ScanStateSnapshot.fromOverlay(e).completeness)
            let raw = ScanStateSnapshot(completeness: bad, tracking: 1, wallFound: true, floorFound: true, ceilingFound: true, walls: [], headingSectors: 0)
            XCTAssertTrue(raw.toJSON().contains("\"completeness\":0.0"))
        }
        let s = ScanStateSnapshot(completeness: 0.5, tracking: 1, wallFound: true, floorFound: true, ceilingFound: true, walls: [],
                                  headingSectors: 0, gaps: ["a\nb\u{1}c\td"])
        XCTAssertTrue(s.toJSON().contains("\"gaps\":[\"a\\nb\\u0001c\\td\"]"))
        XCTAssertFalse(s.toJSON().unicodeScalars.contains { $0.value < 0x20 })
    }

    func testJsonIsSortedFlatAndHasNoImageOrPathFields() {
        let s = ScanStateSnapshot(completeness: 0.4, tracking: 1, wallFound: true, floorFound: true, ceilingFound: false,
                                  walls: [WallState(id: 1, pct: 12)], headingSectors: 2, labels: ["door"], gaps: ["say \"hi\""])
        XCTAssertEqual(
            #"{"ceiling_found":false,"completeness":0.4,"floor_found":true,"gaps":["say \"hi\""],"heading_sectors":2,"labels":["door"],"tracking":1,"wall_found":true,"walls":[{"id":1,"pct":12}]}"#,
            s.toJSON())
    }
}
