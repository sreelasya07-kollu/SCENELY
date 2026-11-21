package dev.capturekit.segment

import dev.capturekit.capture.ObjectBox
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class ObjectBoxesTest {
    /** Camera 1.5 m up at the origin looking down world -Z, 640 x 480. */
    private val cam = CameraSnapshot(1.0, 0.0, 0.0, 0.0, 0.0, 1.5, 0.0, 500.0, 500.0, 320.0, 240.0, 640, 480)
    private fun yawed(deg: Double): CameraSnapshot { val h = Math.toRadians(deg) / 2; return cam.copy(qw = cos(h), qy = sin(h)) }
    private fun movedBack(m: Double) = cam.copy(tz = m)

    private val chairAt = Vec3(0f, 1.0f, -2f)   // 2 m straight ahead
    private fun chair(centre: Vec3?, camera: CameraSnapshot = cam, t: Long = 0): SegResult {
        // The instance centroid is where the centre projects, the box is 100 x 150 px around it.
        val uv = centre?.let { camera.project(it) } ?: floatArrayOf(320f, 240f)
        return SegResult(t, camera, listOf(Instance(62, "chair", 0.9f, Box2(uv[0] - 50, uv[1] - 75, uv[0] + 50, uv[1] + 75), uv[0], uv[1])))
    }
    /** Hit test of a world where the only surface is a sphere-ish blob at [at]: returns it when the ray passes within 0.3 m. */
    private fun hitAt(at: Vec3): (FloatArray, FloatArray) -> Vec3? = { o, d ->
        val t = (at.x - o[0]) * d[0] + (at.y - o[1]) * d[1] + (at.z - o[2]) * d[2]
        val px = o[0] + t * d[0]; val py = o[1] + t * d[1]; val pz = o[2] + t * d[2]
        if (t > 0 && Vec3(px, py, pz).dist(at) < 0.3f) at else null
    }
    private val none: (FloatArray, FloatArray) -> Vec3? = { _, _ -> null }

    @Test fun aSegmentedObjectGetsASolidGreenBoxWithLabelAndId() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        val boxes = t.drawBoxes(cam, 1100)
        val b = boxes.single()
        assertEquals("chair #1", b.text); assertTrue(b.solid)
        assertEquals(320f, (b.box.x0 + b.box.x1) / 2, 0.5f); assertEquals(100f, b.box.x1 - b.box.x0, 0.5f)
        val o = t.objects(1100).single()
        assertEquals(1, o.seenCount); assertEquals(chairAt, o.centreWorld); assertEquals(LiveState.VISIBLE, o.state); assertEquals(62, o.cocoId)
    }

    @Test fun theBoxFollowsTheCameraAndScalesWithDepth() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        val a = t.drawBoxes(cam, 1100).single().box
        // Step 1 m back (twice as far): the same width halves, the centre stays on the axis.
        val b = t.drawBoxes(movedBack(2.0), 1100).single().box
        assertEquals(100f, a.x1 - a.x0, 0.5f); assertEquals(50f, b.x1 - b.x0, 0.5f)
        // Turn the camera right: the chair slides left in the image.
        val c = t.drawBoxes(yawed(-10.0), 1100).single().box
        assertTrue((c.x0 + c.x1) / 2 < 320f - 50f)
    }

    @Test fun sameIdAfterLeavingAndReEnteringView() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        val id = t.objects(1000).single().trackId
        // Turn away: the chair projects outside the image, nothing is drawn, but the track is remembered (dashed state).
        val away = yawed(120.0)
        assertTrue(t.drawBoxes(away, 5000).isEmpty())
        val remembered = t.objects(5000).single()
        assertEquals(LiveState.REMEMBERED, remembered.state)
        // Other objects are seen meanwhile.
        t.apply(SegResult(2000, away, listOf(Instance(63, "couch", 0.8f, Box2(0f, 0f, 100f, 100f), 50f, 50f))), 2000, none)
        // Turn back: its centre projects into the image again; drawn dashed with the "seen" tag, same id.
        val back = t.drawBoxes(cam, 6000).single()
        assertEquals("chair #$id seen", back.text); assertFalse(back.solid)
        // A new sighting from a slightly different viewpoint re-identifies by 3D centre and gets the same id.
        val moved = cam.copy(tx = 0.4)
        t.apply(chair(chairAt, moved, 9000), 7000, hitAt(chairAt))
        val chairs = t.objects(7000).filter { it.label == "chair" }
        assertEquals(1, chairs.size)
        assertEquals(id, chairs[0].trackId); assertEquals(2, chairs[0].seenCount); assertEquals(LiveState.VISIBLE, chairs[0].state)
        assertEquals(2, t.objects(7000).map { it.trackId }.toSet().size)   // chair + couch
    }

    @Test fun aCentreBehindTheCameraGivesNoBox() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        val around = cam.copy(qw = 0.0, qy = 1.0)       // turned 180 deg: the chair is behind
        assertTrue(t.drawBoxes(around, 1100).isEmpty())
        assertEquals(1, t.objects(1100).size)           // still remembered
    }

    @Test fun withoutACentreTheBoxLivesHalfASecond() {
        val t = LiveObjectTracker()
        t.apply(chair(null), 1000, none)
        assertNull(t.objects(1000).single().centreWorld)
        assertEquals(1, t.drawBoxes(cam, 1000 + LiveObjectTracker.NO_CENTRE_MS).size)
        assertTrue(t.drawBoxes(cam, 1000 + LiveObjectTracker.NO_CENTRE_MS + 1).isEmpty())
    }

    @Test fun aStaleResultIsRememberedNotSeen() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        assertTrue(t.drawBoxes(cam, 1000 + LiveObjectTracker.FRESH_MS).single().solid)
        assertFalse(t.drawBoxes(cam, 1001 + LiveObjectTracker.FRESH_MS).single().solid)
    }

    @Test fun anEmptyResultTurnsEverythingIntoMemory() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        t.apply(SegResult(2000, cam, emptyList()), 1200, none)
        val b = t.drawBoxes(cam, 1300).single()
        assertFalse(b.solid); assertTrue(b.text.endsWith("seen"))
    }

    @Test fun aLiftedCoreBoxReplacesTheTrackBoxWhenLabelAndCentreMatch() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        // Core chair 0.9 m tall on the floor (y 0): centre y 0.45; track centre (0, 1.0, -2) is 0.55 m away.
        val core = ObjectBox(4, "chair", 0.0, -2.0, 0.5, 0.5, 0, 0.9)
        val used = t.drawBoxes(cam, 1100, listOf(core), 0f).single().box
        assertEquals(MaskMath.objectBox(cam, core, 0f), used)
        // Wrong class, or too far: the track's own box.
        val own = t.drawBoxes(cam, 1100).single().box
        assertEquals(own, t.drawBoxes(cam, 1100, listOf(core.copy(cls = "couch")), 0f).single().box)
        assertEquals(own, t.drawBoxes(cam, 1100, listOf(core.copy(x = 1.0)), 0f).single().box)
        assertNotEquals(own, used)
        assertEquals(own, t.drawBoxes(cam, 1100, listOf(core), null).single().box)   // no floor height: no core box
    }

    @Test fun aHitTestMissKeepsTheRememberedCentreAndScalesWithDepth() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        // Next sighting: same place in the image, but the hit test finds nothing. The track keeps its centre and depth.
        t.apply(chair(chairAt, cam, 1), 1200, none)
        val o = t.objects(1200).single()
        assertEquals(chairAt, o.centreWorld); assertEquals(2, o.seenCount)
        assertEquals(100f, t.drawBoxes(cam, 1300).single().box.let { it.x1 - it.x0 }, 0.5f)
        assertEquals(50f, t.drawBoxes(movedBack(2.0), 1300).single().box.let { it.x1 - it.x0 }, 0.5f)   // scaled by the remembered depth
    }

    @Test fun clearForgetsEverything() {
        val t = LiveObjectTracker()
        t.apply(chair(chairAt), 1000, hitAt(chairAt))
        t.clear()
        assertTrue(t.objects(1000).isEmpty()); assertFalse(t.any)
    }
}
