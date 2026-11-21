package dev.capturekit.sample

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Bitmap
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import dev.capturekit.capture.ResearchReport
import dev.capturekit.consent.ConsentStore
import dev.capturekit.nativebridge.Status
import dev.capturekit.sample.results.ResultsGate
import dev.capturekit.sample.upload.UploadGate
import dev.capturekit.upload.BundleArchive
import dev.capturekit.upload.UploadPlan
import dev.capturekit.upload.UploadPolicy
import dev.capturekit.upload.UploadSettings
import dev.capturekit.upload.UploadState
import dev.capturekit.upload.UploadStatus
import dev.capturekit.upload.UploadWorker
import dev.capturekit.verdict.ScanInfo
import java.io.File
import java.util.Calendar
import java.util.Date

/**
 * "My scans": every bundle on this phone, newest first, as a grid of thumbnail cards (2 columns portrait, 3 landscape)
 * with date, room label (field trials), the validator verdict as a badge with words over the thumbnail, and (field
 * flavour only) the upload state with progress, Upload / Retry actions and the "Wi-Fi only" switch. All disk and
 * WorkManager reads run on a worker thread; the list refreshes every 2 s while an upload is active. The standard
 * flavour has no INTERNET permission, so it shows no upload UI at all.
 */
class ScansActivity : Activity() {
    private data class Row(val dir: File, val timeMs: Long, val room: String?, val verdict: String?, val size: Long, val upload: UploadStatus, val thumb: Bitmap?, val bundleId: String? = null, val verified: Boolean = false)

