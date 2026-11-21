package dev.capturekit.segment

import dev.capturekit.capture.LabelMap
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp

/** Host math of RF-DETR-Seg Nano on synthetic tensors (ADR 0035). */
class RfDetrTest {
    private fun encClass(vararg hot: Pair<Int, Float>) = FloatArray(RfDetr.N_ENC_CLASS) { -10f }.also { for ((cell, v) in hot) it[cell * RfDetr.CLASSES + 5] = v }

    @Test fun proposalGridAndTopHundred() {
        val delta = FloatArray(RfDetr.N_ENC_DELTA)
        // Cell 27 = (gx 1, gy 1) with a delta; cell 0 and 675 are the corners.
        delta[4 * 27] = 2f; delta[4 * 27 + 1] = -4f; delta[4 * 27 + 2] = 0f; delta[4 * 27 + 3] = Math.log(2.0).toFloat()
        val p = RfDetr.proposals(encClass(27 to 9f, 0 to 8f, 675 to 7f), delta)
        assertEquals(RfDetr.QUERIES, p.cell.size)
        assertArrayEquals(intArrayOf(27, 0, 675), p.cell.copyOf(3))   // best logit first
        // cxcy = delta[:2] * 0.05 + ((gx + .5) / 26, (gy + .5) / 26); wh = exp(delta[2:]) * 0.05
        assertEquals(2f * 0.05f + 1.5f / 26f, p.ts[0], 1e-6f)
        assertEquals(-4f * 0.05f + 1.5f / 26f, p.ts[1], 1e-6f)
        assertEquals(0.05f, p.ts[2], 1e-6f)
        assertEquals(0.10f, p.ts[3], 1e-6f)
        assertEquals(0.5f / 26f, p.ts[4], 1e-6f)                    // cell 0 corner, zero delta
        assertEquals(25.5f / 26f, p.ts[8], 1e-6f); assertEquals(25.5f / 26f, p.ts[9], 1e-6f)
        // Ties resolve to the lower cell index: all other cells are equal (-10), so the rest is cells 1, 2, 3 ...
        assertArrayEquals(intArrayOf(1, 2, 3), p.cell.copyOfRange(3, 6))
    }

    @Test fun referencePointsReparametrisation() {
        val ts = FloatArray(RfDetr.N_REF); val rp = FloatArray(RfDetr.N_REF)
        ts[0] = 0.4f; ts[1] = 0.6f; ts[2] = 0.2f; ts[3] = 0.1f
        rp[0] = 1f; rp[1] = -2f; rp[2] = 0f; rp[3] = Math.log(3.0).toFloat()
        val ref = RfDetr.refPoints(ts, rp)
        assertEquals(1f * 0.2f + 0.4f, ref[0], 1e-6f)     // rp[:2] * wh + cxcy
        assertEquals(-2f * 0.1f + 0.6f, ref[1], 1e-6f)
        assertEquals(exp(0f) * 0.2f, ref[2], 1e-6f)       // exp(rp[2:]) * wh
        assertEquals(3f * 0.1f, ref[3], 1e-6f)
    }

    @Test fun memoryIsHalfOfMemory2() {
        assertArrayEquals(floatArrayOf(1f, -2f, 0.5f), RfDetr.memory(floatArrayOf(2f, -4f, 1f)), 0f)
    }

    private fun logits(vararg q: Triple<Int, Int, Float>) = FloatArray(RfDetr.N_LOGITS) { -10f }.also { for ((qi, k, v) in q) it[qi * RfDetr.CLASSES + k] = v }
    private fun boxes(vararg q: Pair<Int, FloatArray>) = FloatArray(RfDetr.N_BOXES) { if (it % 4 < 2) 0.5f else 0.2f }.also { for ((qi, b) in q) b.copyInto(it, 4 * qi) }

    @Test fun thresholdSigmoidAndNonCocoIdsAreDropped() {
        val l = logits(Triple(0, 62, 2f), Triple(1, 62, -1f), Triple(2, 12, 5f), Triple(3, 0, 6f))   // 12 = unused COCO id, 0 = background slot
        val c = RfDetr.candidates(boxes(), l)
        assertEquals(listOf(0), c.map { it.query })
        assertEquals(1f / (1f + exp(-2f)), c[0].score, 1e-6f)
        assertEquals(62, c[0].coco)
        assertEquals(0.4f, c[0].x0, 1e-6f); assertEquals(0.6f, c[0].x1, 1e-6f)   // cxcywh -> corners
    }

