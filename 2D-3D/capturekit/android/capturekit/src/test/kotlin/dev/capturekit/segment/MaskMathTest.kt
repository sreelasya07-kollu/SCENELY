package dev.capturekit.segment

import dev.capturekit.capture.ObjectBox
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class MaskMathTest {
    /** Camera 1.5 m up at the origin looking down world -Z (identity rotation), 640 x 480. */
    private val cam = CameraSnapshot(1.0, 0.0, 0.0, 0.0, 0.0, 1.5, 0.0, 500.0, 500.0, 320.0, 240.0, 640, 480)

    private fun yawed(deg: Double): CameraSnapshot {
        val h = Math.toRadians(deg) / 2
        return cam.copy(qw = cos(h), qy = sin(h))
    }

    @Test fun projectFollowsOpenCvImageAxes() {
        val c = cam.project(Vec3(0f, 1.5f, -2f))!!
        assertEquals(320f, c[0], 1e-3f); assertEquals(240f, c[1], 1e-3f)
        val rightUp = cam.project(Vec3(1f, 2.5f, -2f))!!
        assertEquals(320f + 250f, rightUp[0], 1e-3f)   // world +X = image right
        assertEquals(240f - 250f, rightUp[1], 1e-3f)   // world up = image up (smaller v)
        assertNull(cam.project(Vec3(0f, 1.5f, 2f)))    // behind
    }

    @Test fun depthIsDistanceAlongTheOpticalAxis() {
        assertEquals(2.0, cam.depthOf(Vec3(0.7f, 1.0f, -2f)), 1e-6)
        assertTrue(cam.depthOf(Vec3(0f, 1.5f, 2f)) < 0)
        assertEquals(2.0, yawed(90.0).depthOf(Vec3(-2f, 1.5f, 0f)), 1e-5)   // yawed 90 deg left: looks down world -X
    }

    @Test fun rayThroughAPixelHitsWhatProjectsThere() {
        for (c in listOf(cam, yawed(37.0))) for ((u, v) in listOf(320f to 240f, 100f to 400f, 600f to 30f)) {
            val (o, d) = c.ray(u, v)
            assertEquals(1.0, Math.sqrt((d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).toDouble()), 1e-5)
            val p = Vec3(o[0] + 3f * d[0], o[1] + 3f * d[1], o[2] + 3f * d[2])
            val uv = c.project(p)!!
            assertEquals(u, uv[0], 0.05f); assertEquals(v, uv[1], 0.05f)
        }
        val (o, d) = cam.ray(320f, 240f)
        assertEquals(1.5f, o[1], 1e-6f)
        assertEquals(-1f, d[2], 1e-6f)                   // the principal ray looks down -Z
    }

    @Test fun objectBoxProjectsTheLiftedFootprint() {
        val chair = ObjectBox(9, "chair", 0.2, -2.5, 0.5, 0.5, 0, 0.9)
        val b = MaskMath.objectBox(cam, chair, 0f)
        assertNotNull(b)
        assertTrue(b!!.x0 < 320f && b.x1 > 320f - 100f)
        assertNull(MaskMath.objectBox(cam, chair.copy(z = 4.0), 0f))   // behind the camera: no box
    }
}
