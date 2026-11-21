package dev.capturekit.sample

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Toast
import dev.capturekit.results.JobFile
import dev.capturekit.results.JobStatus
import dev.capturekit.sample.results.ResultsGate
import java.util.Locale

/**
 * Results of one uploaded scan, read from the roomscan-recon job server (field flavour only; the standard build has
 * no network and never opens this screen). Polls every 5 s while the job is queued or running. Shows the server's
 * verdict (never computed here), the stage stepper, measurement tiles, the floor plan, rescan hints and export links.
 * All network work runs on a worker thread. Nothing is invented: absent data shows as absent.
 */
class ResultsActivity : Activity() {
    companion object { const val EXTRA_BUNDLE_ID = "bundle_id" }

    private lateinit var body: LinearLayout
    private lateinit var plan: WebView
    private lateinit var planHolder: FrameLayout
    @Volatile private var generation = 0
    @Volatile private var planLoadedFor: String? = null
    @Volatile private var visible = false
    private var bundleId = ""
    private var rendered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        bundleId = intent.getStringExtra(EXTRA_BUNDLE_ID).orEmpty()
        // No screen to host a snackbar yet: the activity closes at once, so this one stays a Toast.
        if (bundleId.isBlank()) { Toast.makeText(this, "This scan has no id, so there are no results to show.", Toast.LENGTH_LONG).show(); finish(); return }
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        plan = WebView(this).apply { setBackgroundColor(Color.WHITE); contentDescription = "Floor plan" }
        planHolder = FrameLayout(this).apply {
            background = UiKit.rounded(Color.WHITE, dp(DesignTokens.R_16).toFloat())
            clipToOutline = true
            addView(plan, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(UiKit.topBar(this, "Results", onBack = { finish() }), lp(DesignTokens.SP_8))
        root.addView(ScrollView(this).apply { isFillViewport = true; isVerticalScrollBarEnabled = false; addView(body) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        UiKit.applyInsets(root, DesignTokens.SP_16)
        setContentView(UiKit.page(this, root))
        loading()
    }

    override fun onResume() {
        super.onResume()
        visible = true
        if (bundleId.isBlank()) return
        startLoop()
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    override fun onDestroy() {
        if (::plan.isInitialized) plan.destroy()
        super.onDestroy()
    }

    /** Fetches on a worker thread; repeats every 5 s while the job is queued or running and the screen is visible. */
    private fun startLoop() {
        val gen = ++generation
        var lastGoodActive = false   // last good answer said the job is still running: a failed fetch must not stop the polling
        var haveGood = false
        Thread {
            while (visible && gen == generation) {
                val f = ResultsGate.status(bundleId)
                val job = f.text?.let { JobStatus.parse(it) }
                val svg = job?.file("floorplan_svg")?.takeIf { it.url != planLoadedFor }?.let { it to ResultsGate.fetchText(it.url).text }
                val showError = !haveGood
                runOnUiThread {
                    if (isDestroyed || gen != generation) return@runOnUiThread
                    if (job != null) render(job, svg)
                    else if (showError) message(f.error ?: "The server sent an answer this app does not understand.")
                }
                if (job != null) { haveGood = true; lastGoodActive = job.isActive }
                if (!lastGoodActive) break
                try { Thread.sleep(5000) } catch (e: InterruptedException) { break }
            }
        }.start()
    }

    /** Skeleton cards while the first answer is on its way. */
    private fun loading() {
        body.removeAllViews()
        body.contentDescription = "Loading the results"
        body.addView(UiKit.skeleton(this, -1, 72, DesignTokens.R_16), lp(DesignTokens.SP_16))
        body.addView(UiKit.skeleton(this, -1, 200, DesignTokens.R_16), lp(DesignTokens.SP_16))
        body.addView(UiKit.skeleton(this, -1, 96, DesignTokens.R_16), lp(DesignTokens.SP_16))
    }

    /** Error / notice state (the server could not be reached, or sent something unreadable). */
    private fun message(msg: String) {
        body.removeAllViews()
        body.contentDescription = null
        body.addView(UiKit.emptyState(this, R.drawable.ic_cloud_off, "No results to show", msg),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(DesignTokens.SP_32) })
        UiKit.fadeIn(body)
    }

    private fun render(job: JobStatus, svg: Pair<JobFile, String?>?) {
        body.removeAllViews()
        body.contentDescription = null
        headline(job)
        stages(job)
        measurements(job)
        floorPlan(job, svg)
        rescan(job)
        exports(job)
        // Fade only the first render; the 5 s refresh redraws in place.
        if (!rendered) { rendered = true; UiKit.fadeIn(body) }
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
        val (icon, tint, container) = when (kind) {
            UiKit.Kind.OK -> Triple(R.drawable.ic_check, UiKit.GREEN, DesignTokens.SUCCESS_CONTAINER)
            UiKit.Kind.WARN -> Triple(R.drawable.ic_warning, UiKit.AMBER, DesignTokens.WARNING_CONTAINER)
            UiKit.Kind.ERROR -> Triple(R.drawable.ic_warning, UiKit.RED, DesignTokens.ERROR_CONTAINER)
            UiKit.Kind.INFO -> Triple(if (job.isActive) R.drawable.ic_timer else R.drawable.ic_info, UiKit.ACCENT, UiKit.SURFACE_2)
        }
        body.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = UiKit.rounded(container, dp(DesignTokens.R_16).toFloat())
            setPadding(dp(DesignTokens.SP_16), dp(DesignTokens.SP_16), dp(DesignTokens.SP_16), dp(DesignTokens.SP_16))
            addView(UiKit.iconTile(context, icon, tint, 40), LinearLayout.LayoutParams(dp(40), dp(40)).apply { rightMargin = dp(DesignTokens.SP_16) })
            addView(UiKit.role(context, msg, DesignTokens.TITLE_MEDIUM), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }, lp(DesignTokens.SP_12))
        job.validation?.issues?.filter { it.severity == "ERROR" || it.severity == "WARN" }?.takeIf { it.isNotEmpty() }?.let { issues ->
            body.addView(UiKit.body(this, "Server check notes: " + issues.joinToString("; ") { it.message.ifEmpty { it.code } }, UiKit.LABEL_2, DesignTokens.BODY_MEDIUM.sizeSp), lp(DesignTokens.SP_16))
        }
        body.getChildAt(body.childCount - 1).let { if (it.layoutParams is LinearLayout.LayoutParams) (it.layoutParams as LinearLayout.LayoutParams).bottomMargin = dp(DesignTokens.SP_24) }
    }

    /** One stepper node: tick on green (done), clock on amber (running), cross on red (failed), empty ring otherwise. */
    private fun stageNode(status: String): View {
        val (icon, tint, bg) = when (status) {
            "ok" -> Triple<Int?, Int, Int>(R.drawable.ic_check, UiKit.GREEN, DesignTokens.SUCCESS_CONTAINER)
            "running" -> Triple<Int?, Int, Int>(R.drawable.ic_timer, UiKit.AMBER, DesignTokens.WARNING_CONTAINER)
            "failed" -> Triple<Int?, Int, Int>(R.drawable.ic_close, UiKit.RED, DesignTokens.ERROR_CONTAINER)
            else -> Triple<Int?, Int, Int>(null, UiKit.LABEL_3, UiKit.SURFACE_2)
        }
        return FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(bg)
                if (icon == null) setStroke(dp(2), DesignTokens.OUTLINE)
            }
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            if (icon != null) addView(UiKit.iconImage(context, icon, tint), FrameLayout.LayoutParams(dp(14), dp(14), Gravity.CENTER))
        }
    }

