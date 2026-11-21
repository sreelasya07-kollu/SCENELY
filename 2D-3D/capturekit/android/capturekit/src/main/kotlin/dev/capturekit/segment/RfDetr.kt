package dev.capturekit.segment

import dev.capturekit.capture.LabelMap
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Host math of RF-DETR-Seg Nano (litert-community/RF-DETR-Seg-Nano-LiteRT, ADR 0035), all pure so it is JVM-tested on
 * synthetic tensors. The two GPU graphs only do the network; the proposal grid, the top-100 gather, the reference-point
 * reparametrisation, the thresholding and the NMS run here. Image [1,3,312,312] RGB, /255, ImageNet mean/std, NCHW.
 */
object RfDetr {
    const val SIDE = 312
    const val GRID = 26
    const val CELLS = GRID * GRID          // 676
    const val CLASSES = 91                 // index = COCO category id (0 unused)
    const val QUERIES = 100
    const val MASK = 78
    const val DIM = 256
    const val EMBED = 384

    // Float counts of every graph buffer (converter slot order is arbitrary: the device code resolves slots by these).
    const val N_IMAGE = 3 * SIDE * SIDE
    const val N_CLSPOS = EMBED
    const val N_POSPATCH = CELLS * EMBED
    const val N_ENC_CLASS = CELLS * CLASSES
    const val N_ENC_DELTA = CELLS * 4
    const val N_MEMORY = CELLS * DIM
    const val N_REF = QUERIES * 4
    const val N_QUERY_FEAT = QUERIES * DIM
    const val N_BOXES = QUERIES * 4
    const val N_LOGITS = QUERIES * CLASSES
    const val N_MASKS = QUERIES * MASK * MASK

    /** Default thresholds (guesses; tune on device): sigmoid score, per-class NMS IoU, max instances per run. */
    const val SCORE_THRESHOLD = 0.4f
    const val NMS_IOU = 0.5f
    const val MAX_INSTANCES = 20

