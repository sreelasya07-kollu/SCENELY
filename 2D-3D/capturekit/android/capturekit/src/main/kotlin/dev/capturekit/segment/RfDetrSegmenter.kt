package dev.capturekit.segment

import android.content.Context
import android.util.Log
import com.google.ai.edge.litert.Accelerator
import com.google.ai.edge.litert.CompiledModel
import com.google.ai.edge.litert.Environment
import com.google.ai.edge.litert.TensorBuffer

/**
 * RF-DETR-Seg Nano on the LiteRT CompiledModel GPU (ADR 0035): graph A (image + two host constants -> encoder class /
 * delta / memory2), host math ([RfDetr]), graph B (memory, reference points, query features -> boxes, logits, masks).
 * Files are fetched by scripts/fetch_models.sh --with-segmentation (gitignored assets, never committed). The card says baked
 * large constants mis-execute on the ML Drift GPU delegate, so clspos / pospatch / query_feat are fed as inputs.
 * One shared [Environment]. GPU only: when it cannot be created the feature turns itself off (CPU would take 0.3 to 0.7 s).
 * UNVERIFIED until a device run: GPU creation on LiteRT 2.3.2 (the card measured 2.2.0), the proposal cell order
 * (row-major assumed), and that readFloat() on a fresh input buffer returns its full size (inputs and outputs are both told
 * apart by float count). Single-threaded: [segment] runs on the segmentation thread.
 */
