package dev.capturekit.sample

import android.content.Context
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.RectF
import android.os.SystemClock
import android.util.Log
import android.view.View
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import dev.capturekit.capture.ObjectBox
import dev.capturekit.segment.DrawBox
import dev.capturekit.segment.LiveObject
import dev.capturekit.segment.LiveObjectTracker
import dev.capturekit.segment.SegResult
import dev.capturekit.segment.SegmentationFeed
import dev.capturekit.segment.Vec3

/**
 * Live green object boxes over the camera feed (ADR 0035): label + #id, solid when seen in the last segmentation result,
 * dashed with a "seen" tag when only remembered. Each box follows the camera at frame rate: it is the track's 3D centre
 * projected into the CURRENT camera ([LiveObjectTracker]), mapped image -> view with Frame.transformCoordinates2d so crop and
 * rotation match the background renderer. Must fill the same parent as the AR GLSurfaceView. Display-only, never recorded.
 *
 * Threads: [setResult] on the segmentation thread (latest wins), [onArFrame] on the GL thread (hit test + projection; never
 * blocks), drawing on the UI thread. Each hand-over is one immutable object behind a @Volatile reference.
 */
class ObjectBoxOverlayView(ctx: Context) : View(ctx) {
    private val d = ctx.resources.displayMetrics.density
    private class Mapped(val items: List<Item>)
    private class Item(val text: String, val rect: RectF, val solid: Boolean)

    private val tracker = LiveObjectTracker()               // GL thread only
    @Volatile private var pending: SegResult? = null
    @Volatile private var mapped: Mapped? = null
    /** Latest objects for the completeness card / review (immutable list, safe from any thread). */
    @Volatile var live: List<LiveObject> = emptyList()
        private set
    private var floorY: Float? = null                        // GL thread only, refreshed with every applied result
    private var mapErrors = 0L                               // GL thread only
    private val img = FloatArray(16)
    private val view = FloatArray(16)

    /** Off = nothing is mapped or drawn (the HUD "Boxes" chip); tracking continues. Any thread. */
    @Volatile var showBoxes = true
        set(v) { field = v; if (!v) mapped = null; postInvalidate() }

    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f * d; color = GREEN }
    private val tagBg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = GREEN }
    private val tagText = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 13f * d; color = 0xFF000000.toInt(); isFakeBoldText = true }
    private val dash = DashPathEffect(floatArrayOf(10f * d, 7f * d), 0f)
    private val r = RectF()

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO   // visual hint only
        isClickable = false; isFocusable = false                     // touches fall through to the HUD / AR view
    }

    /** Segmentation thread: one run's instances. */
    fun setResult(res: SegResult) { pending = res }

    /**
     * GL thread, every AR frame: applies a waiting result (hit test per instance, from the result's own camera), then
     * projects every track into the current camera and maps it to the view. [core] = the core's lifted objects.
     */
    @Synchronized fun onArFrame(frame: Frame, session: Session?, core: List<ObjectBox>) {
        try {
            val now = SystemClock.uptimeMillis()
            val res = pending
            if (res != null) {
                pending = null
                floorY = floorOf(session) ?: floorY
                tracker.apply(res, now) { o, dir -> firstHit(frame, o, dir) }
            }
            if (!tracker.any) return
            live = tracker.objects(now)
            if (!showBoxes || frame.camera.trackingState != TrackingState.TRACKING) { if (mapped != null) { mapped = null; postInvalidate() }; return }
            val cam = SegmentationFeed.snapshot(frame.camera)
            val boxes = tracker.drawBoxes(cam, now, core, floorY).take(MAX_BOXES)
            mapped = Mapped(map(frame, boxes))
            postInvalidate()
        } catch (t: Throwable) {   // never break the AR callback
            if (mapErrors++ % 100 == 0L) Log.w(TAG, "object boxes failed ($mapErrors)", t)
        }
    }

    private fun firstHit(frame: Frame, origin: FloatArray, dir: FloatArray): Vec3? {
        val h = frame.hitTest(origin, 0, dir, 0).firstOrNull() ?: return null
        val p = h.hitPose
        return Vec3(p.tx(), p.ty(), p.tz())
    }

    private fun floorOf(session: Session?): Float? = session?.getAllTrackables(Plane::class.java)
        ?.filter { it.trackingState == TrackingState.TRACKING && it.type == Plane.Type.HORIZONTAL_UPWARD_FACING && it.subsumedBy == null }
        ?.minOfOrNull { it.centerPose.ty() }

    /** Image-pixel boxes -> view-pixel rectangles (all four corners, so a rotated display maps right). */
    private fun map(frame: Frame, boxes: List<DrawBox>): List<Item> {
        if (boxes.isEmpty()) return emptyList()
        val out = ArrayList<Item>(boxes.size)
        for (b in boxes) {
            val x0 = b.box.x0; val y0 = b.box.y0; val x1 = b.box.x1; val y1 = b.box.y1
            val corners = floatArrayOf(x0, y0, x1, y0, x1, y1, x0, y1)
            frame.transformCoordinates2d(Coordinates2d.IMAGE_PIXELS, corners, Coordinates2d.VIEW, view)
            var l = Float.MAX_VALUE; var t = Float.MAX_VALUE; var rr = -Float.MAX_VALUE; var bb = -Float.MAX_VALUE
            for (i in 0 until 4) { l = minOf(l, view[2 * i]); rr = maxOf(rr, view[2 * i]); t = minOf(t, view[2 * i + 1]); bb = maxOf(bb, view[2 * i + 1]) }
            out.add(Item(b.text, RectF(l, t, rr, bb), b.solid))
        }
        return out
    }

    /** Drops everything (scan finished or paused). Any thread; the tracker itself is cleared on the next GL frame via [reset]. */
    fun clear() { pending = null; mapped = null; postInvalidate() }

    /** New scan: forget every track. Call from the GL thread owner before the scan starts (no frames are running a result yet). */
    @Synchronized fun reset() { tracker.clear(); live = emptyList(); pending = null; mapped = null; floorY = null; postInvalidate() }

    override fun onDraw(c: Canvas) {
        val m = mapped ?: return
        if (!showBoxes) return
        val pad = 4f * d
        val fm = tagText.fontMetrics
        val tagH = fm.descent - fm.ascent + pad
        for (it in m.items) {
            stroke.pathEffect = if (it.solid) null else dash
            stroke.alpha = if (it.solid) 255 else 200
            c.drawRect(it.rect, stroke)
            val tw = tagText.measureText(it.text) + 2 * pad
            val x = it.rect.left.coerceIn(0f, maxOf(0f, width - tw))
            val y = (it.rect.top - tagH).coerceAtLeast(0f)
            tagBg.alpha = if (it.solid) 255 else 200
            r.set(x, y, x + tw, y + tagH)
            c.drawRoundRect(r, 4f * d, 4f * d, tagBg)
            c.drawText(it.text, x + pad, y + pad / 2 - fm.ascent, tagText)
        }
    }

    private companion object {
        const val TAG = "CKObjectBoxes"
        const val GREEN = 0xFF00E676.toInt()
        const val MAX_BOXES = 24
    }
}