    private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
    private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)

    /** Little-endian float32 bytes of a host constant (.bin); null when the size is not exactly [count] floats. */
    fun loadFloats(bytes: ByteArray, count: Int): FloatArray? {
        if (bytes.size != count * 4) return null
        val bb = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(count).also { bb.get(it) }
    }

    /**
     * Quarter turns (clockwise, 0..3) that make the sensor-oriented image upright, from where the image +x axis points on
     * screen ([dxView], [dyView], view y down): right = 0, down = 1, left = 2, up = 3.
     */
    fun quarterTurns(dxView: Float, dyView: Float): Int =
        if (Math.abs(dxView) >= Math.abs(dyView)) (if (dxView >= 0) 0 else 2) else (if (dyView >= 0) 1 else 3)

    /** Normalised point (u, v) of the UPRIGHT (rotated clockwise by [turns]) image -> normalised point of the original image. */
    fun unrotate(turns: Int, u: Float, v: Float): Pair<Float, Float> = when (((turns % 4) + 4) % 4) {
        0 -> u to v
        1 -> v to 1f - u
        2 -> 1f - u to 1f - v
        else -> 1f - v to u
    }

    /** Camera image -> [1,3,312,312] NCHW into [out] (nearest-neighbour squash of the image rotated by [turns]). */
    fun preprocess(img: SegImage, turns: Int, out: FloatArray) {
        require(out.size == N_IMAGE)
        val plane = SIDE * SIDE
        for (yy in 0 until SIDE) for (xx in 0 until SIDE) {
            val (x, y) = unrotate(turns, (xx + 0.5f) / SIDE, (yy + 0.5f) / SIDE)
            val c = img.argb((x * img.w).toInt().coerceIn(0, img.w - 1), (y * img.h).toInt().coerceIn(0, img.h - 1))
            val i = yy * SIDE + xx
            out[i] = (((c shr 16) and 0xFF) / 255f - MEAN[0]) / STD[0]
            out[plane + i] = (((c shr 8) and 0xFF) / 255f - MEAN[1]) / STD[1]
            out[2 * plane + i] = ((c and 0xFF) / 255f - MEAN[2]) / STD[2]
        }
    }

    /** memory = memory2 * 0.5 (the graph emits it doubled). */
    fun memory(memory2: FloatArray): FloatArray = FloatArray(memory2.size) { memory2[it] * 0.5f }

    /** The 100 proposals graph B starts from: [cell] indices and ts = [cx, cy, w, h] per proposal (flat [100*4]). */
    class Proposals(val cell: IntArray, val ts: FloatArray)

    /**
     * Proposal grid G=26 (row-major, cell = gy * 26 + gx): prop = ((gx+.5)/26, (gy+.5)/26); cxcy = delta[:2] * 0.05 + prop;
     * wh = exp(delta[2:]) * 0.05. The top 100 cells by max class logit (ties: lower cell first), best first.
     */
    fun proposals(encClass: FloatArray, encDelta: FloatArray): Proposals {
        require(encClass.size == N_ENC_CLASS && encDelta.size == N_ENC_DELTA)
        val best = FloatArray(CELLS) { c -> var m = Float.NEGATIVE_INFINITY; for (k in 0 until CLASSES) m = max(m, encClass[c * CLASSES + k]); m }
        val order = (0 until CELLS).sortedWith(compareByDescending<Int> { best[it] }.thenBy { it }).take(QUERIES)
        val ts = FloatArray(N_REF)
        for ((n, c) in order.withIndex()) {
            val gx = c % GRID; val gy = c / GRID
            ts[4 * n] = encDelta[4 * c] * 0.05f + (gx + 0.5f) / GRID
            ts[4 * n + 1] = encDelta[4 * c + 1] * 0.05f + (gy + 0.5f) / GRID
            ts[4 * n + 2] = exp(encDelta[4 * c + 2]) * 0.05f
            ts[4 * n + 3] = exp(encDelta[4 * c + 3]) * 0.05f
        }
        return Proposals(order.toIntArray(), ts)
    }

    /** ref = [rp[:2] * ts.wh + ts.cxcy, exp(rp[2:]) * ts.wh] with rp = refpoint_embed [100,4]; flat [100*4]. */
    fun refPoints(ts: FloatArray, refpointEmbed: FloatArray): FloatArray {
        require(ts.size == N_REF && refpointEmbed.size == N_REF)
        val ref = FloatArray(N_REF)
        for (n in 0 until QUERIES) {
            val cx = ts[4 * n]; val cy = ts[4 * n + 1]; val w = ts[4 * n + 2]; val h = ts[4 * n + 3]
            ref[4 * n] = refpointEmbed[4 * n] * w + cx
            ref[4 * n + 1] = refpointEmbed[4 * n + 1] * h + cy
            ref[4 * n + 2] = exp(refpointEmbed[4 * n + 2]) * w
            ref[4 * n + 3] = exp(refpointEmbed[4 * n + 3]) * h
        }
        return ref
    }

    fun sigmoid(x: Float): Float = 1f / (1f + exp(-x))

    /** One candidate before NMS, in normalised coordinates of the UPRIGHT image. */
    class Candidate(val query: Int, val coco: Int, val score: Float, val x0: Float, val y0: Float, val x1: Float, val y1: Float)

    /** Per query: the best class 1..90 with sigmoid score >= [threshold] and a non-empty box. */
    fun candidates(boxes: FloatArray, logits: FloatArray, threshold: Float = SCORE_THRESHOLD): List<Candidate> {
        require(boxes.size == N_BOXES && logits.size == N_LOGITS)
        val out = ArrayList<Candidate>()
        for (q in 0 until QUERIES) {
            var k = 1; var m = Float.NEGATIVE_INFINITY
            for (c in 1 until CLASSES) { val l = logits[q * CLASSES + c]; if (l > m) { m = l; k = c } }
            val s = sigmoid(m)
            if (s < threshold || LabelMap.cocoName(k).isEmpty()) continue
            val cx = boxes[4 * q]; val cy = boxes[4 * q + 1]; val w = boxes[4 * q + 2]; val h = boxes[4 * q + 3]
            val x0 = (cx - w / 2).coerceIn(0f, 1f); val x1 = (cx + w / 2).coerceIn(0f, 1f)
            val y0 = (cy - h / 2).coerceIn(0f, 1f); val y1 = (cy + h / 2).coerceIn(0f, 1f)
            if (x1 - x0 <= 0f || y1 - y0 <= 0f) continue
            out.add(Candidate(q, k, s, x0, y0, x1, y1))
        }
        return out
    }

    private fun iou(a: Candidate, b: Candidate): Float {
        val iw = min(a.x1, b.x1) - max(a.x0, b.x0); val ih = min(a.y1, b.y1) - max(a.y0, b.y0)
        if (iw <= 0f || ih <= 0f) return 0f
        val inter = iw * ih
        val union = (a.x1 - a.x0) * (a.y1 - a.y0) + (b.x1 - b.x0) * (b.y1 - b.y0) - inter
        return if (union > 0f) inter / union else 0f
    }

    /** Per-class greedy NMS, best score first; at most [max] survivors overall. */
    fun nms(c: List<Candidate>, iouMax: Float = NMS_IOU, max: Int = MAX_INSTANCES): List<Candidate> {
        val kept = ArrayList<Candidate>()
        for (a in c.sortedWith(compareByDescending<Candidate> { it.score }.thenBy { it.query })) {
            if (kept.size >= max) break
            if (kept.none { it.coco == a.coco && iou(it, a) > iouMax }) kept.add(a)
        }
        return kept
    }

    /**
     * Candidate -> [Instance] in pixels of the ORIGINAL ([w] x [h]) image: box corners are un-rotated by [turns]; the
     * centroid is that of the mask pixels (logit > 0) inside the box (mask = [MASK] x [MASK] over the upright image),
     * the box centre when the mask is empty there.
     */
    fun toInstance(c: Candidate, masks: FloatArray?, turns: Int, w: Int, h: Int): Instance {
        val (ax, ay) = unrotate(turns, c.x0, c.y0)
        val (bx, by) = unrotate(turns, c.x1, c.y1)
        val box = Box2(min(ax, bx) * w, min(ay, by) * h, max(ax, bx) * w, max(ay, by) * h)
        var cu = (c.x0 + c.x1) / 2; var cv = (c.y0 + c.y1) / 2
        if (masks != null && masks.size == N_MASKS) {
            val off = c.query * MASK * MASK
            val mx0 = (c.x0 * MASK).toInt().coerceIn(0, MASK - 1); val mx1 = (c.x1 * MASK).toInt().coerceIn(0, MASK - 1)
            val my0 = (c.y0 * MASK).toInt().coerceIn(0, MASK - 1); val my1 = (c.y1 * MASK).toInt().coerceIn(0, MASK - 1)
            var sx = 0L; var sy = 0L; var n = 0L
            for (y in my0..my1) for (x in mx0..mx1) if (masks[off + y * MASK + x] > 0f) { sx += x; sy += y; n++ }
            if (n > 0) { cu = (sx.toFloat() / n + 0.5f) / MASK; cv = (sy.toFloat() / n + 0.5f) / MASK }
        }
        val (ox, oy) = unrotate(turns, cu, cv)
        return Instance(c.coco, LabelMap.cocoName(c.coco), c.score, box, ox * w, oy * h)
    }

    /** Graph B outputs -> instances (threshold, per-class NMS, un-rotation). */
    fun decode(boxes: FloatArray, logits: FloatArray, masks: FloatArray?, turns: Int, w: Int, h: Int,
               threshold: Float = SCORE_THRESHOLD, iouMax: Float = NMS_IOU, max: Int = MAX_INSTANCES): List<Instance> =
        nms(candidates(boxes, logits, threshold), iouMax, max).map { toInstance(it, masks, turns, w, h) }
}