    @Test fun perClassNmsKeepsTheBestAndOtherClasses() {
        val same = floatArrayOf(0.5f, 0.5f, 0.4f, 0.4f)
        val near = floatArrayOf(0.52f, 0.5f, 0.4f, 0.4f)
        val l = logits(Triple(0, 62, 3f), Triple(1, 62, 2f), Triple(2, 63, 1f), Triple(3, 62, 4f))
        val b = boxes(0 to same, 1 to near, 2 to near, 3 to floatArrayOf(0.1f, 0.1f, 0.1f, 0.1f))
        val kept = RfDetr.nms(RfDetr.candidates(b, l))
        assertEquals(listOf(3, 0, 2), kept.map { it.query })   // query 1 (chair, overlaps the better chair 0) dies; the couch survives
        assertEquals(1, RfDetr.nms(RfDetr.candidates(b, l), max = 1).size)
    }

    @Test fun decodeUnrotatesBoxAndTakesTheMaskCentroid() {
        val b = boxes(0 to floatArrayOf(0.25f, 0.5f, 0.2f, 0.4f))     // upright box x .15..35, y .3..7
        val l = logits(Triple(0, 62, 3f))
        val masks = FloatArray(RfDetr.N_MASKS) { -5f }
        // Mask pixels (x 20..21, y 40..41) of query 0 -> centroid (21 / 78, 41 / 78) in the upright image.
        for (y in 40..41) for (x in 20..21) masks[y * RfDetr.MASK + x] = 3f
        val up = RfDetr.decode(b, l, masks, 0, 640, 480).single()
        assertEquals("chair", up.label)
        assertEquals(0.15f * 640, up.box.x0, 1e-3f); assertEquals(0.7f * 480, up.box.y1, 1e-3f)
        assertEquals(21f / 78 * 640, up.cx, 1e-2f); assertEquals(41f / 78 * 480, up.cy, 1e-2f)
        // The same scene seen through a 90 degree clockwise rotated image: corners map back to the sensor image.
        val r = RfDetr.decode(b, l, masks, 1, 640, 480).single()
        assertEquals(0.3f * 640, r.box.x0, 1e-3f); assertEquals(0.7f * 640, r.box.x1, 1e-3f)       // x = v
        assertEquals((1f - 0.35f) * 480, r.box.y0, 1e-3f); assertEquals((1f - 0.15f) * 480, r.box.y1, 1e-3f)   // y = 1 - u
        // No mask pixels: the box centre.
        val none = RfDetr.decode(b, l, FloatArray(RfDetr.N_MASKS) { -1f }, 0, 100, 100).single()
        assertEquals(25f, none.cx, 1e-3f); assertEquals(50f, none.cy, 1e-3f)
    }

    @Test fun rotationHelpersRoundTrip() {
        assertEquals(0, RfDetr.quarterTurns(1f, 0.1f)); assertEquals(1, RfDetr.quarterTurns(0.1f, 1f))
        assertEquals(2, RfDetr.quarterTurns(-1f, 0f)); assertEquals(3, RfDetr.quarterTurns(0f, -1f))
        // Rotating the image clockwise by k and un-rotating the corner of a pixel must land on the original pixel.
        for (k in 0..3) {
            val (x, y) = RfDetr.unrotate(k, 0.2f, 0.7f)
            var u = x; var v = y
            repeat(k) { val nu = 1f - v; val nv = u; u = nu; v = nv }    // forward clockwise quarter turn: (x, y) -> (1 - y, x)
            assertEquals(0.2f, u, 1e-6f); assertEquals(0.7f, v, 1e-6f)
        }
    }

