package dev.capturekit.segment

import dev.capturekit.capture.ObjectBox
import kotlin.math.cos
import kotlin.math.sin

/**
 * The AR camera at one frame: T_world_from_camera (rotation [qw]..[qz], translation [tx]..[tz]; ARCore camera axes,
 * X right / Y up / looking down -Z, aligned with the CPU image) and the CPU-image intrinsics of a [w] x [h] image.
 * The ARCore -> OpenCV axis flip happens only in [project], [depthOf] and [ray] (AGENTS.md C).
 */
data class CameraSnapshot(
    val qw: Double, val qx: Double, val qy: Double, val qz: Double,
    val tx: Double, val ty: Double, val tz: Double,
    val fx: Double, val fy: Double, val cx: Double, val cy: Double,
    val w: Int, val h: Int,
) {
    /** Row-major 3x3 rotation world_from_camera. */
    fun rotation(): DoubleArray {
        val n = Math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz).takeIf { it > 0 } ?: 1.0
        val w = qw / n; val x = qx / n; val y = qy / n; val z = qz / n
        return doubleArrayOf(
            1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
            2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
        )
    }

    /** Distance of world point [p] along the optical axis (OpenCV z); negative or tiny when behind the camera. */
    fun depthOf(p: Vec3): Double {
        val r = rotation()
        val dx = p.x - tx; val dy = p.y - ty; val dz = p.z - tz
        return -(r[2] * dx + r[5] * dy + r[8] * dz)
    }

    /** Image pixel (u, v) of world point [p], or null when it is behind or too close to the camera (< [MIN_DEPTH_M]). */
    fun project(p: Vec3): FloatArray? {
        val r = rotation()
        val dx = p.x - tx; val dy = p.y - ty; val dz = p.z - tz
        // camera (ARCore) = R^T d; OpenCV = (x, -y, -z)
        val gx = r[0] * dx + r[3] * dy + r[6] * dz
        val gy = r[1] * dx + r[4] * dy + r[7] * dz
        val gz = r[2] * dx + r[5] * dy + r[8] * dz
        val z = -gz
        if (z < MIN_DEPTH_M) return null
        return floatArrayOf((fx * gx / z + cx).toFloat(), (fy * -gy / z + cy).toFloat())
    }

    /**
     * World ray through image pixel ([u], [v]) as (origin, unit direction), both 3 floats: what `Frame.hitTest(origin, 0,
     * direction, 0)` takes. Built from THIS snapshot, so a result that is applied later still casts the ray of the camera that took it.
     */
    fun ray(u: Float, v: Float): Pair<FloatArray, FloatArray> {
        val ox = (u - cx) / fx; val oy = (v - cy) / fy      // OpenCV: x right, y down, z forward = 1
        val gx = ox; val gy = -oy; val gz = -1.0            // ARCore camera axes
        val r = rotation()
        var dx = r[0] * gx + r[1] * gy + r[2] * gz
        var dy = r[3] * gx + r[4] * gy + r[5] * gz
        var dz = r[6] * gx + r[7] * gy + r[8] * gz
        val n = Math.sqrt(dx * dx + dy * dy + dz * dz)
        dx /= n; dy /= n; dz /= n
        return floatArrayOf(tx.toFloat(), ty.toFloat(), tz.toFloat()) to floatArrayOf(dx.toFloat(), dy.toFloat(), dz.toFloat())
    }

    fun inImage(u: Float, v: Float, marginFrac: Float = 0.02f): Boolean {
        val mx = w * marginFrac; val my = h * marginFrac
        return u >= mx && u < w - mx && v >= my && v < h - my
    }

    companion object { const val MIN_DEPTH_M = 0.1 }
}

object MaskMath {
    /** Image box of a core object's 3D box (footprint w x d rotated by yaw, floor to h), clipped to the image; null when < 2 corners project. */
    fun objectBox(cam: CameraSnapshot, o: ObjectBox, floorY: Float): Box2? {
        val a = Math.toRadians(o.yawDeg.toDouble())
        val ca = cos(a).toFloat(); val sa = sin(a).toFloat()
        var x0 = Float.MAX_VALUE; var y0 = Float.MAX_VALUE; var x1 = -Float.MAX_VALUE; var y1 = -Float.MAX_VALUE
        var n = 0
        for (sx in floatArrayOf(-0.5f, 0.5f)) for (sz in floatArrayOf(-0.5f, 0.5f)) for (yy in floatArrayOf(0f, o.h.toFloat())) {
            val lx = sx * o.w.toFloat(); val lz = sz * o.d.toFloat()
            val p = Vec3(o.x.toFloat() + lx * ca - lz * sa, floorY + yy, o.z.toFloat() + lx * sa + lz * ca)
            val uv = cam.project(p) ?: continue
            n++
            x0 = minOf(x0, uv[0]); y0 = minOf(y0, uv[1]); x1 = maxOf(x1, uv[0]); y1 = maxOf(y1, uv[1])
        }
        if (n < 2) return null
        val b = Box2(x0.coerceIn(0f, cam.w.toFloat()), y0.coerceIn(0f, cam.h.toFloat()), x1.coerceIn(0f, cam.w.toFloat()), y1.coerceIn(0f, cam.h.toFloat()))
        return if (b.area > 0f) b else null
    }
}
