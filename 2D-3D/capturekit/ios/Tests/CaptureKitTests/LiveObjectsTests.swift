import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin ObjectBoxesTest (contract C2 projection, ADR 0035).
final class LiveObjectsTests: XCTestCase {
    /// Camera 1.5 m up at the origin looking down world -Z, 640 x 480.
    private let cam = CameraSnapshot(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 1.5, tz: 0, fx: 500, fy: 500, cx: 320, cy: 240, w: 640, h: 480)

    private func yawed(_ deg: Double) -> CameraSnapshot {
        var c = cam
        let h = deg * Double.pi / 180 / 2
        c.qw = cos(h); c.qy = sin(h)
        return c
    }
    private func movedBack(_ m: Double) -> CameraSnapshot { var c = cam; c.tz = m; return c }

    private let chairAt = Vec3(0, 1.0, -2)   // 2 m straight ahead

    private func chair(_ centre: Vec3?, camera: CameraSnapshot? = nil, t: Int64 = 0) -> SegResult {
        let camera = camera ?? cam
        // The instance centroid is where the centre projects, the box is 100 x 150 px around it.
        let uv = centre.flatMap { camera.project($0) } ?? (u: Float(320), v: Float(240))
        return SegResult(tNs: t, camera: camera, instances: [
            Instance(coco: 62, label: "chair", score: 0.9, box: Box2(uv.u - 50, uv.v - 75, uv.u + 50, uv.v + 75), cx: uv.u, cy: uv.v),
        ])
    }

    /// Hit test of a world where the only surface is a blob at `at`: returns it when the ray passes within 0.3 m.
    private func hitAt(_ at: Vec3) -> (Vec3, Vec3) -> Vec3? {
        { o, d in
            let t = (at.x - o.x) * d.x + (at.y - o.y) * d.y + (at.z - o.z) * d.z
            let p = Vec3(o.x + t * d.x, o.y + t * d.y, o.z + t * d.z)
            return (t > 0 && p.dist(at) < 0.3) ? at : nil
        }
    }
    private let none: (Vec3, Vec3) -> Vec3? = { _, _ in nil }