    private fun stages(job: JobStatus) {
        if (job.stages.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Progress"))
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = UiKit.card(context, DesignTokens.R_16)
            setPadding(dp(DesignTokens.SP_16), dp(DesignTokens.SP_16), dp(DesignTokens.SP_16), dp(DesignTokens.SP_16))
        }
        job.stages.forEachIndexed { i, s ->
            val last = i == job.stages.lastIndex
            val (label, color) = when (s.status) {
                "ok" -> "Done" to UiKit.GREEN
                "running" -> "Running" to UiKit.AMBER
                "failed" -> "Failed" to UiKit.RED
                "skipped" -> "Skipped" to UiKit.LABEL_3
                else -> "Waiting" to UiKit.LABEL_3
            }
            val reason = s.reason.takeIf { !it.isNullOrBlank() && s.status != "ok" }
            val sub = listOfNotNull(reason, if (s.where == "gpu_worker" && s.status == "pending") "Runs on the GPU computer" else null).joinToString(" · ").ifEmpty { null }
            val title = stageTitle(s.name)
            card.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                contentDescription = "$title: $label" + (sub?.let { ". $it" } ?: "")
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER_HORIZONTAL
                    addView(stageNode(s.status), LinearLayout.LayoutParams(dp(24), dp(24)))
                    if (!last) addView(View(context).apply { setBackgroundColor(DesignTokens.OUTLINE) }, LinearLayout.LayoutParams(dp(2), 0, 1f).apply { topMargin = dp(4); bottomMargin = dp(4) })
                }, LinearLayout.LayoutParams(dp(24), ViewGroup.LayoutParams.MATCH_PARENT).apply { rightMargin = dp(DesignTokens.SP_16) })
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    if (!last) setPadding(0, 0, 0, dp(DesignTokens.SP_16))
                    addView(LinearLayout(context).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        addView(UiKit.role(context, title, DesignTokens.TITLE_MEDIUM), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                        addView(UiKit.role(context, label, DesignTokens.LABEL_MEDIUM, color))
                    })
                    if (sub != null) addView(UiKit.role(context, sub, DesignTokens.BODY_MEDIUM, UiKit.LABEL_2),
                        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2) })
                }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            })
        }
        body.addView(card, lp(DesignTokens.SP_24))
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
        val tiles = ArrayList<View>()
        fun add(label: String, key: String, unit: String, icon: Int, scale: Double = 1.0, digits: Int = 2) {
            job.measure(key)?.let { tiles.add(UiKit.statTile(this, icon, label, String.format(Locale.US, "%.${digits}f", it * scale) + unit)) }
        }
        add("Floor area", "floor_area_m2", " m²", R.drawable.ic_floorplan)
        add("Perimeter", "perimeter_m", " m", R.drawable.ic_floorplan)
        add("Ceiling height", "ceiling_height_m", " m", R.drawable.ic_layers)
        add("Volume", "volume_m3", " m³", R.drawable.ic_cube, digits = 1)
        add("Scale confidence", "scale_confidence", " %", R.drawable.ic_check, scale = 100.0, digits = 0)
        if (tiles.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Measurements"))
        for (pair in tiles.chunked(2)) {
            val line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (i in 0 until 2) line.addView(pair.getOrNull(i) ?: View(this),
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) leftMargin = dp(DesignTokens.SP_12) })
            body.addView(line, lp(DesignTokens.SP_12))
        }
        (body.getChildAt(body.childCount - 1).layoutParams as LinearLayout.LayoutParams).bottomMargin = dp(DesignTokens.SP_24)
    }

    private fun floorPlan(job: JobStatus, svg: Pair<JobFile, String?>?) {
        val f = job.file("floorplan_svg") ?: return
        if (svg != null && svg.second != null) {
            plan.loadDataWithBaseURL(null, svg.second!!, "image/svg+xml", "utf-8", null)
            planLoadedFor = f.url
        }
        if (planLoadedFor != f.url) return
        body.addView(UiKit.sectionHeader(this, "Floor plan"))
        (planHolder.parent as? ViewGroup)?.removeView(planHolder)
        body.addView(planHolder, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(300)).apply { bottomMargin = dp(DesignTokens.SP_24) })
    }

    private fun rescan(job: JobStatus) {
        val items = job.rescanByPriority
        if (items.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Areas to scan again"))
        for (r in items) {
            val card = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                background = UiKit.card(context, DesignTokens.R_16)
                setPadding(dp(DesignTokens.SP_16), dp(DesignTokens.SP_16), dp(DesignTokens.SP_16), dp(DesignTokens.SP_16))
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    addView(UiKit.iconTile(context, R.drawable.ic_warning, UiKit.AMBER, 36), LinearLayout.LayoutParams(dp(36), dp(36)).apply { rightMargin = dp(DesignTokens.SP_12) })
                    addView(UiKit.role(context, r.surface.replaceFirstChar { it.uppercase() }, DesignTokens.TITLE_MEDIUM), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
                })
                addView(UiKit.role(context, r.instruction.ifEmpty { "Scan this area again." }, DesignTokens.BODY_LARGE, UiKit.LABEL_2),
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(DesignTokens.SP_12); bottomMargin = dp(DesignTokens.SP_12) })
                addView(UiKit.secondaryButton(context, "Rescan this area").apply {
                    contentDescription = "Rescan this area: ${r.surface}"
                    setOnClickListener { startActivity(Intent(this@ResultsActivity, CaptureActivity::class.java)) }
                })
            }
            body.addView(card, lp(DesignTokens.SP_12))
        }
    }

    /** File-type icon from the extension: floor plans and documents, 3D models, anything else. */
    private fun fileIcon(name: String): Int = when (name.substringAfterLast('.', "").lowercase(Locale.US)) {
        "svg", "pdf", "dxf" -> R.drawable.ic_floorplan
        "ply", "glb", "gltf", "obj", "splat", "spz", "usdz", "stl" -> R.drawable.ic_cube
        else -> R.drawable.ic_file
    }

    private fun exports(job: JobStatus) {
        if (job.files.isEmpty()) return
        body.addView(UiKit.sectionHeader(this, "Downloads"))
        val group = UiKit.group(this)
        for (f in job.files) {
            group.addView(UiKit.listRow(this, fileIcon(f.name), f.name, UiKit.humanSize(f.size),
                trailing = UiKit.iconImage(this, R.drawable.ic_download, UiKit.LABEL_2).apply { contentDescription = null }, chevron = false) {
                val abs = ResultsGate.absoluteUrl(f.url)
                if (abs == null) { UiKit.snackbar(this, "This link is not from the results server.", UiKit.Kind.ERROR); return@listRow }
                try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(abs))) }
                catch (e: ActivityNotFoundException) { UiKit.snackbar(this, "No app can open this file.", UiKit.Kind.WARN) }
            }.apply { contentDescription = "Download ${f.name}, ${UiKit.humanSize(f.size)}" })
        }
        body.addView(group, lp(DesignTokens.SP_24))
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(bottom) }
}
