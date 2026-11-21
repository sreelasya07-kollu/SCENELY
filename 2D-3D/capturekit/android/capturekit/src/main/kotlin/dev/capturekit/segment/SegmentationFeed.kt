package dev.capturekit.segment

import android.util.Log
import com.google.ar.core.Camera
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.TrackingState

/**
 * AR frame -> segmentation job (ADR 0035). Call [onArFrame] on the GL thread every frame while scanning: it costs one
 * rate check unless a run is due; then it snapshots the camera, works out how many quarter turns make the sensor-oriented
 * image upright on screen, and copies the CPU image (plane bytes only; YUV->RGB happens on the worker). Never throws,
 * never blocks: a busy worker means a counted drop ([SegmentationScheduler]).
 */
class SegmentationFeed(private val scheduler: SegmentationScheduler) {
    private var errors = 0L
    private val unit = floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f)
    private val mapped = FloatArray(6)

    fun onArFrame(frame: Frame, mlRateScale: Double) {
        try {
            val t = frame.timestamp
            if (t == 0L) return
            val cam = frame.camera
            if (!scheduler.shouldCapture(t, mlRateScale, cam.trackingState == TrackingState.TRACKING)) return
            val snap = snapshot(cam)
            frame.transformCoordinates2d(Coordinates2d.IMAGE_NORMALIZED, unit, Coordinates2d.VIEW_NORMALIZED, mapped)
            val turns = RfDetr.quarterTurns(mapped[2] - mapped[0], mapped[3] - mapped[1])
            val image = copyImage(frame) ?: return
            scheduler.submit(SegJob(t, image, snap, turns))
        } catch (t: Throwable) {
            if (errors++ % 50 == 0L) Log.w(TAG, "segmentation frame skipped ($errors)", t)
        }
    }

    private fun copyImage(frame: Frame): SegImage? {
        val img = try { frame.acquireCameraImage() } catch (_: Exception) { return null }
        img.use {
            val yp = it.planes[0]; val up = it.planes[1]; val vp = it.planes[2]
            fun bytes(b: java.nio.ByteBuffer) = ByteArray(b.remaining()).also { a -> b.duplicate().get(a) }
            return SegImage(it.width, it.height, bytes(yp.buffer), yp.rowStride, bytes(up.buffer), bytes(vp.buffer), up.rowStride, up.pixelStride)
        }
    }

    companion object {
        private const val TAG = "CK/Segment"

        /** The camera of one frame: CPU-image intrinsics + physical camera pose (aligned with the CPU image). */
        fun snapshot(cam: Camera): CameraSnapshot {
            val p = cam.pose
            val k = cam.imageIntrinsics
            val f = k.focalLength; val c = k.principalPoint; val d = k.imageDimensions
            return CameraSnapshot(p.qw().toDouble(), p.qx().toDouble(), p.qy().toDouble(), p.qz().toDouble(),
                p.tx().toDouble(), p.ty().toDouble(), p.tz().toDouble(),
                f[0].toDouble(), f[1].toDouble(), c[0].toDouble(), c[1].toDouble(), d[0], d[1])
        }
    }
}