    func testASegmentedObjectGetsASolidGreenBoxWithLabelAndId() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        let boxes = t.drawBoxes(cam, nowMs: 1100)
        XCTAssertEqual(1, boxes.count)
        let b = boxes[0]
        XCTAssertEqual("chair #1", b.text); XCTAssertTrue(b.solid)
        XCTAssertEqual(320, (b.box.x0 + b.box.x1) / 2, accuracy: 0.5); XCTAssertEqual(100, b.box.x1 - b.box.x0, accuracy: 0.5)
        let o = t.objects(nowMs: 1100)[0]
        XCTAssertEqual(1, o.seenCount); XCTAssertEqual(chairAt, o.centreWorld); XCTAssertEqual(.visible, o.state); XCTAssertEqual(62, o.cocoId)
    }

    func testTheBoxFollowsTheCameraAndScalesWithDepth() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        let a = t.drawBoxes(cam, nowMs: 1100)[0].box
        // Step 2 m back (twice as far): the same width halves, the centre stays on the axis.
        let b = t.drawBoxes(movedBack(2.0), nowMs: 1100)[0].box
        XCTAssertEqual(100, a.x1 - a.x0, accuracy: 0.5); XCTAssertEqual(50, b.x1 - b.x0, accuracy: 0.5)
        // Turn the camera right: the chair slides left in the image.
        let c = t.drawBoxes(yawed(-10.0), nowMs: 1100)[0].box
        XCTAssertTrue((c.x0 + c.x1) / 2 < 320 - 50)
    }

    func testSameIdAfterLeavingAndReEnteringView() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        let id = t.objects(nowMs: 1000)[0].trackId
        // Turn away: the chair projects outside the image, nothing is drawn, but the track is remembered (dashed state).
        let away = yawed(120.0)
        XCTAssertTrue(t.drawBoxes(away, nowMs: 5000).isEmpty)
        XCTAssertEqual(.remembered, t.objects(nowMs: 5000)[0].state)
        // Other objects are seen meanwhile.
        t.apply(SegResult(tNs: 2000, camera: away, instances: [Instance(coco: 63, label: "couch", score: 0.8, box: Box2(0, 0, 100, 100), cx: 50, cy: 50)]),
                nowMs: 2000, hit: none)
        // Turn back: its centre projects into the image again; drawn dashed with the "seen" tag, same id.
        let back = t.drawBoxes(cam, nowMs: 6000)
        XCTAssertEqual(1, back.count)
        XCTAssertEqual("chair #\(id) seen", back[0].text); XCTAssertFalse(back[0].solid)
        // A new sighting from a slightly different viewpoint re-identifies by 3D centre and gets the same id.
        var moved = cam
        moved.tx = 0.4
        t.apply(chair(chairAt, camera: moved, t: 9000), nowMs: 7000, hit: hitAt(chairAt))
        let chairs = t.objects(nowMs: 7000).filter { $0.label == "chair" }
        XCTAssertEqual(1, chairs.count)
        XCTAssertEqual(id, chairs[0].trackId); XCTAssertEqual(2, chairs[0].seenCount); XCTAssertEqual(.visible, chairs[0].state)
        XCTAssertEqual(2, Set(t.objects(nowMs: 7000).map { $0.trackId }).count)   // chair + couch
    }

    func testACentreBehindTheCameraGivesNoBox() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        var around = cam
        around.qw = 0; around.qy = 1       // turned 180 deg: the chair is behind
        XCTAssertTrue(t.drawBoxes(around, nowMs: 1100).isEmpty)
        XCTAssertEqual(1, t.objects(nowMs: 1100).count)   // still remembered
    }

    func testWithoutACentreTheBoxLivesHalfASecond() {
        let t = LiveObjectTracker()
        t.apply(chair(nil), nowMs: 1000, hit: none)
        XCTAssertNil(t.objects(nowMs: 1000)[0].centreWorld)
        XCTAssertEqual(1, t.drawBoxes(cam, nowMs: 1000 + LiveObjectTracker.noCentreMs).count)
        XCTAssertTrue(t.drawBoxes(cam, nowMs: 1000 + LiveObjectTracker.noCentreMs + 1).isEmpty)
    }

    func testAStaleResultIsRememberedNotSeen() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        XCTAssertTrue(t.drawBoxes(cam, nowMs: 1000 + LiveObjectTracker.freshMs)[0].solid)
        XCTAssertFalse(t.drawBoxes(cam, nowMs: 1001 + LiveObjectTracker.freshMs)[0].solid)
    }

    func testAnEmptyResultTurnsEverythingIntoMemory() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        t.apply(SegResult(tNs: 2000, camera: cam, instances: []), nowMs: 1200, hit: none)
        let b = t.drawBoxes(cam, nowMs: 1300)[0]
        XCTAssertFalse(b.solid); XCTAssertTrue(b.text.hasSuffix("seen"))
    }

    func testALiftedCoreBoxReplacesTheTrackBoxWhenLabelAndCentreMatch() throws {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        // Core chair 0.9 m tall on the floor (y 0): centre y 0.45; track centre (0, 1.0, -2) is 0.55 m away.
        let core = ObjectBox(4, "chair", 0.0, -2.0, 0.5, 0.5, 0, 0.9)
        let used = t.drawBoxes(cam, nowMs: 1100, core: [core], floorY: 0)[0].box
        XCTAssertEqual(MaskMath.objectBox(cam, core, floorY: 0), used)
        // Wrong class, or too far: the track's own box.
        let own = t.drawBoxes(cam, nowMs: 1100)[0].box
        var couch = core; couch.cls = "couch"
        var far = core; far.x = 1.0
        XCTAssertEqual(own, t.drawBoxes(cam, nowMs: 1100, core: [couch], floorY: 0)[0].box)
        XCTAssertEqual(own, t.drawBoxes(cam, nowMs: 1100, core: [far], floorY: 0)[0].box)
        XCTAssertNotEqual(own, used)
        XCTAssertEqual(own, t.drawBoxes(cam, nowMs: 1100, core: [core], floorY: nil)[0].box)   // no floor height: no core box
    }

    func testClearForgetsEverything() {
        let t = LiveObjectTracker()
        t.apply(chair(chairAt), nowMs: 1000, hit: hitAt(chairAt))
        t.clear()
        XCTAssertTrue(t.objects(nowMs: 1000).isEmpty); XCTAssertFalse(t.any)
    }
}

/// Ported 1:1 from Kotlin CompletenessTest (contract C3).
final class CompletenessTests: XCTestCase {
    private func overlay(_ completeness: Double, spans: [SpanSeg] = [], gaps: [GapMark] = []) -> OverlayEvent {
        var o = OverlayEvent()
        o.completeness = completeness; o.tracking = 1; o.mode = "scan"; o.wallFound = true; o.floorFound = true; o.ceilingFound = true
        o.walls = 4; o.layoutV3 = true; o.spans = spans; o.gaps = gaps
        return o
    }

    private func live(_ id: Int, _ label: String, _ seen: Int, _ centre: Vec3? = nil) -> LiveObject {
        LiveObject(trackId: id, label: label, cocoId: 62, score: 0.9, boxImg: nil, centreWorld: centre, seenCount: seen,
                   firstSeenNs: 0, lastSeenNs: 0, state: .visible)
    }