class RfDetrSegmenter private constructor(
    private val env: Environment,
    private val ga: CompiledModel,
    private val gb: CompiledModel,
    private val refpoint: FloatArray,
    private val aIn: List<TensorBuffer>, private val aOut: List<TensorBuffer>,
    private val bIn: List<TensorBuffer>, private val bOut: List<TensorBuffer>,
    private val slotImage: Int, private val slotMem: Int, private val slotRef: Int,
    override val name: String,
) : Segmenter {
    private val chw = FloatArray(RfDetr.N_IMAGE)

    override fun segment(image: SegImage, quarterTurns: Int): List<Instance>? {
        if (image.w <= 0 || image.h <= 0) return null
        RfDetr.preprocess(image, quarterTurns, chw)
        aIn[slotImage].writeFloat(chw)
        ga.run(aIn, aOut)
        var encClass: FloatArray? = null; var encDelta: FloatArray? = null; var memory2: FloatArray? = null
        for (b in aOut) {
            val a = b.readFloat()
            when (a.size) { RfDetr.N_ENC_CLASS -> encClass = a; RfDetr.N_ENC_DELTA -> encDelta = a; RfDetr.N_MEMORY -> memory2 = a }
        }
        if (encClass == null || encDelta == null || memory2 == null) { Log.e(TAG, "graph A outputs not recognised"); return null }
        val props = RfDetr.proposals(encClass, encDelta)
        bIn[slotMem].writeFloat(RfDetr.memory(memory2))
        bIn[slotRef].writeFloat(RfDetr.refPoints(props.ts, refpoint))
        gb.run(bIn, bOut)
        var boxes: FloatArray? = null; var logits: FloatArray? = null; var masks: FloatArray? = null
        for (b in bOut) {
            val a = b.readFloat()
            when (a.size) { RfDetr.N_BOXES -> boxes = a; RfDetr.N_LOGITS -> logits = a; RfDetr.N_MASKS -> masks = a }
        }
        if (boxes == null || logits == null) { Log.e(TAG, "graph B outputs not recognised"); return null }
        return RfDetr.decode(boxes, logits, masks, quarterTurns, image.w, image.h)
    }

    override fun close() {
        for (b in aIn + aOut + bIn + bOut) try { b.close() } catch (_: Throwable) {}
        try { ga.close() } catch (_: Throwable) {}
        try { gb.close() } catch (_: Throwable) {}
        try { env.close() } catch (_: Throwable) {}
    }

    companion object {
        private const val TAG = "CK/Segment"
        const val GRAPH_A = "rfdetrseg_graphA_fp16.tflite"
        const val GRAPH_B = "rfdetrseg_graphB_fp16.tflite"
        const val CLSPOS = "clspos.bin"
        const val POSPATCH = "pospatch.bin"
        const val QUERY_FEAT = "query_feat.bin"
        const val REFPOINT = "refpoint_embed.bin"

        /** True when all six files are packaged (cheap: opens and closes the asset streams). Never throws. */
        fun available(context: Context): Boolean = listOf(GRAPH_A, GRAPH_B, CLSPOS, POSPATCH, QUERY_FEAT, REFPOINT).all {
            try { context.assets.open(it).close(); true } catch (_: Throwable) { false }
        }

        private fun floats(context: Context, asset: String, count: Int): FloatArray? =
            try { context.assets.open(asset).use { RfDetr.loadFloats(it.readBytes(), count) } } catch (_: Throwable) { null }

        /**
         * Slot of each candidate array among [bufs], told apart by float count: a buffer's size is the length of what
         * readFloat() returns for it (the counts are all distinct per graph, see RfDetrTest). The matching candidate is
         * written into its slot. Null when a buffer matches no candidate or two buffers share a size.
         */
        private fun bind(bufs: List<TensorBuffer>, cands: List<FloatArray>): IntArray? {
            val slot = IntArray(cands.size) { -1 }
            for ((bi, b) in bufs.withIndex()) {
                val n = try { b.readFloat().size } catch (_: Throwable) { return null }
                val ci = cands.indexOfFirst { it.size == n }
                if (ci < 0 || slot[ci] >= 0) return null
                slot[ci] = bi
                b.writeFloat(cands[ci])
            }
            return if (slot.all { it >= 0 }) slot else null
        }

        /** Loads both graphs on the GPU, or null (feature off) when a file is bad or the GPU delegate cannot compile them. Slow: worker thread only. */
        fun open(context: Context): RfDetrSegmenter? {
            if (!available(context)) return null
            val clspos = floats(context, CLSPOS, RfDetr.N_CLSPOS)
            val pospatch = floats(context, POSPATCH, RfDetr.N_POSPATCH)
            val queryFeat = floats(context, QUERY_FEAT, RfDetr.N_QUERY_FEAT)
            val refpoint = floats(context, REFPOINT, RfDetr.N_REF)
            if (clspos == null || pospatch == null || queryFeat == null || refpoint == null) { Log.e(TAG, "a host constant has the wrong size"); return null }
            var env: Environment? = null
            var ga: CompiledModel? = null
            var gb: CompiledModel? = null
            try {
                env = Environment.create()
                ga = CompiledModel.create(context.assets, GRAPH_A, CompiledModel.Options(Accelerator.GPU), env)
                gb = CompiledModel.create(context.assets, GRAPH_B, CompiledModel.Options(Accelerator.GPU), env)
                val aIn = ga.createInputBuffers(); val aOut = ga.createOutputBuffers()
                val bIn = gb.createInputBuffers(); val bOut = gb.createOutputBuffers()
                if (aIn.size != 3 || bIn.size != 3 || aOut.size != 3 || bOut.size != 3) { Log.e(TAG, "unexpected graph layout: A ${aIn.size}->${aOut.size}, B ${bIn.size}->${bOut.size}"); throw IllegalStateException("layout") }
                val image = FloatArray(RfDetr.N_IMAGE)
                val sa = bind(aIn, listOf(image, clspos, pospatch)) ?: throw IllegalStateException("graph A input slots")
                val mem = FloatArray(RfDetr.N_MEMORY); val ref = FloatArray(RfDetr.N_REF)
                val sb = bind(bIn, listOf(mem, queryFeat, ref)) ?: throw IllegalStateException("graph B input slots")
                return RfDetrSegmenter(env, ga, gb, refpoint, aIn, aOut, bIn, bOut, sa[0], sb[0], sb[2], "rf-detr-seg-nano gpu")
                    .also { Log.i(TAG, "segmenter ready: ${it.name}") }
            } catch (t: Throwable) {
                Log.e(TAG, "RF-DETR-Seg GPU init failed: segmentation off", t)
                try { ga?.close() } catch (_: Throwable) {}
                try { gb?.close() } catch (_: Throwable) {}
                try { env?.close() } catch (_: Throwable) {}
                return null
            }
        }
    }
}
