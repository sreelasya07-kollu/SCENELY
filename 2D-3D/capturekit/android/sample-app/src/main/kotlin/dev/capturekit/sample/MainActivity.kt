package dev.capturekit.sample

import android.app.Activity
import android.app.ActivityManager
import android.app.AlertDialog
import android.app.ApplicationExitInfo
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import com.google.ar.core.ArCoreApk
import dev.capturekit.capture.SessionManager
import dev.capturekit.consent.ConsentStore
import dev.capturekit.nativebridge.Status
import dev.capturekit.upload.UploadPlan
import dev.capturekit.verdict.ScanInfo
import java.io.File

/** CaptureKit entry point: onboarding, scan readiness, and links to the user's scans. */
class MainActivity : Activity() {
    private var home = false
    private val ui = Handler(Looper.getMainLooper())
    private val prefs by lazy { getSharedPreferences("ck_prefs", MODE_PRIVATE) }
    private val consent by lazy { ConsentStore.get(this) }

    // Dynamic UI elements
    private var readyBadge: TextView? = null
    private var permCard: LinearLayout? = null
    private var arCard: LinearLayout? = null
    private var arCardText: TextView? = null
    private var arCardBtn: Button? = null
    private var recoveryCard: LinearLayout? = null
    private var recoveryText: TextView? = null
    private var consentSummaryText: TextView? = null
    private var voiceSwitch: Switch? = null
    @Volatile private var recoveryNote: String? = null
    private var recentSection: LinearLayout? = null
    private var recentGen = 0