    func testFormulaWeighsRoomEightyAndObjectsTwenty() {
        XCTAssertEqual(80, Completeness.pct(room: 1.0, confirmed: 0, tracks: 5))   // all room, no object confirmed
        XCTAssertEqual(100, Completeness.pct(room: 1.0, confirmed: 5, tracks: 5))
        XCTAssertEqual(60, Completeness.pct(room: 0.5, confirmed: 5, tracks: 5))   // 0.4 + 0.2
        XCTAssertEqual(40, Completeness.pct(room: 0.5, confirmed: 0, tracks: 4))
        XCTAssertEqual(45, Completeness.pct(room: 0.5, confirmed: 1, tracks: 4))   // 0.4 + 0.2 * 0.25
    }

    func testWithoutTracksTheOverlayAloneDecides() {
        XCTAssertEqual(63, Completeness.pct(room: 0.63, confirmed: 0, tracks: 0))
        XCTAssertEqual(0, Completeness.pct(room: .nan, confirmed: 0, tracks: 0))
        XCTAssertEqual(100, Completeness.pct(room: 7.0, confirmed: 0, tracks: 0))   // clamped
        XCTAssertEqual(0, Completeness.compute(nil, live: []).completenessPct)
    }

    func testObjectsAreConfirmedAfterThreeSightings() {
        let s = Completeness.compute(overlay(0.5), live: [live(1, "chair", 2), live(2, "couch", 3)])
        XCTAssertEqual([false, true], s.objects.map { $0.confirmed })
        XCTAssertEqual(Completeness.pct(room: 0.5, confirmed: 1, tracks: 2), s.completenessPct)
        XCTAssertEqual(50, s.roomPct)
    }

    func testWeakZonesFromMissingSpansGapsAndUnconfirmedObjects() {
        let spans = [
            SpanSeg(2, 0, 0, 2, 0, "o"), SpanSeg(2, 2, 0, 4, 0, "m"),   // wall 2: half missing
            SpanSeg(3, 0, 0, 0, 3, "b"),                                  // blocked is never demanded
            SpanSeg(5, 0, 0, 0, 3, "m"),                                  // wall 5: fully missing
        ]
        let gaps = [GapMark("behind_furniture", 1.0, 2.0, 0.3)]
        let s = Completeness.compute(overlay(0.7, spans: spans, gaps: gaps), live: [live(7, "chair", 1, Vec3(1, 0.5, 2)), live(8, "couch", 5)])
        let z = s.weakZones
        XCTAssertEqual(["wall_span", "wall_span", "object", "gap"], z.map { $0.kind })   // by priority: 1.0, 0.8, 0.5, 0.3
        XCTAssertEqual(5, z[0].wallId); XCTAssertEqual("Scan wall 5 again", z[0].text)
        XCTAssertEqual(2, z[1].wallId); XCTAssertEqual(3.0, z[1].x!, accuracy: 1e-9)       // centre of the missing span
        XCTAssertEqual("Look at the chair again", z[2].text); XCTAssertEqual(1.0, z[2].x!, accuracy: 1e-9)
        XCTAssertEqual("Look at the unseen area (behind furniture)", z[3].text)
        XCTAssertTrue(z.allSatisfy { $0.wallId != 3 })
    }

    func testZonesAreCappedAndAGoodScanHasNone() {
        let many = (1...20).map { GapMark("g", Double($0), 0.0, 0.5) }
        XCTAssertEqual(Completeness.maxZones, Completeness.compute(overlay(0.3, gaps: many), live: []).weakZones.count)
        XCTAssertTrue(Completeness.compute(overlay(1.0), live: [live(1, "chair", 4)]).weakZones.isEmpty)
    }

    func testReviewSummaryJsonFollowsContractC3() {
        let s = Completeness.Summary(completenessPct: 71, roomPct: 70,
                                     objects: [Completeness.ObjectEntry(trackId: 3, label: "chair \"x\"", seenCount: 2, confirmed: false)],
                                     weakZones: [Completeness.WeakZone(kind: "wall_span", wallId: 4, x: 1.234, z: nil, text: "Scan wall 4 again", pri: 0.9)])
        let j = Completeness.toJSON(s)
        XCTAssertEqual("{\"completeness_pct\":71,\"room_pct\":70,\"objects\":[{\"track_id\":3,\"label\":\"chair \\\"x\\\"\",\"seen_count\":2,\"confirmed\":false}]," +
                       "\"weak_zones\":[{\"kind\":\"wall_span\",\"wall_id\":4,\"x\":1.23,\"z\":null,\"text\":\"Scan wall 4 again\",\"pri\":0.9}]}", j)
        XCTAssertEqual("{\"completeness_pct\":0,\"room_pct\":0,\"objects\":[],\"weak_zones\":[]}", Completeness.toJSON(Completeness.compute(nil, live: [])))
        XCTAssertFalse(j.contains("NaN"))
        XCTAssertEqual("ck.review_summary", Completeness.extra)
    }
}
