import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin TrackMemoryTest (incl. the seenCount / snapshot case) and the camera math cases of MaskMathTest.
final class TrackMemoryTests: XCTestCase {
    private func chair(_ key: TrackKey?, centre: Vec3? = nil, box: Box2? = nil) -> SegPrompt {
        SegPrompt(key: key, kind: .object, label: "chair", x: 10, y: 10, box: box, centre: centre)
    }
    private func floor(_ id: Int64, centre: Vec3? = nil, box: Box2? = nil) -> SegPrompt {
        SegPrompt(key: .plane(id), kind: .floor, label: "Floor", x: 5, y: 5, box: box, centre: centre)
    }
    private func one(_ t: [Track]) -> Track { XCTAssertEqual(1, t.count); return t[0] }

    func testSameObjectLeavesAndReturnsKeepsIdAndColour() {
        let m = TrackMemory()
        let first = one(m.assign([chair(.coreObject(7), centre: Vec3(1, 0.4, 2))]))
        for _ in 0..<20 { m.assign([floor(1)]) }   // the chair is out of view for 20 runs
        let back = one(m.assign([chair(.coreObject(7), centre: Vec3(1.05, 0.4, 2))]))
        XCTAssertEqual(first.id, back.id)
        XCTAssertEqual(first.color, back.color)
        XCTAssertEqual("chair", back.label)
    }

    func testUnkeyedObjectReturnsByCentreDistance() {
        let m = TrackMemory()
        let a = one(m.assign([chair(nil, centre: Vec3(1, 0.4, 2), box: Box2(0, 0, 50, 50))]))
        for _ in 0..<5 { m.assign([floor(1)]) }
        // Re-entering the view from the other side: the box is elsewhere, the 3D centre is close.
        let b = one(m.assign([chair(nil, centre: Vec3(1.2, 0.4, 2.1), box: Box2(400, 300, 460, 360))]))
        XCTAssertEqual(a.id, b.id)
        let far = one(m.assign([chair(nil, centre: Vec3(4, 0.4, -2), box: Box2(400, 300, 460, 360))]))
        XCTAssertNotEqual(a.id, far.id)
    }

    func testIouFallbackWithoutCentre() {
        let m = TrackMemory()
        let a = one(m.assign([chair(nil, box: Box2(100, 100, 200, 200))]))
        let b = one(m.assign([chair(nil, box: Box2(110, 105, 210, 205))]))
        XCTAssertEqual(a.id, b.id)
        let c = one(m.assign([chair(nil, box: Box2(400, 400, 450, 450))]))
        XCTAssertNotEqual(a.id, c.id)
    }

    func testDifferentLabelOrKindNeverMerges() {
        let m = TrackMemory()
        let a = one(m.assign([chair(nil, centre: Vec3(1, 0.4, 2), box: Box2(0, 0, 50, 50))]))
        let t = one(m.assign([SegPrompt(key: nil, kind: .object, label: "table", x: 10, y: 10, box: Box2(0, 0, 50, 50), centre: Vec3(1, 0.4, 2))]))
        XCTAssertNotEqual(a.id, t.id)
    }

    func testDistinctKeysAreDistinctTracksEvenWhenClose() {
        let m = TrackMemory()
        let r = m.assign([chair(.coreObject(1), centre: Vec3(1, 0.4, 2)), chair(.coreObject(2), centre: Vec3(1.1, 0.4, 2))])
        XCTAssertNotEqual(r[0].id, r[1].id)
        let again = one(m.assign([chair(.coreObject(2), centre: Vec3(1, 0.4, 2))]))
        XCTAssertEqual(r[1].id, again.id)
    }

    func testOneTrackPerPromptPerRun() {
        let m = TrackMemory()
        let c = Vec3(1, 0.4, 2)
        let r = m.assign([chair(nil, centre: c), chair(nil, centre: c)])
        XCTAssertNotEqual(r[0].id, r[1].id)
        let r2 = m.assign([chair(nil, centre: c), chair(nil, centre: c)])
        XCTAssertEqual(Set([r[0].id, r[1].id]), Set([r2[0].id, r2[1].id]))
    }

    func testKeyedPromptAdoptsUnkeyedTrackThenKeepsIt() {
        let m = TrackMemory()
        let a = one(m.assign([chair(nil, centre: Vec3(1, 0.4, 2))]))
        let b = one(m.assign([chair(.coreObject(5), centre: Vec3(1.1, 0.4, 2))]))
        XCTAssertEqual(a.id, b.id)
        let c = one(m.assign([chair(.coreObject(5), centre: Vec3(3, 0.4, 5))]))   // the core moved it: key wins
        XCTAssertEqual(a.id, c.id)
    }

