package dev.capturekit.guidance

import dev.capturekit.capture.CoreEvent
import dev.capturekit.capture.LabelMap
import dev.capturekit.segment.LiveObject

/**
 * Scan completeness and weak zones (ADR 0035/0036), pure. Inputs: the core overlay (room coverage, wall spans, gaps; gaps need
 * guide understanding 2) and the live object tracks.
 *
 * completeness_pct = round(100 * (0.8 * overlay.completeness + 0.2 * confirmed / max(1, tracks))), or the overlay only when there
 * are no tracks. A track is confirmed after [CONFIRM_SIGHTINGS] or more segmentation sightings (guess).
 * Weak zones = overlay spans in state 'm' (per wall id), overlay gaps (by type) and unconfirmed tracks ("Look at the chair again").
 * The ReviewSummary JSON (contract C3) travels in the Intent extra `ck.review_summary`; it is never recorded in the bundle.
 */
object Completeness {
    const val CONFIRM_SIGHTINGS = 3
    const val MAX_ZONES = 8
    const val EXTRA = "ck.review_summary"

    data class ObjectEntry(val trackId: Int, val label: String, val seenCount: Int, val confirmed: Boolean)
    /** [kind] = "wall_span" | "gap" | "object"; [x], [z] in metres (null = unknown); [pri] 0..1 (1 = look here first). */
    data class WeakZone(val kind: String, val wallId: Int?, val x: Double?, val z: Double?, val text: String, val pri: Double)
    data class Summary(val completenessPct: Int, val roomPct: Int, val objects: List<ObjectEntry>, val weakZones: List<WeakZone>)

    fun pct(room: Double, confirmed: Int, tracks: Int): Int {
        val r = if (room.isFinite()) room.coerceIn(0.0, 1.0) else 0.0
        val v = if (tracks <= 0) r else 0.8 * r + 0.2 * confirmed.toDouble() / maxOf(1, tracks)
        return Math.round(100.0 * v).toInt().coerceIn(0, 100)
    }

    fun compute(o: CoreEvent.Overlay?, live: List<LiveObject>): Summary {
        val objects = live.map { ObjectEntry(it.trackId, it.label, it.seenCount, it.seenCount >= CONFIRM_SIGHTINGS) }
        val room = o?.completeness ?: 0.0
        val zones = ArrayList<WeakZone>()
        if (o != null) {
            // Missing wall stretches, one zone per wall: centre of the missing spans, priority by how much of the wall is missing.
            for ((id, spans) in o.spans.groupBy { it.id }) {
                val missing = spans.filter { it.state == 'm' }
                if (missing.isEmpty()) continue
                fun len(s: dev.capturekit.capture.SpanSeg) = Math.hypot(s.x1 - s.x0, s.z1 - s.z0)
                val total = spans.sumOf { len(it) }.takeIf { it > 0 } ?: 1.0
                val frac = (missing.sumOf { len(it) } / total).coerceIn(0.0, 1.0)
                zones.add(WeakZone("wall_span", id.takeIf { it > 0 }, missing.map { (it.x0 + it.x1) / 2 }.average(), missing.map { (it.z0 + it.z1) / 2 }.average(),
                    if (id > 0) "Scan wall $id again" else "Scan the missing part of the wall", 0.6 + 0.4 * frac))
            }
            for (g in o.gaps) zones.add(WeakZone("gap", null, g.x, g.z, "Look at the unseen area (${g.type.replace('_', ' ')})", g.pri.coerceIn(0.0, 1.0)))
        }
        for (t in live) if (t.seenCount < CONFIRM_SIGHTINGS)
            zones.add(WeakZone("object", null, t.centreWorld?.x?.toDouble(), t.centreWorld?.z?.toDouble(), "Look at the ${LabelMap.displayName(t.label)} again", 0.5))
        val sorted = zones.sortedWith(compareByDescending<WeakZone> { it.pri }.thenBy { it.text })
        val confirmed = objects.count { it.confirmed }
        return Summary(pct(room, confirmed, live.size), pct(room, 0, 0), objects, sorted.take(MAX_ZONES))
    }

    private fun esc(s: String): String = buildString { for (c in s) when {
        c == '"' -> append("\\\""); c == '\\' -> append("\\\\"); c == '\n' -> append("\\n"); c < ' ' -> append(String.format("\\u%04x", c.code)); else -> append(c) } }
    private fun num(d: Double?): String = if (d == null || !d.isFinite()) "null" else (Math.round(d * 100.0) / 100.0).toString()

    /** Contract C3 JSON. */
    fun toJson(s: Summary): String = buildString {
        append("{\"completeness_pct\":").append(s.completenessPct).append(",\"room_pct\":").append(s.roomPct).append(",\"objects\":[")
        s.objects.forEachIndexed { i, o ->
            if (i > 0) append(',')
            append("{\"track_id\":").append(o.trackId).append(",\"label\":\"").append(esc(o.label)).append("\",\"seen_count\":").append(o.seenCount)
                .append(",\"confirmed\":").append(o.confirmed).append('}')
        }
        append("],\"weak_zones\":[")
        s.weakZones.forEachIndexed { i, z ->
            if (i > 0) append(',')
            append("{\"kind\":\"").append(z.kind).append("\",\"wall_id\":").append(z.wallId ?: "null").append(",\"x\":").append(num(z.x))
                .append(",\"z\":").append(num(z.z)).append(",\"text\":\"").append(esc(z.text)).append("\",\"pri\":").append(num(z.pri)).append('}')
        }
        append("]}")
    }
}