    @Test fun preprocessIsNchwImageNetNormalisedAndRotates() {
        // 4 x 2 landscape image: left half black, right half white, grey chroma.
        val w = 4; val h = 2
        val y = ByteArray(w * h) { if (it % w >= 2) 255.toByte() else 0 }
        val img = SegImage(w, h, y, w, ByteArray(2) { 128.toByte() }, ByteArray(2) { 128.toByte() }, 2, 1)
        val out = FloatArray(RfDetr.N_IMAGE)
        RfDetr.preprocess(img, 0, out)
        val plane = RfDetr.SIDE * RfDetr.SIDE
        assertEquals((0f - 0.485f) / 0.229f, out[0], 1e-4f)                          // R plane, top-left = black
        assertEquals((1f - 0.456f) / 0.224f, out[plane + RfDetr.SIDE - 1], 1e-4f)    // G plane, top-right = white
        assertEquals((1f - 0.406f) / 0.225f, out[2 * plane + RfDetr.SIDE - 1], 1e-4f) // B plane
        // Rotated 90 degrees clockwise the white half is on the bottom: top-left stays black, bottom-left is white.
        RfDetr.preprocess(img, 1, out)
        assertEquals((0f - 0.485f) / 0.229f, out[0], 1e-4f)
        assertEquals((1f - 0.485f) / 0.229f, out[(RfDetr.SIDE - 1) * RfDetr.SIDE], 1e-4f)
    }

    @Test fun hostConstantsMustHaveTheExactSize() {
        val bytes = java.nio.ByteBuffer.allocate(12).order(java.nio.ByteOrder.LITTLE_ENDIAN).putFloat(1f).putFloat(-2f).putFloat(0.5f).array()
        assertArrayEquals(floatArrayOf(1f, -2f, 0.5f), RfDetr.loadFloats(bytes, 3)!!, 0f)
        assertNull(RfDetr.loadFloats(bytes, 4)); assertNull(RfDetr.loadFloats(bytes.copyOf(11), 3))
    }

    @Test fun everyGraphBufferHasADistinctFloatCountSoSlotsCanBeToldApart() {
        val a = listOf(RfDetr.N_IMAGE, RfDetr.N_CLSPOS, RfDetr.N_POSPATCH)
        val aOut = listOf(RfDetr.N_ENC_CLASS, RfDetr.N_ENC_DELTA, RfDetr.N_MEMORY)
        val b = listOf(RfDetr.N_MEMORY, RfDetr.N_QUERY_FEAT, RfDetr.N_REF)
        val bOut = listOf(RfDetr.N_BOXES, RfDetr.N_LOGITS, RfDetr.N_MASKS)
        for (s in listOf(a, aOut, b, bOut)) assertEquals(3, s.toSet().size)
        assertEquals(3 * 312 * 312, RfDetr.N_IMAGE); assertEquals(676 * 91, RfDetr.N_ENC_CLASS); assertEquals(100 * 78 * 78, RfDetr.N_MASKS)
    }

    @Test fun cocoCategoryLabelMapPinsChairCouchTv() {
        // RF-DETR class = COCO category id = EfficientDet index + 1 (ADR 0035; ADR 0017 chair 61 -> 62).
        assertEquals(LabelMap.CHAIR, LabelMap.fromCocoCategory(62)); assertEquals("chair", LabelMap.cocoName(62))
        assertEquals(LabelMap.COUCH, LabelMap.fromCocoCategory(63)); assertEquals("couch", LabelMap.cocoName(63))
        assertEquals(LabelMap.TV, LabelMap.fromCocoCategory(72)); assertEquals("tv", LabelMap.cocoName(72))
        assertEquals(LabelMap.BED, LabelMap.fromCocoCategory(65)); assertEquals(LabelMap.DINING_TABLE, LabelMap.fromCocoCategory(67))
        assertEquals(LabelMap.UNKNOWN, LabelMap.fromCocoCategory(1))      // person: not a core class
        assertEquals("person", LabelMap.cocoName(1)); assertEquals("toothbrush", LabelMap.cocoName(90))
        assertEquals("", LabelMap.cocoName(12)); assertEquals("", LabelMap.cocoName(0)); assertEquals("", LabelMap.cocoName(91))
        // Every core-mapped category has a COCO name equal to (or the spoken form of) the core class.
        for (cat in 1..90) if (LabelMap.fromCocoCategory(cat) != LabelMap.UNKNOWN) assertTrue(cat.toString(), LabelMap.cocoName(cat).isNotEmpty())
        assertNotNull(LabelMap.cocoName(50))
    }
}
