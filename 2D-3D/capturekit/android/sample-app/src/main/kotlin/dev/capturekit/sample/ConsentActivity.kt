package dev.capturekit.sample

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import dev.capturekit.consent.ConsentStore

/**
 * Consent screen. The text (res/raw/consent_v1.txt, a placeholder pending a legal owner) scrolls; the two
 * optional choices (upload, anonymous telemetry) sit at the end of it and both start off. Accept stays
 * disabled until the user has scrolled to the end. Decline just leaves: no consent, no scanning.
 */
class ConsentActivity : Activity() {
    private lateinit var scroll: ScrollView
    private lateinit var accept: Button
    private lateinit var hint: TextView
    private lateinit var upload: Switch
    private lateinit var telemetry: Switch
    private var reachedEnd = false
    private var accepting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.setBackgroundColor(UiKit.BG)
        val text = resources.openRawResource(
            resources.getIdentifier(ConsentStore.TEXT_RESOURCE, "raw", packageName).also { check(it != 0) { "missing raw/${ConsentStore.TEXT_RESOURCE}" } }).bufferedReader().use { it.readText() }
        val (head, rest) = text.lines().let { it.first() to it.drop(1).joinToString("\n").trim() }

        val content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        content.addView(UiKit.role(this, "Before you scan", DesignTokens.HEADLINE_MEDIUM).apply {
            isFocusable = true
            if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        }, lp(12))
        content.addView(UiKit.banner(this, head.lowercase().replaceFirstChar { it.uppercase() }, UiKit.Kind.WARN), lp(20))

        // Icon-led summary of what the full text below says.
        content.addView(UiKit.sectionHeader(this, "In short"))
        content.addView(UiKit.group(this).apply {
            addView(UiKit.listRow(this@ConsentActivity, R.drawable.ic_camera, "What is recorded", "Camera images, phone motion, phone model and scan time."))
            addView(UiKit.listRow(this@ConsentActivity, R.drawable.ic_lock, "Stays on your phone", "Nothing is uploaded unless you allow it below."))
            addView(UiKit.listRow(this@ConsentActivity, R.drawable.ic_warning, "Private places", "Switch screens off and ask other people to leave the room.", titleColor = UiKit.AMBER))
        }, lp(24))

        content.addView(UiKit.sectionHeader(this, "Full text"))
        content.addView(TextView(this).apply {
            this.text = rest
            textSize = DesignTokens.BODY_LARGE.sizeSp; setTextColor(UiKit.LABEL_2); setLineSpacing(0f, 1.25f)
            background = UiKit.card(this@ConsentActivity, DesignTokens.R_16)
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }, lp(24))

        upload = toggle("Allow uploading my finished scans (optional)")
        telemetry = toggle("Allow anonymous crash and usage reports (optional)")
        content.addView(UiKit.sectionHeader(this, "Optional, both off by default"))
        content.addView(UiKit.group(this).apply {
            addView(toggleRow(R.drawable.ic_download, "Upload my finished scans", "Sent to the team's server only if you allow it", upload))
            addView(toggleRow(R.drawable.ic_info, "Anonymous crash and usage reports", "No images, file names or personal details", telemetry))
        }, lp(24))

        scroll = ScrollView(this).apply {
            isFillViewport = false
            isVerticalScrollBarEnabled = false
            clipToPadding = false
            contentDescription = "Consent text. Scroll to the end to enable the Accept button."
            addView(content)
            UiKit.applyInsetsAboveBar(this, 20)
            setOnScrollChangeListener { _, _, _, _, _ -> checkEnd() }
            viewTreeObserver.addOnGlobalLayoutListener { checkEnd() }   // text shorter than the screen: nothing to scroll
        }

        hint = UiKit.role(this, "", DesignTokens.BODY_SMALL, UiKit.LABEL_3).apply { gravity = Gravity.CENTER }
        accept = UiKit.bigButton(this, "Accept and continue").apply {
            contentDescription = "Accept and continue. Available after you scroll to the end of the consent text."
            setOnClickListener { UiKit.haptic(this, true); onAccept() }
        }
        val decline = UiKit.textButton(this, "Decline").apply {
            contentDescription = "Decline. You will not be able to scan without consent."
            setOnClickListener { setResult(RESULT_CANCELED); finish() }
        }
        val bar = UiKit.bottomActionBar(this, hint, accept, decline, stacked = true)
        setContentView(UiKit.stickyPage(this, scroll, bar))
        UiKit.fadeIn(content)
        paint()
    }

    private fun checkEnd() {
        if (reachedEnd) return
        if (!scroll.canScrollVertically(1) && scroll.getChildAt(0).height > 0) {
            reachedEnd = true
            paint()
            accept.announceForAccessibility("Accept is now available")
        }
    }

    private fun paint() {
        accept.isEnabled = reachedEnd
        UiKit.recolor(accept, if (reachedEnd) UiKit.PRIMARY else UiKit.TONAL)
        if (!reachedEnd) accept.setTextColor(UiKit.LABEL_3)
        hint.text = if (reachedEnd) "You can accept now. Both optional choices are off unless you turned them on."
            else "Scroll down and read to the end to enable Accept."
    }

    private fun onAccept() {
        if (!reachedEnd || accepting) return
        accepting = true
        accept.isEnabled = false
        ConsentStore.get(this).accept(System.currentTimeMillis(), upload.isChecked, telemetry.isChecked)
        setResult(RESULT_OK)
        if (intent.getBooleanExtra(EXTRA_START_SCAN, false)) startActivity(Intent(this, CaptureActivity::class.java))
        finish()
    }

    /** Off-by-default switch; [label] is its accessibility name. */
    private fun toggle(label: String) = UiKit.toggle(this, false).apply { contentDescription = label }

    private fun toggleRow(icon: Int, title: String, sub: String, sw: Switch) =
        UiKit.listRow(this, icon, title, sub, trailing = sw).apply {
            isClickable = true; isFocusable = true; foreground = UiKit.rowRipple(); setOnClickListener { sw.toggle() }
        }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        .apply { bottomMargin = dp(bottom) }

    companion object {
        const val EXTRA_START_SCAN = "start_scan"
    }
}
