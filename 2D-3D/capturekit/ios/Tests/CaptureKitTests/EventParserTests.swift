import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin EventParserTest.
final class EventParserTests: XCTestCase {
    private func overlay(_ line: String, file: StaticString = #filePath, line ln: UInt = #line) -> OverlayEvent {
        guard case .overlay(let o)? = EventParser.parseLine(line) else { XCTFail("not an overlay", file: file, line: ln); return OverlayEvent() }
        return o
    }

    func testKeyframeRequest() {
        let e = EventParser.parseLine(#"{"file":"keyframes/000012.jpg","frame_id":42,"t_ns":123456,"type":"keyframe_request"}"#)
        XCTAssertEqual(.keyframeRequest(frameId: 42, file: "keyframes/000012.jpg"), e)
    }

    func testMultiLineAndUnknown() {
        let text = """
        {"type":"state","t_ns":1,"from":"IDLE","to":"CALIBRATING","reason":"start"}
        {"type":"governor","t_ns":2,"from":"NOMINAL","to":"LOWER_RESOLUTION","reason":"thermal=2"}
        {"type":"mystery","x":1}
        not json

        """
        let ev = EventParser.parse(text)
        XCTAssertEqual(3, ev.count)
        XCTAssertEqual(.stateChange(from: "IDLE", to: "CALIBRATING", reason: "start"), ev[0])
        XCTAssertEqual(.governor(from: "NOMINAL", to: "LOWER_RESOLUTION", reason: "thermal=2"), ev[1])
        if case .other = ev[2] {} else { XCTFail("expected other") }
    }

    func testFrameQualityAndDrops() {
        guard case .frameQuality(let id, _, let hard, let reasons)? = EventParser.parseLine(
            #"{"type":"frame_quality","t_ns":5,"frame_id":7,"quality":0.0,"hard_reject":true,"reasons":["MOTION_BLUR","LOW_TEXTURE"]}"#)
        else { return XCTFail("not frame_quality") }
        XCTAssertEqual(7, id); XCTAssertTrue(hard); XCTAssertEqual(["MOTION_BLUR", "LOW_TEXTURE"], reasons)
        guard case .ingestDrop(let counts)? = EventParser.parseLine(#"{"type":"ingest_drop","t_ns":9,"frame":3,"gyro":10}"#)
        else { return XCTFail("not ingest_drop") }
        XCTAssertEqual(["gyro": 10, "frame": 3] as [String: Int64], counts)
        XCTAssertNil(EventParser.parseLine(#"{"no_type":1}"#))
    }

    func testInstructionEvent() {
        let e = EventParser.parseLine(
            #"{"haptic":"tap","id":7,"instruction":"MOVE_TO","long_text":"Walk ahead about 2 meters.","msg_id":"move.to","overlay_hint":"arrow:10:2","params":{"distance_m":2,"rel_bearing_deg":10},"priority":2,"speak_text":"Walk ahead, 2 meters.","t_ns":5,"type":"instruction"}"#)
        XCTAssertEqual(.instruction(id: 7, type: "MOVE_TO", speakText: "Walk ahead, 2 meters.", longText: "Walk ahead about 2 meters.",
                                    priority: 2, haptic: "tap", overlayHint: "arrow:10:2"), e)
    }

    func testOverlayEvent() {
        let e = overlay(
            #"{"ceiling_found":false,"completeness":0.35,"floor_found":true,"has_target":true,"mode":"target","seen":0.8627,"surfaces":"1.25,4.00,3.65,4.00,86;-0.5,0.00,-0.5,3.20,12","t_ns":4999999950,"target_x":2.55,"target_z":3.05,"tracking":1,"type":"overlay","user_x":2.47,"user_yaw_deg":-2,"user_z":3.05,"wall_found":true,"walls":2,"why_id":"why.left","why_text":"Left wall not scanned yet"}"#)
        XCTAssertEqual(0.35, e.completeness, accuracy: 1e-9); XCTAssertEqual(0.8627, e.seen, accuracy: 1e-9)
        XCTAssertEqual(1, e.tracking); XCTAssertEqual("target", e.mode)
        XCTAssertTrue(e.wallFound && e.floorFound && !e.ceilingFound); XCTAssertEqual(2, e.walls)
        XCTAssertEqual(2.47, e.userX, accuracy: 1e-9); XCTAssertEqual(3.05, e.userZ, accuracy: 1e-9); XCTAssertEqual(-2.0, e.userYawDeg, accuracy: 1e-9)
        XCTAssertTrue(e.hasTarget); XCTAssertEqual(2.55, e.targetX, accuracy: 1e-9); XCTAssertEqual(3.05, e.targetZ, accuracy: 1e-9)
        XCTAssertEqual("why.left", e.whyId); XCTAssertEqual("Left wall not scanned yet", e.whyText)
        XCTAssertEqual([WallSeg(1.25, 4.0, 3.65, 4.0, 86), WallSeg(-0.5, 0.0, -0.5, 3.2, 12)], e.surfaces)
    }

    func testOverlayEmptySurfacesAndMalformed() {
        let e = overlay(
            #"{"ceiling_found":false,"completeness":0,"floor_found":false,"has_target":false,"mode":"sweep","seen":0,"surfaces":"","t_ns":0,"target_x":0,"target_z":0,"tracking":1,"type":"overlay","user_x":2.5,"user_yaw_deg":0,"user_z":2,"wall_found":false,"walls":0,"why_id":"why.sweep","why_text":"Looking for walls: sweep slowly"}"#)
        XCTAssertTrue(e.surfaces.isEmpty); XCTAssertFalse(e.hasTarget); XCTAssertEqual("sweep", e.mode)
        XCTAssertEqual([WallSeg(1.0, 2.0, 3.0, 4.0, 5)], EventParser.parseSurfaces("1,2,3,4,5;bad;1,2,3;x,y,z,w,v;"))
    }

    func testOverlayV2SixFieldSurfacesAndYawMask() {
        let e = overlay(
            #"{"ceiling_found":false,"completeness":0,"floor_found":false,"has_target":false,"mode":"sweep","seen":0,"surfaces":"1.25,4.00,3.65,4.00,86,2;-0.5,0.00,-0.5,3.20,12,1","t_ns":0,"target_x":0,"target_z":0,"tracking":1,"type":"overlay","user_x":2.5,"user_yaw_deg":0,"user_z":2,"wall_found":true,"walls":2,"why_id":"why.sweep","why_text":"x","yaw_mask":2049}"#)
        XCTAssertEqual([WallSeg(1.25, 4.0, 3.65, 4.0, 86, 2), WallSeg(-0.5, 0.0, -0.5, 3.2, 12, 1)], e.surfaces)
        XCTAssertEqual(2049, e.yawMask)
        // Mixed 5- and 6-field entries and a 7-field entry: 5 -> id 0, 6 -> id kept, 7 skipped.
        XCTAssertEqual([WallSeg(1.0, 2.0, 3.0, 4.0, 5, 0), WallSeg(1.0, 2.0, 3.0, 4.0, 5, 7)],
                       EventParser.parseSurfaces("1,2,3,4,5;1,2,3,4,5,7;1,2,3,4,5,7,9"))
        // Old core: no yaw_mask key -> 0, and 5-field surfaces still parse (v1 back-compat).
        let old = overlay(#"{"completeness":0,"mode":"sweep","surfaces":"1,2,3,4,5","tracking":1,"type":"overlay","why_id":"a","why_text":"b"}"#)
        XCTAssertEqual(0, old.yawMask)
        XCTAssertEqual([WallSeg(1.0, 2.0, 3.0, 4.0, 5)], old.surfaces)
        // Out-of-range mask bits are dropped.
        XCTAssertEqual(0xFFF, overlay(#"{"type":"overlay","surfaces":"","yaw_mask":65535}"#).yawMask)
    }

    func testPolicyDecode() {
        let p = Policy.from([3.0, 0.5, 0.25, 1.0, 0.0, 0.0, 0.0])
        XCTAssertEqual("LOWER_RESOLUTION", p.levelName)
        XCTAssertTrue(!p.overlay && !p.upload && !p.mustPause)
        XCTAssertTrue(Policy.from([5.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0]).mustPause)
    }

    func testOverlayV3SpansShellCeilingSeen() {
        let e = overlay(
            #"{"ceiling_found":false,"ceiling_seen":true,"completeness":0.5,"floor_found":true,"has_target":false,"mode":"sweep","seen":0.5,"shell":"0,0;4,0;4,3;0,3","shell_closed":true,"spans":"1,0,0,2,0,o;1,2,0,3,0,b;1,3,0,4,0,m;-1,4,0,4,3,o","surfaces":"0,0,4,0,60,1;4,0,4,3,80,2","t_ns":1,"target_x":0,"target_z":0,"tracking":1,"type":"overlay","user_x":1,"user_yaw_deg":0,"user_z":1,"wall_found":true,"walls":4,"why_id":"w","why_text":"x"}"#)
        XCTAssertTrue(e.layoutV3); XCTAssertTrue(e.shellClosed); XCTAssertTrue(e.ceilingSeen); XCTAssertEqual(4, e.walls)
        XCTAssertEqual([PlanPt(0, 0), PlanPt(4, 0), PlanPt(4, 3), PlanPt(0, 3)], e.shell)
        XCTAssertEqual(4, e.spans.count)
        XCTAssertEqual(SpanSeg(1, 2.0, 0.0, 3.0, 0.0, "b"), e.spans[1])
        XCTAssertEqual(-1, e.spans[3].id)
        XCTAssertEqual(["o", "b", "m", "o"] as [Character], e.spans.map { $0.state })
    }

    func testOverlayWithoutV3KeysKeepsDefaults() {
        let e = overlay(
            #"{"ceiling_found":false,"completeness":0,"floor_found":false,"has_target":false,"mode":"sweep","seen":0,"surfaces":"","t_ns":0,"target_x":0,"target_z":0,"tracking":1,"type":"overlay","user_x":0,"user_yaw_deg":0,"user_z":0,"wall_found":false,"walls":0,"why_id":"w","why_text":"x"}"#)
        XCTAssertTrue(!e.layoutV3 && !e.shellClosed && !e.ceilingSeen)
        XCTAssertTrue(e.spans.isEmpty && e.shell.isEmpty && e.objects.isEmpty && e.openings.isEmpty && e.gaps.isEmpty)
    }

    func testOverlayObjectsOpeningsGaps() {
        let e = overlay(
            #"{"ceiling_found":false,"completeness":0,"floor_found":false,"gap_why_id":"gap.occluded","gap_why_text":"behind the sofa","gaps":"occluded,1.5,2.0,0.8;missing_wall,0,4,0.5","has_target":false,"mode":"sweep","objects":"1,sofa,1.2,0.4,1.8,0.9,15,0.8;2,chair,3,1,0.5,0.5,0,0.9","openings":"door,W1,0,0,0.9,0,0,2;window,,4,1,4,2,0.9,1.9","seen":0,"surfaces":"","t_ns":0,"target_x":0,"target_z":0,"tracking":1,"type":"overlay","user_x":0,"user_yaw_deg":0,"user_z":0,"wall_found":false,"walls":0,"why_id":"w","why_text":"x"}"#)
        XCTAssertEqual(ObjectBox(1, "sofa", 1.2, 0.4, 1.8, 0.9, 15, 0.8), e.objects[0]); XCTAssertEqual(2, e.objects.count)
        XCTAssertEqual(Opening("door", "W1", 0.0, 0.0, 0.9, 0.0, 0.0, 2.0), e.openings[0]); XCTAssertEqual("", e.openings[1].wall)
        XCTAssertEqual(GapMark("occluded", 1.5, 2.0, 0.8), e.gaps[0]); XCTAssertEqual("behind the sofa", e.gapWhyText)
    }

    func testReviewHandOverEncodersRoundTrip() {
        let shell = [PlanPt(0, 0), PlanPt(4.5, 0), PlanPt(4.5, -3.25)]
        XCTAssertEqual(shell, EventParser.parseShell(EventParser.encodeShell(shell)))
        let spans = [SpanSeg(2, 0, 0, 1.5, 0, "b"), SpanSeg(-1, 1.5, 0, 4.5, 0, "m")]
        XCTAssertEqual(spans, EventParser.parseSpans(EventParser.encodeSpans(spans)))
        let objs = [ObjectBox(3, "sofa", 1.0, 2.0, 1.8, 0.9, 30, 0.8)]
        XCTAssertEqual(objs, EventParser.parseObjects(EventParser.encodeObjects(objs)))
        let ops = [Opening("door", "W1", 0, 0, 0.9, 0, 0, 2), Opening("window", "", 4, 1, 4, 2, 0.9, 1.9)]
        XCTAssertEqual(ops, EventParser.parseOpenings(EventParser.encodeOpenings(ops)))
        XCTAssertEqual([PlanPt](), EventParser.parseShell(EventParser.encodeShell([])))
    }

    func testMalformedV3RowsAreSkipped() {
        XCTAssertTrue(EventParser.parseSpans("").isEmpty)
        XCTAssertEqual(1, EventParser.parseSpans("1,0,0,1,0,o;1,0,0,1,0,x;a,0,0,1,0,o;1,0,0,1,o;").count)
        XCTAssertEqual(1, EventParser.parseShell("1,2;x,3;4").count)
        XCTAssertEqual(1, EventParser.parseObjects("1,sofa,0,0,1,1,0,1;1,sofa,0,0,1,1,0;1,sofa,q,0,1,1,0,1").count)
        XCTAssertEqual(0, EventParser.parseOpenings("door,W1,0,0,1,0,0").count)
        XCTAssertEqual(0, EventParser.parseGaps("occluded,1,two,0.5").count)
    }

    func testTrackingRecoveryEvents() {
        // Exactly as the core writes them (sorted keys); t_ns keeps all 64 bits.
        let lost = EventParser.parseLine(#"{"degraded_s":2.013,"reason":3,"t_ns":9007199254740993,"tracking_state":2,"type":"tracking_lost"}"#)
        XCTAssertEqual(.trackingLost(tNs: 9007199254740993, trackingState: 2, reason: 3, degradedS: 2.013), lost)
        let reset = EventParser.parseLine(#"{"drift_deg":4.5,"drift_m":0.123,"lost_s":3.5,"t_ns":12000000000,"type":"tracking_reset"}"#)
        XCTAssertEqual(.trackingReset(tNs: 12_000_000_000, lostS: 3.5, driftM: 0.123, driftDeg: 4.5), reset)
        XCTAssertNil(EventParser.parseLine(#"{"type":"tracking_lost","reason":3}"#))   // no t_ns: malformed, skipped
    }
}
