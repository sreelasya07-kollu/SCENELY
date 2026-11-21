package dev.capturekit.sample

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import dev.capturekit.results.JobFile
import dev.capturekit.results.JobStatus
import dev.capturekit.sample.results.ResultsGate
import java.util.Locale

/**
 * Results of one uploaded scan, read from the roomscan-recon job server (field flavour only; the standard build has
 * no network and never opens this screen). Polls every 5 s while the job is queued or running. Shows the server's
 * verdict (never computed here), the stage list, measurements, the floor plan, rescan hints and export links.
 * All network work runs on a worker thread. Nothing is invented: absent data shows as absent.
 */
class ResultsActivity : Activity() {
    companion object { const val EXTRA_BUNDLE_ID = "bundle_id" }

    private lateinit var body: LinearLayout
    private lateinit var plan: WebView
    private lateinit var planHolder: FrameLayout
    private var generation = 0
    private var planLoadedFor: String? = null
    @Volatile private var visible = false
    private var bundleId = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bundleId = intent.getStringExtra(EXTRA_BUNDLE_ID).orEmpty()
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        plan = WebView(this).apply { setBackgroundColor(Color.WHITE); contentDescription = "Floor plan" }
        planHolder = FrameLayout(this).apply {
            background = UiKit.rounded(Color.WHITE, dp(16).toFloat())
            clipToOutline = true
            addView(plan, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(UiKit.circularIconButton(this, R.drawable.ic_arrow_back, "Back to my scans", 44).apply { setOnClickListener { finish() } },
            LinearLayout.LayoutParams(dp(44), dp(44)).apply { bottomMargin = dp(16) })
        root.addView(UiKit.largeTitle(this, "Results"), lp(16))
        root.addView(ScrollView(this).apply { isFillViewport = true; isVerticalScrollBarEnabled = false; addView(body) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        UiKit.applyInsets(root, 20)
        setContentView(UiKit.page(this, root))
        message("Loading the results...")
    }

    override fun onResume() {
        super.onResume()
        visible = true
        startLoop()
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    override fun onDestroy() {
        plan.destroy()
        super.onDestroy()
    }

    /** Fetches on a worker thread; repeats every 5 s while the job is queued or running and the screen is visible. */
    private fun startLoop() {
        val gen = ++generation
        Thread {
            while (visible && gen == generation) {
                val f = ResultsGate.status(bundleId)
                val job = f.text?.let { JobStatus.parse(it) }
                val svg = job?.file("floorplan_svg")?.takeIf { it.url != planLoadedFor }?.let { it to ResultsGate.fetchText(it.url).text }
                runOnUiThread {
                    if (isDestroyed || gen != generation) return@runOnUiThread
                    if (job == null) message(f.error ?: "The server sent an answer this app does not understand.") else render(job, svg)
                }
                if (job == null || !job.isActive) break
                try { Thread.sleep(5000) } catch (e: InterruptedException) { break }
            }
        }.start()
    }

    private fun message(msg: String) {
        body.removeAllViews()
        body.addView(TextView(this).apply { text = msg; textSize = 16f; setTextColor(UiKit.LABEL_2); gravity = Gravity.CENTER; setPadding(0, dp(48), 0, 0) }, lp(0))
    }

    private fun render(job: JobStatus, svg: Pair<JobFile, String?>?) {
        body.removeAllViews()
        headline(job)
        stages(job)
        measurements(job)
        floorPlan(job, svg)
        rescan(job)
        exports(job)
    }

    private fun headline(job: JobStatus) {
        val (msg, kind) = when {
            job.state == "failed" -> "Processing failed${job.error?.let { ": $it" } ?: "."}" to UiKit.Kind.ERROR
            job.state == "rejected" -> "The server could not use this scan${job.error?.let { ": $it" } ?: "."}" to UiKit.Kind.ERROR
            job.verdict == "pass" -> "The scan looks good." to UiKit.Kind.OK
            job.verdict == "pass_with_warnings" -> "The scan is usable, with some notes." to UiKit.Kind.WARN
            job.verdict == "needs_rescan" -> "Part of the room needs another scan." to UiKit.Kind.ERROR
            job.isActive -> (if (job.state == "queued") "Waiting for the server to start." else "Processing your scan...") to UiKit.Kind.INFO
            else -> "No verdict yet." to UiKit.Kind.INFO
        }
        body.addView(UiKit.banner(this, msg, kind).apply { textSize = 17f }, lp(16))
        job.validation?.issues?.filter { it.severity == "ERROR" || it.severity == "WARN" }?.takeIf { it.isNotEmpty() }?.let { issues ->
            body.addView(UiKit.body(this, "Server check notes: " + issues.joinToString("; ") { it.message.ifEmpty { it.code } }), lp(16))
        }
    }

    private fun stages(job: JobStatus) {
        if (job.stages.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Progress"))
        val group = UiKit.group(this)
        for (s in job.stages) {
            val (label, color) = when (s.status) {
                "ok" -> "Done" to UiKit.GREEN
                "running" -> "Running" to UiKit.AMBER
                "failed" -> "Failed" to UiKit.RED
                "skipped" -> "Skipped" to UiKit.LABEL_3
                else -> "Waiting" to UiKit.LABEL_3
            }
            val reason = s.reason.takeIf { !it.isNullOrBlank() && s.status != "ok" }
            val sub = listOfNotNull(reason, if (s.where == "gpu_worker" && s.status == "pending") "Runs on the GPU computer" else null).joinToString(" · ").ifEmpty { null }
            group.addView(UiKit.listRow(this, null, stageTitle(s.name), sub,
                trailing = UiKit.text(this, UiKit.dotted(label, color), 14f, UiKit.LABEL_2), chevron = false))
        }
        body.addView(group, lp(24))
    }

    private fun stageTitle(name: String) = when (name) {
        "validate" -> "Scan check"
        "spatial" -> "Camera poses"
        "recon" -> "Reconstruction"
        "export" -> "Floor plan and exports"
        "qa" -> "Quality report"
        "splat" -> "3D splat"
        "splat_eval" -> "Splat quality"
        else -> name
    }

    private fun measurements(job: JobStatus) {
        val rows = ArrayList<Pair<String, String>>()
        fun add(label: String, key: String, unit: String, scale: Double = 1.0, digits: Int = 2) {
            job.measure(key)?.let { rows.add(label to String.format(Locale.US, "%.${digits}f", it * scale) + unit) }
        }
        add("Floor area", "floor_area_m2", " m²")
        add("Perimeter", "perimeter_m", " m")
        add("Ceiling height", "ceiling_height_m", " m")
        add("Volume", "volume_m3", " m³", digits = 1)
        add("Scale confidence", "scale_confidence", " %", scale = 100.0, digits = 0)
        if (rows.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Measurements"))
        val group = UiKit.group(this)
        for ((k, v) in rows) group.addView(UiKit.listRow(this, null, k, trailing = UiKit.text(this, v, 16f, UiKit.LABEL), chevron = false))
        body.addView(group, lp(24))
    }

    private fun floorPlan(job: JobStatus, svg: Pair<JobFile, String?>?) {
        val f = job.file("floorplan_svg") ?: return
        if (svg != null && svg.second != null) {
            plan.loadDataWithBaseURL(null, svg.second!!, "image/svg+xml", "utf-8", null)
            planLoadedFor = f.url
        }
        if (planLoadedFor != f.url) return
        body.addView(UiKit.sectionHeader(this, "Floor plan"))
        body.addView(planHolder, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(300)).apply { bottomMargin = dp(24) })
    }

    private fun rescan(job: JobStatus) {
        val items = job.rescanByPriority
        if (items.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Areas to scan again"))
        for (r in items) {
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                background = UiKit.card(context, UiKit.RADIUS_DP)
                setPadding(dp(16), dp(14), dp(16), dp(14))
                addView(UiKit.text(context, r.surface.replaceFirstChar { it.uppercase() }, 16f, UiKit.LABEL, UiKit.MEDIUM))
                addView(UiKit.body(context, r.instruction.ifEmpty { "Scan this area again." }), lp(10).apply { topMargin = dp(4) })
                addView(UiKit.secondaryButton(context, "Rescan this area").apply {
                    contentDescription = "Rescan this area: ${r.surface}"
                    setOnClickListener { startActivity(Intent(this@ResultsActivity, CaptureActivity::class.java)) }
                })
            }
            body.addView(card, lp(12))
        }
    }

    private fun exports(job: JobStatus) {
        if (job.files.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Downloads"))
        val group = UiKit.group(this)
        for (f in job.files) {
            group.addView(UiKit.listRow(this, null, f.name, UiKit.humanSize(f.size), chevron = true) {
                try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(ResultsGate.absoluteUrl(f.url)))) }
                catch (e: ActivityNotFoundException) { Toast.makeText(this, "No app can open this file.", Toast.LENGTH_SHORT).show() }
            })
        }
        body.addView(group, lp(24))
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(bottom) }
}