    private class Recent(val dir: File, val timeMs: Long, val verdict: String?, val thumb: android.graphics.Bitmap?)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setBackgroundColor(UiKit.BG)
        Features.prefetch(this)   // ADR 0032: debug-build switches read off the main thread before the capture screen
        if (prefs.getBoolean(KEY_ONBOARDED, false)) showHome() else showOnboarding(0)
        if (savedInstanceState == null) checkLastExit()
    }

    private fun checkLastExit() {
        Thread {
            val reason = lastExitReason()
            getExternalFilesDir("bundles")?.let { dev.capturekit.upload.BundleArchive.cleanTmp(it) }   // a zip pack the process was killed in (ADR 0040)
            val recovered = try { SessionManager.recoverInterrupted(this) } catch (t: Throwable) { Log.w(TAG, "recovery failed", t); emptyList() }
            if (reason != null) Log.i(TAG, "last process exit: $reason; recovered ${recovered.size} scan(s)")
            if (recovered.isEmpty()) return@Thread
            runOnUiThread {
                recoveryNote = "Your last scan ended unexpectedly. It was recovered and saved."
                paintRecovery()
            }
        }.start()
    }

    private fun lastExitReason(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            val am = getSystemService(ActivityManager::class.java) ?: return null
            val info = am.getHistoricalProcessExitReasons(packageName, 0, 1).firstOrNull() ?: return null
            if (info.timestamp <= prefs.getLong(KEY_EXIT_TS, 0L)) return null
            val text = "${exitName(info.reason)} status=${info.status} (${info.description ?: "-"})"
            prefs.edit().putLong(KEY_EXIT_TS, info.timestamp).putString(KEY_EXIT_REASON, text).apply()
            text
        } catch (t: Throwable) { Log.w(TAG, "exit reasons unavailable", t); null }
    }

    private fun exitName(r: Int) = when (r) {
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        else -> "REASON_$r"
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun lp(bottom: Int = 12) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        .apply { bottomMargin = dp(bottom) }
    private val wrap = ViewGroup.LayoutParams.WRAP_CONTENT

    private fun setScreen(root: View) {
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            addView(root)
            UiKit.applyInsets(this, 20)
        }
        setContentView(UiKit.page(this, scroll))
    }

    // ---- onboarding (3 pages) ----
    private var lastOnbPage = 0

    private fun showOnboarding(page: Int) {
        home = false
        readyBadge = null; permCard = null; arCard = null; recoveryCard = null; recentSection = null
        val last = 2
        val (title, lines) = when (page) {
            0 -> "Scan a room in 3D" to listOf(
                "CaptureKit guides you around the room, tracks what you have covered, and tells you what to revisit.",
                "Press Start and move smoothly.\nFollow the spoken and on-screen cues.\nFinish and review your scan.")
            1 -> "Camera and motion" to listOf(
                "The camera maps the room and tracks your movement. Your scan stays on this phone unless you choose to upload it.",
                "Motion sensors keep tracking stable. Uploads and anonymous telemetry are optional and off by default.")
            else -> "Before you start" to listOf(
                "Use good light.\nWalk slowly and keep the phone steady.\nTurn the volume up for spoken guidance.\nClose doors and keep people out of view.")
        }
        val illustration = when (page) { 0 -> R.drawable.ill_scan; 1 -> R.drawable.ill_privacy; else -> R.drawable.ill_tips }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        // Skip jumps to the last page, so the camera permission step is never bypassed.
        root.addView(LinearLayout(this).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
            if (page < last) addView(UiKit.textButton(this@MainActivity, "Skip").apply { setOnClickListener { showOnboarding(last) } })
        }, lp(0))
        root.addView(View(this), LinearLayout.LayoutParams(1, 0, 1f))
        val art = ImageView(this).apply {
            setImageResource(illustration)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        root.addView(art, LinearLayout.LayoutParams(dp(176), dp(176)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(DesignTokens.SP_24) })
        val heading = UiKit.role(this, title, DesignTokens.HEADLINE_MEDIUM).apply {
            gravity = Gravity.CENTER
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }
        root.addView(heading, lp(12))
        for (l in lines) root.addView(UiKit.role(this, l, DesignTokens.BODY_LARGE, if (l == lines.first()) UiKit.LABEL_2 else UiKit.LABEL).apply { gravity = Gravity.CENTER }, lp(14))
        root.addView(View(this), LinearLayout.LayoutParams(1, 0, 1f))

        // Page dots: the selected one widens and takes the accent.
        val dots = PageDots(this, last + 1).apply { contentDescription = "Step ${page + 1} of ${last + 1}" }
        dots.select(lastOnbPage, animate = false)
        dots.post { dots.select(page) }
        lastOnbPage = page
        root.addView(dots, lp(8))

        val next = UiKit.bigButton(this, if (page == last) (if (CameraPermission.granted(this)) "Continue" else "Allow camera and continue") else "Continue").apply {
            setOnClickListener {
                UiKit.haptic(this, false)
                if (page < last) showOnboarding(page + 1)
                else if (CameraPermission.granted(this@MainActivity)) finishOnboarding()
                else CameraPermission.request(this@MainActivity)
            }
        }
        val bar = if (page > 0) UiKit.bottomActionBar(this, UiKit.secondaryButton(this, "Back").apply { setOnClickListener { showOnboarding(page - 1) } }, next)
        else UiKit.bottomActionBar(this, next)
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            clipToPadding = false
            addView(root)
            UiKit.applyInsetsAboveBar(this, 20)
        }
        setContentView(UiKit.stickyPage(this, scroll, bar))
        UiKit.slideUp(art, 16)
        UiKit.fadeIn(heading)
    }

    private fun finishOnboarding() {
        prefs.edit().putBoolean(KEY_ONBOARDED, true).apply()
        showHome()
        if (!consent.hasConsent()) startActivity(Intent(this, ConsentActivity::class.java))
    }

    private fun openScans() = startActivity(Intent(this, ScansActivity::class.java))

    /** A status-tinted card with an icon + title line, body text and an optional action. Hidden until needed. */
    private fun alertCard(kind: UiKit.Kind, title: String, bodyOut: (TextView) -> Unit, action: Button?): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val container = when (kind) {
                UiKit.Kind.OK -> DesignTokens.SUCCESS_CONTAINER
                UiKit.Kind.WARN -> DesignTokens.WARNING_CONTAINER
                UiKit.Kind.ERROR -> DesignTokens.ERROR_CONTAINER
                UiKit.Kind.INFO -> UiKit.SURFACE_2
            }
            background = UiKit.rounded(container, dp(DesignTokens.R_16).toFloat(), UiKit.withAlpha(kind.color, 0x40), 1)
            setPadding(dp(16), dp(16), dp(16), dp(16))
            visibility = View.GONE
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(UiKit.iconImage(this@MainActivity, if (kind == UiKit.Kind.OK) R.drawable.ic_check else R.drawable.ic_warning, kind.color),
                    LinearLayout.LayoutParams(dp(20), dp(20)).apply { rightMargin = dp(10) })
                addView(UiKit.role(this@MainActivity, title, DesignTokens.TITLE_MEDIUM, kind.color))
            }, lp(6))
            addView(UiKit.role(this@MainActivity, "", DesignTokens.BODY_MEDIUM, UiKit.LABEL_2).also(bodyOut), lp(if (action != null) 14 else 0))
            if (action != null) addView(action)
        }

    // ---- Home ----
    private fun showHome() {
        home = true
        val version = try { packageManager.getPackageInfo(packageName, 0).versionName } catch (t: Throwable) { "1.0" }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        // 1. Top bar: wordmark and settings.
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(56)
            addView(UiKit.iconTile(this@MainActivity, R.drawable.ic_cube), LinearLayout.LayoutParams(dp(36), dp(36)).apply { rightMargin = dp(12) })
            addView(UiKit.role(this@MainActivity, "CaptureKit", DesignTokens.TITLE_LARGE).apply {
                if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            }, LinearLayout.LayoutParams(0, wrap, 1f))
            addView(UiKit.iconButton(this@MainActivity, R.drawable.ic_settings, "Settings").apply {
                setOnClickListener { startActivity(Intent(this@MainActivity, SettingsActivity::class.java)) }
            })
        }, lp(8))

        // 2. Readiness chip.
        readyBadge = UiKit.chip(this).also { root.addView(it, LinearLayout.LayoutParams(wrap, wrap).apply { bottomMargin = dp(20) }) }

        // 3. Alerts (each hidden unless needed).
        recoveryCard = alertCard(UiKit.Kind.OK, "Scan recovered", { recoveryText = it },
            UiKit.secondaryButton(this, "View scans").apply { setOnClickListener { openScans() } }).also { root.addView(it, lp(12)) }
        paintRecovery()
        permCard = alertCard(UiKit.Kind.ERROR, "Camera access needed",
            { it.text = "CaptureKit uses the camera to see the room and track your movement." },
            UiKit.bigButton(this, "Allow camera").apply { setOnClickListener { CameraPermission.retry(this@MainActivity) } })
            .also { root.addView(it, lp(12)) }
        arCardBtn = UiKit.bigButton(this, "Check again").apply { setOnClickListener { refresh() } }
        arCard = alertCard(UiKit.Kind.WARN, "Google Play Services for AR needed", { arCardText = it }, arCardBtn)
            .also { root.addView(it, lp(12)) }

        // 4. Hero: one clear action.
        val hero = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = UiKit.rounded(UiKit.ACCENT_CONTAINER, dp(DesignTokens.R_28).toFloat())
            setPadding(dp(24), dp(24), dp(24), dp(24))
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(UiKit.role(this@MainActivity, "New scan", DesignTokens.HEADLINE_SMALL, UiKit.ON_ACCENT_CONTAINER), lp(8))
                    addView(UiKit.role(this@MainActivity, "Walk slowly around the room. CaptureKit tracks what you have covered and tells you what is missing.",
                        DesignTokens.BODY_MEDIUM, UiKit.ON_ACCENT_CONTAINER))
                }, LinearLayout.LayoutParams(0, wrap, 1f))
                addView(ImageView(this@MainActivity).apply {
                    setImageResource(R.drawable.ill_scan)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, LinearLayout.LayoutParams(dp(88), dp(88)).apply { leftMargin = dp(12) })
            }, lp(20))
            addView(UiKit.bigButton(this@MainActivity, "Start scan").apply {
                setOnClickListener {
                    UiKit.haptic(this, true)
                    if (!CameraPermission.granted(this@MainActivity)) {
                        CameraPermission.request(this@MainActivity)
                    } else if (!consent.hasConsent()) {
                        startActivity(Intent(this@MainActivity, ConsentActivity::class.java).putExtra(ConsentActivity.EXTRA_START_SCAN, true))
                    } else {
                        startActivity(Intent(this@MainActivity, CaptureActivity::class.java))
                    }
                }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, wrap))
        }
        root.addView(hero, lp(28))
        UiKit.slideUp(hero, 16)

        // 5. Recent scans strip (hidden until a scan exists; filled off the main thread).
        recentSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
        }.also { root.addView(it, lp(20)) }

        // 6. Library
        root.addView(UiKit.sectionHeader(this, "Library"))
        val voice = UiKit.toggle(this, SpeechRenderer.savedEnabled(this)).apply {
            contentDescription = "Voice guidance"
            setOnCheckedChangeListener { _, on -> SpeechRenderer.saveEnabled(this@MainActivity, on) }
        }
        voiceSwitch = voice
        root.addView(UiKit.group(this).apply {
            addView(UiKit.listRow(this@MainActivity, R.drawable.ic_scans, "My scans", "Saved rooms and their check results") { openScans() })
            addView(UiKit.listRow(this@MainActivity, R.drawable.ic_mic, "Voice guidance", "Spoken coaching while you scan", trailing = voice).apply {
                isClickable = true; foreground = UiKit.rowRipple(); setOnClickListener { voice.toggle() }
            })
            addView(UiKit.listRow(this@MainActivity, R.drawable.ic_settings, "Settings", "Object boxes, motion sensors, prompts, voice commands") {
                startActivity(Intent(this@MainActivity, SettingsActivity::class.java))
            })
        }, lp(28))

        // 7. Privacy
        root.addView(UiKit.sectionHeader(this, "Privacy"))
        root.addView(UiKit.group(this).apply {
            addView(UiKit.listRow(this@MainActivity, R.drawable.ic_lock, "Stored on this phone", "").also { row ->
                val column = (0 until row.childCount).map { row.getChildAt(it) }.filterIsInstance<LinearLayout>().first()
                consentSummaryText = column.getChildAt(1) as TextView
            })
            addView(UiKit.listRow(this@MainActivity, R.drawable.ic_warning, "Withdraw consent", titleColor = UiKit.RED, chevron = false) { confirmRevoke() })
        }, lp(28))

        // 8. Developer tools: debuggable builds only.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            root.addView(UiKit.sectionHeader(this, "Developer"))
            root.addView(UiKit.group(this).apply {
                addView(UiKit.listRow(this@MainActivity, R.drawable.ic_cube, "Sensor recorder", "Raw camera and IMU capture") {
                    startActivity(Intent(this@MainActivity, RecorderActivity::class.java))
                })
                addView(UiKit.listRow(this@MainActivity, R.drawable.ic_timer, "Clock check", "Camera and sensor timestamp offsets") {
                    startActivity(Intent(this@MainActivity, ClockCheckActivity::class.java))
                })
            }, lp(20))
        }

        root.addView(UiKit.caption(this, "Version $version").apply { gravity = Gravity.CENTER }, lp(8))

        setScreen(root)
        refresh()
        loadRecent()
    }

    /** Newest five scans with their thumbnail and verdict, read on a worker thread (same sources as "My scans"). */
    private fun loadRecent() {
        if (!home) return
        val gen = ++recentGen
        Thread {
            val items = try {
                val root = getExternalFilesDir("bundles")
                val dirs = root?.let { dev.capturekit.upload.BundleArchive.list(it) } ?: emptyList()   // folders and scan_*.zip (ADR 0040)
                dirs.map { it to ScanInfo.timeMs(dev.capturekit.upload.BundleArchive.dirOf(it).name, it.lastModified()) }.sortedByDescending { it.second }.take(5).map { (d, t) ->
                    val manifest = try { dev.capturekit.upload.BundleArchive.manifestText(d) } catch (e: Throwable) { "" }
                    Recent(d, t, ReviewActivity.parseManifest(manifest).verdict, ScanThumbnails.load(d))
                }
            } catch (t: Throwable) { Log.w(TAG, "recent scans unavailable", t); emptyList() }
            runOnUiThread { if (!isDestroyed && home && gen == recentGen) paintRecent(items) }
        }.start()
    }

    private fun paintRecent(items: List<Recent>) {
        val section = recentSection ?: return
        section.removeAllViews()
        if (items.isEmpty()) { section.visibility = View.GONE; return }
        section.visibility = View.VISIBLE
        section.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(UiKit.sectionHeader(this@MainActivity, "Recent scans").apply { setPadding(dp(16), 0, dp(16), 0) },
                LinearLayout.LayoutParams(0, wrap, 1f))
            addView(UiKit.textButton(this@MainActivity, "See all", UiKit.ACCENT).apply { setOnClickListener { openScans() } })
        }, lp(4))
        val strip = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        for (r in items) {
            strip.addView(recentCard(r), LinearLayout.LayoutParams(dp(148), wrap).apply { rightMargin = dp(DesignTokens.SP_12) })
        }
        section.addView(HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(strip)
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, wrap))
        UiKit.fadeIn(section)
    }

    private fun recentCard(r: Recent): LinearLayout {
        val dateText = android.text.format.DateUtils.getRelativeTimeSpanString(
            r.timeMs, System.currentTimeMillis(), android.text.format.DateUtils.DAY_IN_MILLIS,
            android.text.format.DateUtils.FORMAT_ABBREV_RELATIVE).toString()
        val badge = ScanInfo.badgeText(r.verdict)
        val tint = if (r.verdict == "PASS" || r.verdict == "WARN" || r.verdict == "FAIL") ScanUi.verdictColor(r.verdict) else UiKit.LABEL_2
        val thumb = FrameLayout(this).apply {
            background = UiKit.rounded(UiKit.SURFACE_2, dp(DesignTokens.R_16).toFloat())
            clipToOutline = true
            if (r.thumb != null) {
                addView(ImageView(this@MainActivity).apply {
                    setImageBitmap(r.thumb)
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            } else {
                addView(UiKit.iconImage(this@MainActivity, R.drawable.ic_scans, UiKit.LABEL_3),
                    FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER))
            }
            // Own badge: a dark scrim keeps the verdict legible over any photo (pillBadge is a faint fill).
            addView(UiKit.role(this@MainActivity, badge, DesignTokens.LABEL_MEDIUM, tint).apply {
                background = UiKit.rounded(0xCC0B0D0E.toInt(), dp(DesignTokens.R_PILL).toFloat())
                setPadding(dp(10), dp(4), dp(10), dp(4))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, FrameLayout.LayoutParams(wrap, wrap, Gravity.START or Gravity.TOP).apply { setMargins(dp(8), dp(8), 0, 0) })
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            isClickable = true; isFocusable = true
            contentDescription = "Scan $dateText, $badge. Open review."
            foreground = UiKit.rowRipple()
            addView(thumb, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(111)))
            addView(UiKit.role(this@MainActivity, dateText, DesignTokens.LABEL_MEDIUM, UiKit.LABEL_2).apply {
                maxLines = 1
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(DesignTokens.SP_8) })
            setOnClickListener {
                startActivity(Intent(this@MainActivity, ReviewActivity::class.java)
                    .putExtra(ReviewActivity.EXTRA_DIR, r.dir.absolutePath).putExtra(ReviewActivity.EXTRA_STATUS, Status.OK))
            }
        }
    }

    private fun paintVoice() {
        val on = SpeechRenderer.savedEnabled(this)
        voiceSwitch?.let { if (it.isChecked != on) it.isChecked = on }
    }

    private fun paintRecovery() {
        val c = recoveryCard ?: return
        val n = recoveryNote
        c.visibility = if (n == null) View.GONE else View.VISIBLE
        if (n != null) recoveryText?.text = n
    }

    private fun paintConsent() {
        Telemetry.sync(this)
        val c = consent.current()
        consentSummaryText?.text = if (c == null) {
            "Consent not given yet. It is needed before scanning."
        } else {
            "Upload ${if (c.upload) "on" else "off"}  ·  Anonymous telemetry ${if (c.telemetry) "on" else "off"}"
        }
    }

    private fun confirmRevoke() {
        AlertDialog.Builder(this, R.style.AppDialog)
            .setTitle("Withdraw consent?")
            .setMessage("Scanning will be blocked until you accept again. Uploading and anonymous telemetry stop, and recorded choices are removed from this phone. Your saved scans stay on the phone.")
            .setPositiveButton("Withdraw") { _, _ ->
                consent.revoke()
                dev.capturekit.upload.UploadWorker.cancelAll(this)
                paintConsent()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun refresh() {
        if (!home) return
        paintConsent()
        paintVoice()
        val ok = CameraPermission.granted(this)
        permCard?.visibility = if (ok) View.GONE else View.VISIBLE

        val av = try { ArCoreApk.getInstance().checkAvailability(this) } catch (t: Throwable) { null }
        val (readyText, isSupported) = when {
            av == null -> "AR status unknown" to false
            av.isTransient -> "Checking AR..." to false
            av == ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED -> "Install Google Play Services for AR" to false
            av == ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD -> "Update Google Play Services for AR" to false
            av.isSupported -> "Ready to scan" to true
            else -> "This phone does not support AR" to false
        }

        if (isSupported) {
            arCard?.visibility = View.GONE
        } else {
            arCard?.visibility = View.VISIBLE
            arCardText?.text = "$readyText. CaptureKit needs it to track the phone's position in the room."
        }

        readyBadge?.let {
            when {
                ok && isSupported -> UiKit.setChip(it, "Ready to scan", UiKit.GREEN)
                !ok -> UiKit.setChip(it, "Camera access needed", UiKit.RED)
                else -> UiKit.setChip(it, readyText, UiKit.AMBER)
            }
        }

        if (av?.isTransient == true) ui.postDelayed({ refresh() }, 500)
    }

    override fun onResume() { super.onResume(); refresh(); loadRecent() }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) UiKit.immersive(this)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        CameraPermission.onResult(this, grantResults)
        if (!home) finishOnboarding() else refresh()
    }

    override fun onPause() { ui.removeCallbacksAndMessages(null); super.onPause() }

    private companion object {
        const val KEY_ONBOARDED = "onboarded"
        const val KEY_EXIT_TS = "last_exit_ts"
        const val KEY_EXIT_REASON = "last_exit_reason"
        const val TAG = "CKMain"
    }
}
