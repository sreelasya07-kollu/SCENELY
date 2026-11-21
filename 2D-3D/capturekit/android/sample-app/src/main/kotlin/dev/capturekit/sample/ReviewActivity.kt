package dev.capturekit.sample

import android.app.Activity
import android.content.Intent
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import dev.capturekit.capture.EventParser
import dev.capturekit.guidance.Completeness
import dev.capturekit.guidance.ObjectSummary
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.capturekit.nativebridge.Status
import dev.capturekit.sample.upload.UploadGate
import dev.capturekit.upload.BundleArchive
import dev.capturekit.upload.UploadState
import dev.capturekit.upload.UploadStatus
import dev.capturekit.upload.UploadWorker
import dev.capturekit.verdict.ScanInfo
import dev.capturekit.verdict.VerdictText
import java.io.File

/**
 * Review screen after Finish: save status, the validator verdict the core wrote into manifest.json
 * (PASS / WARN / FAIL) in plain language (assets/verdict_messages.json), keyframes, size, duration and the bundle
 * path. Field flavour: queues the upload when the user allowed it and the verdict is not FAIL, and shows its state.
 * Standard flavour has no INTERNET permission: nothing is queued and no upload state is shown.
 */
class ReviewActivity : Activity() {
    data class Parsed(val verdict: String?, val keyframes: Int?, val issues: List<String>, val durationMs: Long? = null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dir = File(intent.getStringExtra(EXTRA_DIR) ?: "")
        val status = intent.getIntExtra(EXTRA_STATUS, Status.STATE)
        val elapsed = intent.getLongExtra(EXTRA_ELAPSED_MS, 0L)
        val kfLive = intent.getIntExtra(EXTRA_KEYFRAMES, 0)
        // Skeleton placeholders while the manifest is read off the main thread.
        setContentView(UiKit.page(this, LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            contentDescription = "Checking the scan"
            addView(UiKit.skeleton(context, -1, 96, DesignTokens.R_24), lp(DesignTokens.SP_16))
            addView(UiKit.skeleton(context, -1, 88, DesignTokens.R_16), lp(DesignTokens.SP_12))
            addView(UiKit.skeleton(context, -1, 88, DesignTokens.R_16), lp(DesignTokens.SP_12))
            UiKit.applyInsets(this, DesignTokens.SP_24)
        }))
        // Disk reads (manifest, bundle size) stay off the UI thread.
        Thread {
            val text = try { BundleArchive.manifestText(dir) } catch (t: Throwable) { "" }   // folder or zip
            val parsed = parseManifest(text)
            val issues = VerdictText.issuesOf(text)
            val vt = ScanUi.verdictText(applicationContext)
            val size = try { BundleArchive.sizeBytes(dir) } catch (t: Throwable) { 0L }
            // Upload only with the user's upload consent and a non-FAIL verdict (field flavour; a no-op in standard).
            if (status == Status.OK && UploadGate.available) try {
                // Only a never-queued scan is queued here; a failed one waits for the explicit Retry in My scans.
                if (UploadWorker.status(applicationContext, dir).state == UploadState.NONE) UploadGate.enqueueIfAllowed(applicationContext, dir, parsed.verdict)
            } catch (t: Throwable) { }
            runOnUiThread { if (!isDestroyed) build(dir, status, elapsed, kfLive, parsed, size, vt, issues) }
        }.start()
    }

    private var uploadChip: TextView? = null

    /** Polls WorkManager off the main thread until the upload reaches a final state or the screen closes. */
    private fun watchUpload(dir: File) {
        Thread {
            while (!isDestroyed) {
                val st = UploadWorker.status(applicationContext, dir)
                runOnUiThread { if (!isDestroyed) uploadChip?.let { ScanUi.paintUpload(it, st) } }
                if (st.state == UploadState.VERIFIED || st.state == UploadState.FAILED || st.state == UploadState.NONE) break
                try { Thread.sleep(2000) } catch (e: InterruptedException) { break }
            }
        }.start()
    }

    private fun build(dir: File, status: Int, elapsed: Long, kfLive: Int, manifest: Parsed, size: Long, vt: VerdictText, issueList: List<VerdictText.Issue>) {
        val verdict = if (status == Status.OK) manifest.verdict else null
        val kf = manifest.keyframes ?: kfLive
        val ok = status == Status.OK
        val ready = ok && verdict != "FAIL"
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT

        // Landscape: two columns (verdict on the left, numbers on the right); portrait: one column. The page scrolls and the
        // actions sit in a sticky bar, so they are reachable in both orientations.
        val landscape = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val colA = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val colB = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        // Feature switches (ADR 0032): "Found" counts = detector.
        val features = Features.get(this)

        // ---- Verdict hero: status icon on a tinted circle, headline, check chip ----
        val (vText, vColor) = when {
            !ok -> "Not saved (status ${UiKit.statusName(status)})" to UiKit.RED
            else -> ScanInfo.badgeText(verdict) to ScanUi.verdictColor(verdict)
        }
        val (heroIcon, heroTint, heroBg) = when {
            !ok || verdict == "FAIL" -> Triple(R.drawable.ic_close, UiKit.RED, DesignTokens.ERROR_CONTAINER)
            verdict == "PASS" -> Triple(R.drawable.ic_check, UiKit.GREEN, DesignTokens.SUCCESS_CONTAINER)
            verdict == "WARN" -> Triple(R.drawable.ic_warning, UiKit.AMBER, DesignTokens.WARNING_CONTAINER)
            else -> Triple(R.drawable.ic_info, UiKit.LABEL_2, UiKit.SURFACE_3)
        }
        val headline = when {
            ok && verdict != null -> vt.headline(verdict)
            ok -> "Scan saved"
            else -> "Save failed"
        }
        colA.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(FrameLayout(context).apply {
                background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(heroBg) }
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                addView(UiKit.iconImage(context, heroIcon, heroTint), FrameLayout.LayoutParams(dp(36), dp(36), Gravity.CENTER))
            }, LinearLayout.LayoutParams(dp(72), dp(72)))
            addView(UiKit.role(context, headline, DesignTokens.HEADLINE_SMALL).apply {
                gravity = Gravity.CENTER
                if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            }, LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(DesignTokens.SP_16) })
            addView(UiKit.chip(context).also { UiKit.setChip(it, vText, vColor) },
                LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(DesignTokens.SP_12) })
        }, lp(DesignTokens.SP_24))

        // Plain-language result: up to three notes (title, what happened, what to do), errors first.
        if (ok && verdict != null) {
            val notes = vt.describe(issueList)
            if (notes.isNotEmpty()) {
                val card = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    background = UiKit.card(context, DesignTokens.R_16)
                    setPadding(dp(DesignTokens.SP_16), dp(DesignTokens.SP_8), dp(DesignTokens.SP_16), dp(DesignTokens.SP_8))
                }
                for (n in notes.take(3)) card.addView(LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    setPadding(0, dp(DesignTokens.SP_8), 0, dp(DesignTokens.SP_8))
                    contentDescription = "${if (n.severity == "ERROR") "Problem" else "Note"}: ${n.title}. ${n.text} ${n.action}"
                    addView(UiKit.iconImage(context, R.drawable.ic_warning, if (n.severity == "ERROR") UiKit.RED else UiKit.AMBER),
                        LinearLayout.LayoutParams(dp(20), dp(20)).apply { rightMargin = dp(DesignTokens.SP_12); topMargin = dp(2) })
                    addView(LinearLayout(context).apply {
                        orientation = LinearLayout.VERTICAL
                        addView(UiKit.role(context, n.title, DesignTokens.TITLE_SMALL))
                        addView(UiKit.role(context, "${n.text} ${n.action}", DesignTokens.BODY_MEDIUM, UiKit.LABEL_2),
                            LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(2) })
                    }, LinearLayout.LayoutParams(0, wrap, 1f))
                })
                if (notes.size > 3) card.addView(UiKit.role(this, "and ${notes.size - 3} more", DesignTokens.BODY_MEDIUM, UiKit.LABEL_3),
                    LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(DesignTokens.SP_4); bottomMargin = dp(DesignTokens.SP_8) })
                colA.addView(card, lp(DesignTokens.SP_16))
            }
        }
        colA.addView(UiKit.role(this, when {
            ready -> "The scan is stored on this phone."
            ok -> "Not ready: the check failed. Scan again, moving slowly and covering the whole room."
            else -> "Something went wrong while saving. Scan again."
        }, DesignTokens.BODY_LARGE, UiKit.LABEL_2), lp(DesignTokens.SP_12))
        if (ready && UploadGate.available) {
            val chip = UiKit.chip(this).also { uploadChip = it; it.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES; it.setPadding(dp(12), dp(6), dp(12), dp(6)) }
            ScanUi.paintUpload(chip, UploadStatus(UploadState.NONE))
            colA.addView(chip, LinearLayout.LayoutParams(wrap, wrap).apply { bottomMargin = dp(DesignTokens.SP_16) })
            watchUpload(dir)
        }

        // ---- Numbers: 2x2 stat tiles ----
        val tiles = ArrayList<View>()
        // Live elapsed time when coming from a scan; otherwise the bundle's own clock span (opened from My scans).
        val durationMs = if (elapsed > 0) elapsed else manifest.durationMs
        if (durationMs != null && durationMs > 0) tiles.add(UiKit.statTile(this, R.drawable.ic_timer, "Duration", UiKit.mmss(durationMs)))
        tiles.add(UiKit.statTile(this, R.drawable.ic_layers, "Keyframes", kf.toString()))
        // Completeness and weak zones from the last live snapshot (contract C3, Intent extra only).
        val summary = parseSummary(intent.getStringExtra(Completeness.EXTRA))
        if (summary != null) tiles.add(UiKit.statTile(this, R.drawable.ic_check, "Complete", "${summary.first}%").apply {
            contentDescription = "Scan completeness ${summary.first} percent"
        })
        tiles.add(UiKit.statTile(this, R.drawable.ic_file, "Size", UiKit.humanSize(size)))
        for (pair in tiles.chunked(2)) {
            val line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (i in 0 until 2) line.addView(pair.getOrNull(i) ?: View(this),
                LinearLayout.LayoutParams(0, wrap, 1f).apply { if (i > 0) leftMargin = dp(DesignTokens.SP_12) })
            colB.addView(line, lp(DesignTokens.SP_12))
        }

        // What the scan recognised (issue #2 D): objects by class plus doors / windows, from the last room snapshot.
        if (features.detector) {
            val found = ObjectSummary.text(
                EventParser.parseObjects(intent.getStringExtra(EXTRA_OBJECTS) ?: ""),
                EventParser.parseOpenings(intent.getStringExtra(EXTRA_OPENINGS) ?: ""),
            )
            val foundText = when {
                found.isNotEmpty() -> found
                intent.getBooleanExtra(EXTRA_OBJECTS_EXPECTED, false) -> "No objects recognised"
                else -> null
            }
            if (foundText != null) colB.addView(UiKit.group(this).apply {
                addView(UiKit.listRow(context, R.drawable.ic_boxes, "Found", foundText, chevron = false).apply {
                    contentDescription = if (found.isNotEmpty()) "Found in the room: $found" else "Found in the room: no objects recognised"
                })
            }, lp(DesignTokens.SP_12))
        }

        // "To improve": the weak zones, one icon row each.
        if (summary != null && summary.second.isNotEmpty()) {
            colB.addView(UiKit.sectionHeader(this, "To improve"))
            colB.addView(UiKit.group(this).apply {
                for (z in summary.second) addView(UiKit.listRow(context, R.drawable.ic_warning, z, titleColor = UiKit.AMBER, chevron = false))
            }, lp(DesignTokens.SP_12))
        }

        // Collapsible details: folder name and the full path (selectable so it can be copied).
        val detailsBody = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            setPadding(dp(DesignTokens.SP_16), 0, dp(DesignTokens.SP_16), dp(DesignTokens.SP_16))
            addView(UiKit.role(context, "Folder", DesignTokens.LABEL_MEDIUM, UiKit.LABEL_3))
            addView(UiKit.role(context, dir.name, DesignTokens.BODY_MEDIUM).apply { setTextIsSelectable(true) })
            addView(UiKit.pathText(context, dir.absolutePath, Int.MAX_VALUE).apply { ellipsize = null; setTextIsSelectable(true) },
                LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(DesignTokens.SP_8) })
        }
        val chevron = UiKit.iconImage(this, R.drawable.ic_chevron_right, UiKit.LABEL_3)
        val detailsHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(DesignTokens.TOUCH_TARGET)
            setPadding(dp(DesignTokens.SP_16), dp(DesignTokens.SP_8), dp(DesignTokens.SP_16), dp(DesignTokens.SP_8))
            isClickable = true
            isFocusable = true
            foreground = UiKit.rowRipple()
            contentDescription = "Details, collapsed"
            addView(UiKit.role(context, "Details", DesignTokens.TITLE_MEDIUM), LinearLayout.LayoutParams(0, wrap, 1f))
            addView(chevron, LinearLayout.LayoutParams(dp(18), dp(18)))
            setOnClickListener {
                val open = detailsBody.visibility != View.VISIBLE
                if (open) UiKit.fadeIn(detailsBody) else detailsBody.visibility = View.GONE
                chevron.animate().rotation(if (open) 90f else 0f).setDuration(UiKit.motionMs(context, DesignTokens.MOTION_FAST)).start()
                contentDescription = if (open) "Details, expanded" else "Details, collapsed"
            }
        }
        colB.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = UiKit.card(context, DesignTokens.R_16)
            clipToOutline = true
            addView(detailsHeader)
            addView(detailsBody)
        }, lp(DesignTokens.SP_12))

        // ---- Layout ----
        val body = LinearLayout(this).apply {
            orientation = if (landscape) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
            if (landscape) {
                addView(colA, LinearLayout.LayoutParams(0, wrap, 1f).apply { rightMargin = dp(DesignTokens.SP_24) })
                addView(colB, LinearLayout.LayoutParams(0, wrap, 1f))
            } else {
                addView(colA, LinearLayout.LayoutParams(match, wrap))
                addView(colB, LinearLayout.LayoutParams(match, wrap))
            }
        }

        val newScan = UiKit.bigButton(this, "New scan").apply {
            setPadding(dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12))
            setOnClickListener { startActivity(Intent(this@ReviewActivity, CaptureActivity::class.java)); finish() }
        }
        val home = UiKit.secondaryButton(this, "Done").apply {
            setPadding(dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12))
            setOnClickListener { finish() }
        }
        val scans = UiKit.secondaryButton(this, "My scans").apply {
            setPadding(dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12))
            contentDescription = "Open My scans"
            setOnClickListener { startActivity(Intent(this@ReviewActivity, ScansActivity::class.java)); finish() }
        }

        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(UiKit.topBar(context, "Scan review", onBack = { finish() }), LinearLayout.LayoutParams(match, wrap).apply { bottomMargin = dp(DesignTokens.SP_8) })
                addView(body, LinearLayout.LayoutParams(match, wrap))
            }, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            UiKit.applyInsetsAboveBar(this, DesignTokens.SP_16)
        }
        setContentView(UiKit.stickyPage(this, scroll, UiKit.bottomActionBar(this, scans, home, newScan)))
        UiKit.slideUp(body, 16)
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(bottom) }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) UiKit.immersive(this)
    }

    companion object {
        const val EXTRA_DIR = "dir"
        const val EXTRA_STATUS = "status"
        const val EXTRA_ELAPSED_MS = "elapsed_ms"
        const val EXTRA_KEYFRAMES = "keyframes"
        /** Last overlay snapshot's objects / openings (overlay string formats) for the "Found" row. */
        const val EXTRA_OBJECTS = "room_objects"
        const val EXTRA_OPENINGS = "room_openings"
        /** True when the scan lifted detections to objects (detector + understanding on): "No objects recognised" is then meaningful. */
        const val EXTRA_OBJECTS_EXPECTED = "room_objects_expected"

        /** ReviewSummary JSON (contract C3) -> (completeness %, up to 5 weak-zone texts); null when absent or unreadable. */
        fun parseSummary(json: String?): Pair<Int, List<String>>? = try {
            if (json.isNullOrEmpty()) null else {
                val o = org.json.JSONObject(json)
                val zones = o.optJSONArray("weak_zones")
                val texts = ArrayList<String>()
                if (zones != null) for (i in 0 until minOf(zones.length(), 5)) zones.optJSONObject(i)?.optString("text", "")?.takeIf { it.isNotEmpty() }?.let { texts.add(it) }
                o.getInt("completeness_pct") to texts
            }
        } catch (t: Throwable) { null }

        /** manifest.json: validation.verdict, counts.keyframes and WARN/ERROR messages from validation.issues (INFO hidden). */
        fun parseManifest(text: String): Parsed = try {
            val root = org.json.JSONObject(text)
            val validation = root.optJSONObject("validation")
            val verdict = validation?.optString("verdict", "")?.takeIf { it == "PASS" || it == "WARN" || it == "FAIL" }
            val kf = root.optJSONObject("counts")?.let { if (it.has("keyframes")) it.optInt("keyframes", -1).takeIf { n -> n >= 0 } else null }
            val arr = validation?.optJSONArray("issues")
            val issues = ArrayList<String>()
            if (arr != null) for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val sev = o.optString("severity", "")
                val msg = o.optString("message", "")
                if ((sev == "WARN" || sev == "ERROR") && msg.isNotEmpty()) issues.add(msg)
            }
            val clock = root.optJSONObject("clock")
            val dur = if (clock != null && clock.has("t_start_ns") && clock.has("t_end_ns"))
                ((clock.optLong("t_end_ns") - clock.optLong("t_start_ns")) / 1_000_000L).takeIf { it > 0 } else null
            Parsed(verdict, kf, issues, dur)
        } catch (t: Throwable) { Parsed(null, null, emptyList()) }   // missing/corrupt manifest: show "not available"
    }
}
