package dev.capturekit.guidance

import dev.capturekit.capture.CoreEvent
import dev.capturekit.capture.GapMark
import dev.capturekit.capture.SpanSeg
import dev.capturekit.segment.LiveObject
import dev.capturekit.segment.LiveState
import dev.capturekit.segment.Vec3
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletenessTest {
    private fun overlay(completeness: Double, spans: List<SpanSeg> = emptyList(), gaps: List<GapMark> = emptyList()) = CoreEvent.Overlay(
        completeness, 0.0, 1, "scan", true, true, true, 4, 0.0, 0.0, 0.0, false, 0.0, 0.0, "", "", emptyList(),
        layoutV3 = true, spans = spans, gaps = gaps)

    private fun live(id: Int, label: String, seen: Int, centre: Vec3? = null) =
        LiveObject(id, label, 62, 0.9f, null, centre, seen, 0, 0, LiveState.VISIBLE)

    @Test fun formulaWeighsRoomEightyAndObjectsTwenty() {
        assertEquals(80, Completeness.pct(1.0, 0, 5))      // all room, no object confirmed
        assertEquals(100, Completeness.pct(1.0, 5, 5))
        assertEquals(60, Completeness.pct(0.5, 5, 5))      // 0.4 + 0.2
        assertEquals(40, Completeness.pct(0.5, 0, 4))
        assertEquals(45, Completeness.pct(0.5, 1, 4))      // 0.4 + 0.2 * 0.25
    }

    @Test fun withoutTracksTheOverlayAloneDecides() {
        assertEquals(63, Completeness.pct(0.63, 0, 0))
        assertEquals(0, Completeness.pct(Double.NaN, 0, 0))
        assertEquals(100, Completeness.pct(7.0, 0, 0))     // clamped
        assertEquals(0, Completeness.compute(null, emptyList()).completenessPct)
    }

    @Test fun objectsAreConfirmedAfterThreeSightings() {
        val s = Completeness.compute(overlay(0.5), listOf(live(1, "chair", 2), live(2, "couch", 3)))
        assertEquals(listOf(false, true), s.objects.map { it.confirmed })
        assertEquals(Completeness.pct(0.5, 1, 2), s.completenessPct)
        assertEquals(50, s.roomPct)
    }

    @Test fun weakZonesFromMissingSpansGapsAndUnconfirmedObjects() {
        val spans = listOf(
            SpanSeg(2, 0.0, 0.0, 2.0, 0.0, 'o'), SpanSeg(2, 2.0, 0.0, 4.0, 0.0, 'm'),   // wall 2: half missing
            SpanSeg(3, 0.0, 0.0, 0.0, 3.0, 'b'),                                          // blocked is never demanded
            SpanSeg(5, 0.0, 0.0, 0.0, 3.0, 'm'),                                          // wall 5: fully missing
        )
        val gaps = listOf(GapMark("behind_furniture", 1.0, 2.0, 0.3))
        val s = Completeness.compute(overlay(0.7, spans, gaps), listOf(live(7, "chair", 1, Vec3(1f, 0.5f, 2f)), live(8, "couch", 5)))
        val z = s.weakZones
        assertEquals(listOf("wall_span", "wall_span", "object", "gap"), z.map { it.kind })   // by priority: 1.0, 0.8, 0.5, 0.3
        assertEquals(5, z[0].wallId); assertEquals("Scan wall 5 again", z[0].text)
        assertEquals(2, z[1].wallId); assertEquals(3.0, z[1].x!!, 1e-9)                       // centre of the missing span
        assertEquals("Look at the chair again", z[2].text); assertEquals(1.0, z[2].x!!, 1e-9)
        assertEquals("Look at the unseen area (behind furniture)", z[3].text)
        assertTrue(z.none { it.wallId == 3 })
        // An unconfirmed object without a 3D centre is not a weak zone (x / z are metres).
        assertTrue(Completeness.compute(overlay(1.0), listOf(live(9, "chair", 1))).weakZones.isEmpty())
    }

    @Test fun zonesAreCappedAndAGoodScanHasNone() {
        val many = (1..20).map { GapMark("g", it.toDouble(), 0.0, 0.5) }
        assertEquals(Completeness.MAX_ZONES, Completeness.compute(overlay(0.3, gaps = many), emptyList()).weakZones.size)
        assertTrue(Completeness.compute(overlay(1.0), listOf(live(1, "chair", 4))).weakZones.isEmpty())
    }

    @Test fun reviewSummaryJsonFollowsContractC3() {
        val s = Completeness.Summary(71, 70, listOf(Completeness.ObjectEntry(3, "chair \"x\"", 2, false)),
            listOf(Completeness.WeakZone("wall_span", 4, 1.234, null, "Scan wall 4 again", 0.9)))
        val j = Completeness.toJson(s)
        assertEquals("{\"completeness_pct\":71,\"room_pct\":70,\"objects\":[{\"track_id\":3,\"label\":\"chair \\\"x\\\"\",\"seen_count\":2,\"confirmed\":false}]," +
            "\"weak_zones\":[{\"kind\":\"wall_span\",\"wall_id\":4,\"x\":1.23,\"z\":null,\"text\":\"Scan wall 4 again\",\"pri\":0.9}]}", j)
        assertEquals("{\"completeness_pct\":0,\"room_pct\":0,\"objects\":[],\"weak_zones\":[]}", Completeness.toJson(Completeness.compute(null, emptyList())))
        assertFalse(j.contains("NaN"))
        assertEquals("ck.review_summary", Completeness.EXTRA)
    }
}