    private lateinit var list: LinearLayout
    private var wifiOnly = true
    private var generation = 0
    @Volatile private var visible = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        wifiOnly = UploadSettings.unmeteredOnly(this)
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(UiKit.topBar(this, "My scans", onBack = { finish() }), lp(DesignTokens.SP_8))
        if (UploadGate.available) root.addView(settingsPanel(), lp(DesignTokens.SP_16))
        root.addView(ScrollView(this).apply { isFillViewport = true; isVerticalScrollBarEnabled = false; addView(list) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        UiKit.applyInsets(root, DesignTokens.SP_16)
        setContentView(UiKit.page(this, root))
        showLoading()
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

    /** Re-reads everything on a worker thread; keeps polling every 2 s while any upload is active and the screen is visible. */
    private fun startLoop() {
        val gen = ++generation
        Thread {
            while (visible && gen == generation) {
                val rows = loadRows()
                runOnUiThread { if (!isDestroyed && gen == generation) render(rows) }
                val active = rows.any { it.upload.state == UploadState.WAITING || it.upload.state == UploadState.UPLOADING || it.upload.state == UploadState.RETRYING }
                if (!active) break
                try { Thread.sleep(2000) } catch (e: InterruptedException) { break }
            }
        }.start()
    }

    private fun loadRows(): List<Row> {
        val root = getExternalFilesDir("bundles") ?: return emptyList()
        val dirs = BundleArchive.list(root)   // folders and scan_*.zip; the folder wins if both exist (ADR 0040)
        val uploads = UploadGate.available
        return dirs.map { d ->
            val manifest = try { BundleArchive.manifestText(d) } catch (t: Throwable) { "" }
            val research = try { ResearchReport.fileFor(d).takeIf { it.exists() }?.readText() } catch (t: Throwable) { null }
            val upload = if (uploads) UploadWorker.status(applicationContext, d) else UploadStatus(UploadState.NONE)
            Row(d, ScanInfo.timeMs(BundleArchive.dirOf(d).name, d.lastModified()), ScanInfo.roomLabel(research), ReviewActivity.parseManifest(manifest).verdict,
                try { BundleArchive.sizeBytes(d) } catch (t: Throwable) { 0L },
                upload, thumbFor(d), UploadPlan.bundleId(manifest),
                uploads && (upload.state == UploadState.VERIFIED || UploadPolicy.verifiedMarker(d).exists()))
        }.sortedByDescending { it.timeMs }
    }

    /** Middle keyframe, decoded small once per scan (worker thread); shared with Home via [ScanThumbnails]. */
    private fun thumbFor(d: File): Bitmap? = ScanThumbnails.load(d)

    /** "Today, 12:07", "Yesterday, 21:58", "17 Nov, 21:35", "17 Nov 2025" (phone's own time format). */
    private fun friendlyDate(ms: Long): String {
        val now = Calendar.getInstance(); val c = Calendar.getInstance().apply { timeInMillis = ms }
        val time = android.text.format.DateFormat.getTimeFormat(this).format(Date(ms))
        val days = (startOfDay(now) - startOfDay(c)) / 86_400_000L
        return when {
            days == 0L -> "Today, $time"
            days == 1L -> "Yesterday, $time"
            now.get(Calendar.YEAR) == c.get(Calendar.YEAR) -> android.text.format.DateFormat.format("d MMM", c).toString() + ", $time"
            else -> android.text.format.DateFormat.format("d MMM yyyy", c).toString()
        }
    }

    private fun startOfDay(c: Calendar) = (c.clone() as Calendar).apply {
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.timeInMillis

    private val columns: Int
        get() = if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) 3 else 2

    /** Skeleton grid while the first read runs on the worker thread. */
    private fun showLoading() {
        list.removeAllViews()
        val cols = columns
        for (r in 0 until 2) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (c in 0 until cols) row.addView(UiKit.skeleton(this, 0, 168, DesignTokens.R_16),
                LinearLayout.LayoutParams(0, dp(168), 1f).apply { if (c > 0) leftMargin = dp(DesignTokens.SP_12) })
            list.addView(row, lp(DesignTokens.SP_12))
        }
        list.contentDescription = "Loading your scans"
    }

    private fun render(rows: List<Row>) {
        list.removeAllViews()
        list.contentDescription = null
        if (rows.isEmpty()) { renderEmpty(); return }
        val consentUpload = UploadGate.available && ConsentStore.get(this).uploadAllowed()
        if (UploadGate.available && !consentUpload) {
            list.addView(UiKit.banner(this, "Uploading is off. You did not allow uploads in the consent screen.", UiKit.Kind.WARN), lp(DesignTokens.SP_12))
        }
        list.addView(UiKit.sectionHeader(this, if (rows.size == 1) "1 scan" else "${rows.size} scans"))
        val cols = columns
        for (chunk in rows.chunked(cols)) {
            val line = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (i in 0 until cols) {
                val r = chunk.getOrNull(i)
                val lpItem = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { if (i > 0) leftMargin = dp(DesignTokens.SP_12) }
                if (r != null) line.addView(card(r, friendlyDate(r.timeMs), consentUpload), lpItem)
                else line.addView(View(this), lpItem)
            }
            list.addView(line, lp(DesignTokens.SP_12))
        }
    }

    private fun renderEmpty() {
        list.addView(UiKit.emptyState(this, R.drawable.ic_scans, "No scans yet", "Scan a room and it will show up here with its check result.", "Start a scan") {
            startActivity(Intent(this@ScansActivity, CaptureActivity::class.java)); finish()
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(DesignTokens.SP_32) })
    }

    private fun card(r: Row, date: String, consentUpload: Boolean): View {
        // 4:3 thumbnail with the check result overlaid; a camera glyph stands in when the bundle has no keyframes.
        val thumb = AspectFrame(this, 3f / 4f).apply {
            setBackgroundColor(UiKit.SURFACE_3)
            if (r.thumb != null) addView(ImageView(context).apply { setImageBitmap(r.thumb); scaleType = ImageView.ScaleType.CENTER_CROP; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO },
                FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            else addView(UiKit.iconImage(context, R.drawable.ic_camera, UiKit.LABEL_3), FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER))
            addView(UiKit.role(context, UiKit.dotted(ScanInfo.badgeText(r.verdict), ScanUi.verdictColor(r.verdict)), DesignTokens.LABEL_MEDIUM).apply {
                background = UiKit.rounded(0xCC0B0D0E.toInt(), dp(DesignTokens.R_PILL).toFloat())
                setPadding(dp(10), dp(4), dp(10), dp(4))
            }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP or Gravity.START).apply { setMargins(dp(8), dp(8), dp(8), 0) })
        }
        val info = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12), dp(DesignTokens.SP_12))
            addView(UiKit.role(context, r.room ?: date, DesignTokens.TITLE_SMALL).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END })
            addView(UiKit.role(context, if (r.room != null) "$date  ·  ${UiKit.humanSize(r.size)}" else UiKit.humanSize(r.size), DesignTokens.BODY_SMALL, UiKit.LABEL_3).apply {
                maxLines = 1; ellipsize = TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(2) })
        }
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = UiKit.card(context, DesignTokens.R_16)
            clipToOutline = true
            foreground = UiKit.rowRipple()
            addView(thumb, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(info, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        var spoken = "Scan $date${r.room?.let { ", $it" } ?: ""}. Check: ${ScanInfo.badgeText(r.verdict)}."
        val topGap = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(DesignTokens.SP_8) }
        if (UploadGate.available) {
            val chip = UiKit.chip(this).also { ScanUi.paintUpload(it, r.upload, wifiOnly) }.apply {
                textSize = DesignTokens.LABEL_MEDIUM.sizeSp
                setPadding(dp(10), dp(5), dp(10), dp(5))
            }
            info.addView(chip, topGap)
            if (r.upload.state == UploadState.UPLOADING) info.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                max = 100; progress = r.upload.percent.coerceIn(0, 100)
                progressTintList = ColorStateList.valueOf(UiKit.ACCENT)
                progressBackgroundTintList = ColorStateList.valueOf(DesignTokens.OUTLINE)
                contentDescription = "Upload progress ${r.upload.percent} percent"
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(6)).apply { topMargin = dp(DesignTokens.SP_8) })
            spoken += " ${ScanUi.uploadText(r.upload, wifiOnly).replace("%", " percent")}."
            val canUpload = consentUpload && UploadPolicy.eligible(true, r.verdict)
            val action = when {
                canUpload && r.upload.state == UploadState.NONE -> "Upload"
                canUpload && r.upload.state == UploadState.FAILED -> "Retry upload"
                else -> null
            }
            if (action != null) info.addView(UiKit.secondaryButton(this, action).apply {
                contentDescription = "$action for the scan from $date"
                setOnClickListener { UiKit.haptic(this, true); isEnabled = false; queue(r.dir, r.verdict, replace = false) }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(DesignTokens.SP_12) })
            else if (r.verdict != "PASS" && r.verdict != "WARN" && r.upload.state == UploadState.NONE) info.addView(
                UiKit.role(this, if (r.verdict == "FAIL") "A failed scan is never uploaded." else "Not finalized: this scan cannot be uploaded.", DesignTokens.BODY_SMALL, UiKit.LABEL_3), topGap)
        }
        // Results of the server run: only for a scan the server has verified, and only when this build has a job server.
        if (ResultsGate.available && r.verified && r.bundleId != null) {
            info.addView(UiKit.secondaryButton(this, "View results").apply {
                contentDescription = "View the server results for the scan from $date"
                setOnClickListener { startActivity(Intent(this@ScansActivity, ResultsActivity::class.java).putExtra(ResultsActivity.EXTRA_BUNDLE_ID, r.bundleId)) }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(DesignTokens.SP_12) })
        }
        col.isClickable = true
        col.isFocusable = true
        col.contentDescription = spoken + " Double tap for details."
        col.setOnClickListener {
            startActivity(Intent(this, ReviewActivity::class.java).putExtra(ReviewActivity.EXTRA_DIR, r.dir.absolutePath).putExtra(ReviewActivity.EXTRA_STATUS, Status.OK))
        }
        return col
    }

    private fun queue(dir: File, verdict: String?, replace: Boolean) {
        Thread {
            try { UploadGate.enqueueIfAllowed(applicationContext, dir, verdict, replace) } catch (t: Throwable) { }
            runOnUiThread { if (!isDestroyed) startLoop() }
        }.start()
    }

    private fun settingsPanel(): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = UiKit.card(context, DesignTokens.R_16)
        setPadding(dp(DesignTokens.SP_16), dp(DesignTokens.SP_8), dp(DesignTokens.SP_16), dp(DesignTokens.SP_12))
        addView(UiKit.toggle(context, wifiOnly).apply {
            text = "Upload on Wi-Fi only"; textSize = DesignTokens.TITLE_MEDIUM.sizeSp; setTextColor(UiKit.LABEL); typeface = UiKit.MEDIUM
            minHeight = dp(DesignTokens.TOUCH_TARGET)
            contentDescription = "Upload on Wi-Fi only. Turn off to also upload on mobile data."
            setOnCheckedChangeListener { _, on ->
                wifiOnly = on
                Thread {
                    UploadSettings.setUnmeteredOnly(applicationContext, on)
                    // Queued uploads keep the old network rule, so restart the ones that have not finished.
                    for (r in loadRows()) if (r.upload.state == UploadState.WAITING || r.upload.state == UploadState.RETRYING || r.upload.state == UploadState.UPLOADING)
                        try { UploadGate.enqueueIfAllowed(applicationContext, r.dir, r.verdict, replace = true) } catch (t: Throwable) { }
                    runOnUiThread { if (!isDestroyed) startLoop() }
                }.start()
            }
        })
        addView(UiKit.role(context, "Scans are large. Off means mobile data may be used.", DesignTokens.BODY_SMALL, UiKit.LABEL_3))
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(bottom) }
}

/** Frame whose height is [ratio] x its width (thumbnails): fixes the tile size before the bitmap is decoded. */
private class AspectFrame(ctx: Context, private val ratio: Float) : FrameLayout(ctx) {
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        super.onMeasure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec((w * ratio).toInt(), MeasureSpec.EXACTLY))
    }
}
