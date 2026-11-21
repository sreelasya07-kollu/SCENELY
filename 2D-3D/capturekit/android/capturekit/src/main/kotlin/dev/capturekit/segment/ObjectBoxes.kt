package dev.capturekit.segment

import dev.capturekit.capture.LabelMap
import dev.capturekit.capture.ObjectBox

enum class LiveState { VISIBLE, REMEMBERED }

/** Contract C2 (in memory, never recorded): one object of this scan. */
data class LiveObject(
    val trackId: Int, val label: String, val cocoId: Int, val score: Float,
    val boxImg: Box2?, val centreWorld: Vec3?, val seenCount: Int,
    val firstSeenNs: Long, val lastSeenNs: Long, val state: LiveState,
) {
    /** Scanned (ADR 0038): located in 3D and seen at least [LiveObjectTracker.SCANNED_MIN_SIGHTINGS] times. Derived, so immutable. */
    val scanned: Boolean get() = centreWorld != null && seenCount >= LiveObjectTracker.SCANNED_MIN_SIGHTINGS
}

/**
 * One box to draw this frame, in camera-image pixels: [solid] = seen in the last result, else remembered (dashed, "seen" tag).
 * [scanned] = see [LiveObject.scanned] (drawn green with a check, else amber).
 */
data class DrawBox(val trackId: Int, val text: String, val box: Box2, val solid: Boolean, val scanned: Boolean = false)

/**
 * Live objects of one scan (ADR 0035): turns each segmentation result into tracks and draws them every frame.
 * GL thread only (the hit test needs the current Frame); [objects] / [drawBoxes] are cheap. Identity = [TrackMemory]
 * (same label, 3D centre <= 0.5 m or box IoU >= 0.3, LRU 48), so an object that leaves the view and returns keeps its id.
 *
 * Every frame, each track is drawn as follows: with a 3D centre it is projected into the CURRENT camera and drawn with the last
 * box size scaled by lastDepth / currentDepth (a centre behind the camera or outside the image gives no box); without a centre
 * only for [NO_CENTRE_MS] after its result. A lifted core object box (same class, centre within [CORE_MATCH_M]) replaces the box.
 */
class LiveObjectTracker(private val memory: TrackMemory = TrackMemory()) {
    /** Box geometry relative to the centroid pixel, in pixels at the time of the result, plus when it arrived. */
    private class Extra(val halfW: Float, val halfH: Float, val offX: Float, val offY: Float, val depth: Double, val appliedMs: Long)

    private val extras = HashMap<Int, Extra>()
    private var lastIds: Set<Int> = emptySet()
    private var lastResultMs = Long.MIN_VALUE

    /** True once at least one result was applied. */
    val any: Boolean get() = lastResultMs != Long.MIN_VALUE

    /**
     * Applies one result. [hit] returns the first world hit of the ray (origin, unit direction), or null; it is called with the
     * ray of the camera that TOOK the image ([SegResult.camera]), never the current camera. [nowMs] is a monotonic ms clock.
     */
    fun apply(res: SegResult, nowMs: Long, hit: (FloatArray, FloatArray) -> Vec3?) {
        val prompts = res.instances.map { i ->
            val (o, d) = res.camera.ray(i.cx, i.cy)
            val centre = try { hit(o, d) } catch (_: Throwable) { null }
            SegPrompt(null, SurfaceKind.OBJECT, i.label, i.cx, i.cy, i.box, centre, i.coco, i.score)
        }
        val tracks = memory.assign(prompts, res.tNs)
        val remembered = memory.snapshot().associate { it.id to it.centre }   // after assign: a hit-test miss keeps the old centre
        for ((k, t) in tracks.withIndex()) {
            val i = res.instances[k]
            val c = remembered[t.id]
            val bx = (i.box.x0 + i.box.x1) / 2; val by = (i.box.y0 + i.box.y1) / 2
            // Offsets are relative to where the centre projects: this sighting's centroid pixel, or (hit-test miss) the remembered centre.
            val anchor = if (prompts[k].centre != null) null else c?.let { res.camera.project(it) }
            val ax = anchor?.get(0) ?: i.cx; val ay = anchor?.get(1) ?: i.cy
            extras[t.id] = Extra((i.box.x1 - i.box.x0) / 2, (i.box.y1 - i.box.y0) / 2, bx - ax, by - ay,
                if (c != null) res.camera.depthOf(c) else 0.0, nowMs)
        }
        val alive = memory.snapshot().map { it.id }.toSet()
        extras.keys.retainAll(alive)
        lastIds = tracks.map { it.id }.toSet()
        lastResultMs = nowMs
    }