    func testLruBoundEvictsLeastRecentlySeen() {
        let m = TrackMemory(capacity: 3)
        let ids = (1...3).map { one(m.assign([chair(.coreObject($0))])).id }
        m.assign([chair(.coreObject(1))])            // touch 1: now 2 is the oldest
        m.assign([chair(.coreObject(4))])            // evicts 2
        XCTAssertEqual(3, m.size)
        XCTAssertEqual(ids[0], one(m.assign([chair(.coreObject(1))])).id)
        XCTAssertEqual(ids[2], one(m.assign([chair(.coreObject(3))])).id)
        let two = one(m.assign([chair(.coreObject(2))])).id
        XCTAssertNotEqual(ids[1], two)               // forgotten: a new id, never a reused one
        XCTAssertEqual(3, m.size)
    }

    func testPlaneIdStableWhileItsBoxAndCentreMove() {
        let m = TrackMemory()
        let a = one(m.assign([floor(42, centre: Vec3(0, 0, 0), box: Box2(0, 300, 640, 480))]))
        let b = one(m.assign([floor(42, centre: Vec3(3, 0, 4), box: Box2(0, 0, 100, 50))]))   // grew / re-centred
        XCTAssertEqual(a.id, b.id)
        let other = one(m.assign([floor(43, centre: Vec3(3, 0, 4), box: Box2(0, 0, 100, 50))]))
        XCTAssertNotEqual(a.id, other.id)
        XCTAssertEqual(.floor, other.kind)
        let wall = one(m.assign([SegPrompt(key: .layoutWall(3), kind: .wall, label: "Wall", x: 1, y: 1)]))
        XCTAssertEqual(wall.id, one(m.assign([SegPrompt(key: .layoutWall(3), kind: .wall, label: "Wall", x: 300, y: 9)])).id)
    }

    func testColourIsAFunctionOfTheIdAndNeighboursDiffer() {
        let m = TrackMemory()
        let t = m.assign((1...4).map { chair(.coreObject($0)) })
        for i in 1..<t.count { XCTAssertNotEqual(t[i - 1].color, t[i].color) }
        for x in t { XCTAssertEqual(TrackMemory.colorFor(x.id), x.color) }
    }

    func testSeenCountAndSnapshotTrackEverySighting() {
        let m = TrackMemory()
        func live(_ c: Vec3, _ t: Int64) -> Track {
            one(m.assign([SegPrompt(key: nil, kind: .object, label: "chair", x: 1, y: 1, box: nil, centre: c, cocoId: 62, score: 0.8)], tNs: t))
        }
        let a = live(Vec3(1, 0.4, 2), 100)
        _ = live(Vec3(1.1, 0.4, 2), 200)
        let back = live(Vec3(1.0, 0.4, 2.1), 900)
        XCTAssertEqual(a.id, back.id)
        let snap = m.snapshot()
        XCTAssertEqual(1, snap.count)
        let s = snap[0]
        XCTAssertEqual(3, s.seenCount); XCTAssertEqual(100, s.firstSeenNs); XCTAssertEqual(900, s.lastSeenNs)
        XCTAssertEqual(62, s.cocoId); XCTAssertEqual(0.8, s.score, accuracy: 1e-6)
        XCTAssertEqual(Vec3(1.0, 0.4, 2.1), s.centre)
        // A run without that chair does not count as a sighting.
        m.assign([floor(1)], tNs: 1000)
        XCTAssertEqual(3, m.snapshot().first { $0.label == "chair" }!.seenCount)
    }

    func testBoxIou() {
        XCTAssertEqual(1, Box2(0, 0, 10, 10).iou(Box2(0, 0, 10, 10)), accuracy: 1e-6)
        XCTAssertEqual(0, Box2(0, 0, 10, 10).iou(Box2(20, 20, 30, 30)), accuracy: 1e-6)
        XCTAssertEqual(25.0 / 175.0, Box2(0, 0, 10, 10).iou(Box2(5, 5, 15, 15)), accuracy: 1e-6)
    }
}

