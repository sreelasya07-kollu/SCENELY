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
    private class Entry(val key: String, val title: String, val sub: String, val default: Boolean)

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private val entries by lazy {
        val d = FeatureFlags.Flags.DEFAULTS
        listOf(
            Entry(FeatureFlags.PREF_OBJECT_BOXES, "Object boxes", "Green boxes with a label and number on the camera view; objects are remembered for the scan", d.segmentation),
            Entry(FeatureFlags.PREF_RECORD_IMU, "Record motion sensors", "Keep the gyroscope and accelerometer in the scan", d.recordImu),
            Entry(FeatureFlags.PREF_GUIDANCE, "Navigation prompts", "Spoken and written directions while you scan", d.guidance),
            Entry(FeatureFlags.PREF_VOICE_COMMANDS, "Voice commands", "Push-to-talk microphone button (asks for the microphone)", d.voiceCommands),
            Entry(FeatureFlags.PREF_RECALIBRATE_CARD, "Tracking recovery card", "Shows what to do when camera tracking is lost", d.recalibrateCard),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = Features.prefs(this)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(UiKit.largeTitle(this, "Settings"), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(16) })
        root.addView(UiKit.group(this).apply {
            for (e in entries) {
                val sw = UiKit.toggle(this@SettingsActivity, prefs.getBoolean(e.key, e.default)).apply {
                    contentDescription = e.title
                    setOnCheckedChangeListener { _, on -> prefs.edit().putBoolean(e.key, on).apply(); Features.invalidate() }
                }
                addView(UiKit.listRow(this@SettingsActivity, null, e.title, e.sub, trailing = sw).apply {
                    isClickable = true; foreground = UiKit.rowRipple(); setOnClickListener { sw.toggle() }
                })
            }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(16) })
        root.addView(UiKit.caption(this, "Changes apply to the next scan.").apply { gravity = Gravity.CENTER })
        root.addView(UiKit.secondaryButton(this, "Done").apply { setOnClickListener { finish() } },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(20) })
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            addView(root)
            UiKit.applyInsets(this, 20)
        }
        setContentView(UiKit.page(this, scroll))
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) UiKit.immersive(this)
    }
}