    /** Every remembered track as C2 objects ([LiveState.VISIBLE] = seen in the last result, which is at most [FRESH_MS] old). */
    fun objects(nowMs: Long): List<LiveObject> {
        val fresh = any && nowMs - lastResultMs <= FRESH_MS
        return memory.snapshot().map { t ->
            LiveObject(t.id, t.label, t.cocoId, t.score, t.box, t.centre, t.seenCount, t.firstSeenNs, t.lastSeenNs,
                if (fresh && t.id in lastIds) LiveState.VISIBLE else LiveState.REMEMBERED)
        }
    }

    /** Boxes to draw for the camera [cam] right now. [core] = lifted core objects with [floorY] (null floor = no core boxes). */
    fun drawBoxes(cam: CameraSnapshot, nowMs: Long, core: List<ObjectBox> = emptyList(), floorY: Float? = null): List<DrawBox> {
        val out = ArrayList<DrawBox>()
        for (o in objects(nowMs)) {
            val ex = extras[o.trackId] ?: continue
            val solid = o.state == LiveState.VISIBLE
            val text = if (solid) "${o.label} #${o.trackId}" else "${o.label} #${o.trackId} seen"
            val c = o.centreWorld
            val box: Box2? = if (c != null) {
                val uv = cam.project(c)
                if (uv == null || !cam.inImage(uv[0], uv[1], 0f)) null
                else coreBoxFor(o, c, cam, core, floorY) ?: scaled(cam, c, uv, ex)
            } else if (nowMs - ex.appliedMs <= NO_CENTRE_MS && o.boxImg != null) o.boxImg else null
            if (box != null) out.add(DrawBox(o.trackId, text, box, solid, o.scanned))
        }
        return out
    }

    private fun scaled(cam: CameraSnapshot, c: Vec3, uv: FloatArray, ex: Extra): Box2? {
        val d = cam.depthOf(c)
        val s = if (ex.depth > 0.0 && d > 0.0) (ex.depth / d).toFloat() else 1f
        val cx = uv[0] + ex.offX * s; val cy = uv[1] + ex.offY * s
        return Box2(cx - ex.halfW * s, cy - ex.halfH * s, cx + ex.halfW * s, cy + ex.halfH * s)
    }

    private fun coreBoxFor(o: LiveObject, c: Vec3, cam: CameraSnapshot, core: List<ObjectBox>, floorY: Float?): Box2? {
        if (floorY == null || core.isEmpty() || o.cocoId == 0) return null
        val cls = LabelMap.coreName(LabelMap.fromCocoCategory(o.cocoId))
        var best: ObjectBox? = null; var bestD = CORE_MATCH_M
        for (b in core) {
            if (b.cls != cls) continue
            val d = c.dist(Vec3(b.x.toFloat(), floorY + b.h.toFloat() / 2f, b.z.toFloat()))
            if (d <= bestD) { bestD = d; best = b }
        }
        return best?.let { MaskMath.objectBox(cam, it, floorY) }
    }

    fun clear() { memory.clear(); extras.clear(); lastIds = emptySet(); lastResultMs = Long.MIN_VALUE }

    companion object {
        /** A track without a 3D centre stays drawn this long after its result (brief). */
        const val NO_CENTRE_MS = 500L
        /** A result older than this no longer counts as "seen in the last result" (paused, tracking lost, worker stalled). */
        const val FRESH_MS = 1500L
        /** Core object box and track match when their centres are this close (metres). */
        const val CORE_MATCH_M = 0.6f
        /** An object counts as scanned once it was seen this many times and has a 3D centre (ADR 0038). */
        const val SCANNED_MIN_SIGHTINGS = 3
    }
}