final class CameraSnapshotTests: XCTestCase {
    /// Camera 1.5 m up at the origin looking down world -Z (identity rotation), 640 x 480.
    private let cam = CameraSnapshot(qw: 1, qx: 0, qy: 0, qz: 0, tx: 0, ty: 1.5, tz: 0, fx: 500, fy: 500, cx: 320, cy: 240, w: 640, h: 480)

    private func yawed(_ deg: Double) -> CameraSnapshot {
        var c = cam
        let h = deg * Double.pi / 180 / 2
        c.qw = cos(h); c.qy = sin(h)
        return c
    }

    func testProjectFollowsOpenCvImageAxes() throws {
        let c = try XCTUnwrap(cam.project(Vec3(0, 1.5, -2)))
        XCTAssertEqual(320, c.u, accuracy: 1e-3); XCTAssertEqual(240, c.v, accuracy: 1e-3)
        let ru = try XCTUnwrap(cam.project(Vec3(1, 2.5, -2)))
        XCTAssertEqual(320 + 250, ru.u, accuracy: 1e-3)   // world +X = image right
        XCTAssertEqual(240 - 250, ru.v, accuracy: 1e-3)   // world up = image up (smaller v)
        XCTAssertNil(cam.project(Vec3(0, 1.5, 2)))        // behind
    }

    func testRayThroughThePrincipalPointLooksDownMinusZAndRoundTripsProject() throws {
        let r = cam.ray(320, 240)
        XCTAssertEqual(0, r.origin.x, accuracy: 1e-6); XCTAssertEqual(1.5, r.origin.y, accuracy: 1e-6)
        XCTAssertEqual(-1, r.direction.z, accuracy: 1e-6)
        let cam2 = yawed(25)
        let r2 = cam2.ray(100, 400)
        let p = Vec3(r2.origin.x + 3 * r2.direction.x, r2.origin.y + 3 * r2.direction.y, r2.origin.z + 3 * r2.direction.z)
        let uv = try XCTUnwrap(cam2.project(p))
        XCTAssertEqual(100, uv.u, accuracy: 0.05); XCTAssertEqual(400, uv.v, accuracy: 0.05)
        XCTAssertGreaterThan(cam2.depthOf(p), 0)
    }

    func testColumnMajorInitMatchesTheQuaternionCamera() throws {
        // ARKit camera.transform for a yaw of 30 degrees about +Y and translation (1, 2, 3), column-major.
        let a = 30.0 * Double.pi / 180
        let c = Float(cos(a)), s = Float(sin(a))
        let m: [Float] = [c, 0, -s, 0,   0, 1, 0, 0,   s, 0, c, 0,   1, 2, 3, 1]
        let cm = CameraSnapshot(columnMajor: m, fx: 500, fy: 500, cx: 320, cy: 240, w: 640, h: 480)
        let q = CameraSnapshot(qw: cos(a / 2), qx: 0, qy: sin(a / 2), qz: 0, tx: 1, ty: 2, tz: 3, fx: 500, fy: 500, cx: 320, cy: 240, w: 640, h: 480)
        let p = Vec3(0.5, 2.2, -4)
        let u1 = try XCTUnwrap(cm.project(p)), u2 = try XCTUnwrap(q.project(p))
        XCTAssertEqual(u2.u, u1.u, accuracy: 0.05); XCTAssertEqual(u2.v, u1.v, accuracy: 0.05)
        // A 180 degree turn about X (trace < 0 branch) is a valid rotation too.
        let flip: [Float] = [1, 0, 0, 0,   0, -1, 0, 0,   0, 0, -1, 0,   0, 0, 0, 1]
        let f = CameraSnapshot(columnMajor: flip, fx: 1, fy: 1, cx: 0, cy: 0, w: 10, h: 10)
        XCTAssertEqual(1, (f.qw * f.qw + f.qx * f.qx + f.qy * f.qy + f.qz * f.qz), accuracy: 1e-9)
        XCTAssertEqual(1, abs(f.qx), accuracy: 1e-9)
    }

    func testObjectBoxProjectsTheLiftedFootprint() throws {
        let chair = ObjectBox(9, "chair", 0.2, -2.5, 0.5, 0.5, 0, 0.9)
        let b = try XCTUnwrap(MaskMath.objectBox(cam, chair, floorY: 0))
        XCTAssertTrue(b.x0 < 320 && b.x1 > 320 - 100)
        var behind = chair
        behind.z = 4.0
        XCTAssertNil(MaskMath.objectBox(cam, behind, floorY: 0))   // behind the camera: no box
    }
}
