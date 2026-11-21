package dev.capturekit.sample

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import dev.capturekit.capture.FeatureFlags

/**
 * Settings (ADR 0036): every switch that used to need `adb shell setprop` (contract C4, SharedPreferences "capturekit",
 * Boolean keys `ck.*`). Precedence: debug property > this setting > default ([FeatureFlags.resolve]). A change takes effect at the
 * next scan (the capture screen resolves the flags when it opens).
 */
class SettingsActivity : Activity() {
    private class Entry(val key: String, val icon: Int, val title: String, val sub: String, val default: Boolean)

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private val capture by lazy {
        val d = FeatureFlags.Flags.DEFAULTS
        listOf(
            Entry(FeatureFlags.PREF_OBJECT_BOXES, R.drawable.ic_boxes, "Object boxes", "Green boxes with a label and number on the camera view; objects are remembered for the scan", d.segmentation),
            Entry(FeatureFlags.PREF_RECORD_IMU, R.drawable.ic_timer, "Record motion sensors", "Keep the gyroscope and accelerometer in the scan", d.recordImu),
            Entry(FeatureFlags.PREF_RECALIBRATE_CARD, R.drawable.ic_warning, "Tracking recovery card", "Shows what to do when camera tracking is lost", d.recalibrateCard),
        )
    }

    private val guidance by lazy {
        val d = FeatureFlags.Flags.DEFAULTS
        listOf(
            Entry(FeatureFlags.PREF_GUIDANCE, R.drawable.ic_voice, "Navigation prompts", "Spoken and written directions while you scan", d.guidance),
            Entry(FeatureFlags.PREF_VOICE_COMMANDS, R.drawable.ic_mic, "Voice commands", "Push-to-talk microphone button (asks for the microphone)", d.voiceCommands),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = Features.prefs(this)
        fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(bottom) }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        fun section(title: String, list: List<Entry>) {
            root.addView(UiKit.sectionHeader(this, title))
            root.addView(UiKit.group(this).apply {
                for (e in list) {
                    val sw = UiKit.toggle(this@SettingsActivity, prefs.getBoolean(e.key, e.default)).apply {
                        contentDescription = e.title
                        setOnCheckedChangeListener { _, on -> prefs.edit().putBoolean(e.key, on).apply(); Features.invalidate() }
                    }
                    addView(UiKit.listRow(this@SettingsActivity, e.icon, e.title, e.sub, trailing = sw).apply {
                        isClickable = true; isFocusable = true; foreground = UiKit.rowRipple(); setOnClickListener { sw.toggle() }
                    })
                }
            }, lp(24))
        }
        root.addView(UiKit.topBar(this, "Settings", onBack = { finish() }), lp(8))
        section("Capture", capture)
        section("Guidance", guidance)
        root.addView(UiKit.caption(this, "Changes apply to the next scan.").apply { gravity = Gravity.CENTER })
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            clipToPadding = false
            addView(root)
            UiKit.applyInsetsAboveBar(this, 20)
        }
        val bar = UiKit.bottomActionBar(this, UiKit.secondaryButton(this, "Done").apply { setOnClickListener { finish() } })
        setContentView(UiKit.stickyPage(this, scroll, bar))
        UiKit.fadeIn(root)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) UiKit.immersive(this)
    }
}
