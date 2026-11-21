package dev.capturekit.sample

import android.animation.ObjectAnimator
import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.capturekit.capture.FeatureFlags
import dev.capturekit.guidance.StatusPill

/**
 * Shared capture HUD over the camera preview (design tokens, ADR 0039):
 *  - Top bar: close (left), centred status pill (tracking + quality + thermal), one REC timer capsule (right)
 *  - Right column: 48 dp icon buttons (voice guidance, push-to-talk mic, object boxes, trial)
 *  - Viewfinder reticle: spatial corner brackets with a centre dot
 *  - Middle row: coverage ring with % and the top weak zone (one line); debug messages beside it
 *  - Coaching capsule (icon + sentence, crossfade) above the action row and the camera deck
 *  - Camera deck: pause (vector icon) | shutter inside a thin ring that fills with completeness | spacer
 * Long-press the status pill to toggle the ingest debug line. Clamped by system bar / cutout insets.
 * [features] (ADR 0032): a switched-off feature's view is never added / stays GONE and gets no click listener
 * (completeness card = always while scanning, boxes button = segmentation / live object boxes, mic button = voiceCommands,
 * recalibration card = recalibrateCard).
 */
class Hud(private val ctx: Activity, private val features: FeatureFlags.Flags = FeatureFlags.Flags.DEFAULTS) {
    private val d = ctx.resources.displayMetrics.density
    private fun dp(v: Int) = (v * d).toInt()

    private val pill = UiKit.chip(ctx).apply { textSize = UiKit.TEXT_M; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
    /** In-scan action buttons (ADR 0036): the same actions the voice commands have. Visible while recording. */
    var onAction: (ScanActions.Kind) -> Unit = {}
    private fun actionChip(icon: Int, label: String, desc: String, kind: ScanActions.Kind) = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        minimumHeight = dp(DesignTokens.TOUCH_TARGET)   // 48 dp touch target
        isClickable = true
        isFocusable = true
        background = UiKit.rippleSurface(ctx, UiKit.RADIUS_PILL_DP, UiKit.GLASS)
        setPadding(dp(12), 0, dp(14), 0)
        contentDescription = desc
        addView(UiKit.iconImage(ctx, icon, UiKit.LABEL), LinearLayout.LayoutParams(dp(18), dp(18)).apply { rightMargin = dp(6) })
        addView(TextView(ctx).apply {
            text = label
            textSize = DesignTokens.LABEL_MEDIUM.sizeSp
            typeface = UiKit.MEDIUM
            setTextColor(UiKit.LABEL)
            maxLines = 1
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        })
        UiKit.pressScale(this)
        setOnClickListener { UiKit.haptic(it, false); onAction(kind) }
    }
    private val actionRow = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        visibility = View.GONE
        for ((icon, label, desc, kind) in listOf(
            Quad(R.drawable.ic_hud_repeat, "Repeat", "Repeat the last instruction", ScanActions.Kind.REPEAT),
            Quad(R.drawable.ic_info, "What's missing", "Ask what is still missing", ScanActions.Kind.MISSING),
            Quad(R.drawable.ic_hud_vol_down, "Quieter", "Quieter voice", ScanActions.Kind.QUIETER),
            Quad(R.drawable.ic_hud_vol_up, "Louder", "Louder voice", ScanActions.Kind.LOUDER))) {
            addView(actionChip(icon, label, desc, kind), LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(4); rightMargin = dp(4) })
        }
    }

    private data class Quad(val icon: Int, val label: String, val desc: String, val kind: ScanActions.Kind)

    /** Coverage ring with % (ADR 0035) + the first weak zone. Hidden until the first overlay arrives. */
    private val completeRing = UiKit.progressRing(ctx).apply {
        visibility = View.GONE
        background = UiKit.rounded(UiKit.GLASS, dp(40).toFloat())
        setPadding(dp(4), dp(4), dp(4), dp(4))
    }
    private var ringPct = -1
    private val completeHint = glassText(UiKit.TEXT_S).apply { visibility = View.GONE; maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END }
    private val completeCard = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        addView(completeRing, LinearLayout.LayoutParams(dp(56), dp(56)))
        addView(completeHint, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(8) })
    }
    private val detail = glassText(UiKit.TEXT_M).apply { visibility = View.GONE }
    /** Voice-command feedback ("Paused.", answers, notes): its own line so it never overwrites [detail]. */
    private val voiceLine = glassText(UiKit.TEXT_M).apply { visibility = View.GONE; maxLines = 3; ellipsize = android.text.TextUtils.TruncateAt.END }
    /** Ingest counters line (trk/frm/kf/pts/pl); hidden until the status pill is long-pressed. */
    private val debug = glassText(UiKit.TEXT_S).apply { visibility = View.GONE; typeface = Typeface.MONOSPACE }
    var debugOn = false
        private set
    private val result = glassText(UiKit.TEXT_M).apply { visibility = View.GONE; ellipsize = android.text.TextUtils.TruncateAt.MIDDLE; maxLines = 4 }
    private val recDot = View(ctx).apply { background = UiKit.rounded(UiKit.RED, dp(5).toFloat()) }
    private val recText = TextView(ctx).apply {
        textSize = DesignTokens.LABEL_LARGE.sizeSp; setTextColor(UiKit.LABEL); typeface = UiKit.MEDIUM; fontFeatureSettings = "tnum"
        maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
    }
    /** The single REC timer capsule. */
    private val recRow = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        visibility = View.GONE
        background = UiKit.nowBar(ctx)
        setPadding(dp(14), dp(8), dp(16), dp(8))
        addView(recDot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { rightMargin = dp(8) })
        addView(recText)
    }

    /** Voice guidance on/off (ADR 0036). Hidden unless [setVoice] is given a state. */
    private val voice = HudIconButton(ctx, R.drawable.ic_hud_vol_up, "Voice guidance").apply { visibility = View.GONE }
    /** Live object boxes on/off (ADR 0035). Hidden unless live segmentation runs in this scan. */
    private val boxes = HudIconButton(ctx, R.drawable.ic_boxes, "Object boxes").apply { visibility = View.GONE }
    /** Push-to-talk (right column). Hidden unless voice commands are available. */
    private val mic = HudIconButton(ctx, R.drawable.ic_mic, "Voice commands").apply { visibility = View.GONE }
    /** Field research (trial setup); hidden unless [setTrial] is given a label (field flavour, not recording). */
    private val trial = HudIconButton(ctx, R.drawable.ic_layers, "Research trial").apply { visibility = View.GONE }
    private val reticle = ReticleView(ctx).apply { visibility = View.GONE }

    private val coachIcon = UiKit.iconImage(ctx, R.drawable.ic_info, UiKit.ACCENT)
    private val coachLabel = TextView(ctx).apply {
        textSize = DesignTokens.BODY_LARGE.sizeSp
        setTextColor(UiKit.LABEL)
        typeface = UiKit.MEDIUM
        gravity = Gravity.CENTER_VERTICAL
        maxLines = 2
    }
    /** Coaching capsule: icon + sentence; the whole capsule crossfades between sentences. */
    private val coaching = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = UiKit.nowBar(ctx)
        setPadding(dp(16), dp(10), dp(22), dp(10))
        addView(coachIcon, LinearLayout.LayoutParams(dp(20), dp(20)).apply { rightMargin = dp(10) })
        addView(coachLabel)
    }
    /** Issue #1: centred "Recalibrating" card with the circling-phone animation (declared before [root], which adds it). */
    private val recalibrate = RecalibrateOverlay(ctx)
    private val bannerText = TextView(ctx)
    private val bannerButton = UiKit.bigButton(ctx, "Retry", UiKit.TONAL).apply { textSize = UiKit.TEXT_M; minimumHeight = dp(48); minHeight = dp(48) }
    private val bannerRow = LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        visibility = View.GONE
        addView(bannerText, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        addView(bannerButton, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { leftMargin = dp(12) })
    }

    /** Authentic camera shutter button in the center of the control deck. */
    val button: Button = ShutterButton(ctx).apply {
        minimumWidth = dp(76); minWidth = dp(76)
        minimumHeight = dp(76); minHeight = dp(76)
    }
    /** Thin ring around the shutter that fills with the completeness (visible while a coverage summary exists). */
    private val shutterRing = ShutterRing(ctx).apply { visibility = View.INVISIBLE }
    private val pauseGlyph = GlyphButton(ctx, 50).apply {
        visibility = View.GONE
        setGlyph(R.drawable.ic_pause)
        contentDescription = "Pause"
    }
    /** Circular glass pause/resume button flanking the shutter (vector icon, no text). */
    val pauseButton: Button = pauseGlyph
    /** Leaves the capture screen before recording starts (hidden while recording: Finish is the way out). */
    val closeButton: View = UiKit.circularIconButton(ctx, R.drawable.ic_close, "Close", 48).apply {
        setOnClickListener { ctx.finish() }
    }

    private val pulse = ObjectAnimator.ofFloat(recDot, View.ALPHA, 1f, 0.2f).apply {
        duration = 600; repeatMode = ObjectAnimator.REVERSE; repeatCount = ObjectAnimator.INFINITE
    }
    private fun startPulse() { if (UiKit.animationsEnabled(ctx)) { if (!pulse.isStarted) pulse.start() } else recDot.alpha = 1f }
    private var coachText = ""
    private var bannerKey: String? = null
    private var paused = false
    private var recSec = -1L
    private var recPaused = false
    private var recCounter = ""
    private var everTracked = false   // "Starting..." only until the camera first tracks

    private val longSide = maxOf(ctx.resources.displayMetrics.widthPixels, ctx.resources.displayMetrics.heightPixels)
    init {
        pill.maxWidth = (longSide * 0.36).toInt()
        val mid = (longSide * 0.55).toInt()
        coachLabel.maxWidth = (longSide * 0.62).toInt(); detail.maxWidth = mid; voiceLine.maxWidth = mid; result.maxWidth = mid; debug.maxWidth = mid
        completeHint.maxWidth = (longSide * 0.3).toInt()
        recText.maxWidth = (longSide * 0.28).toInt()
        voice.setOnClickListener { UiKit.haptic(it, false); onVoiceToggle() }
        if (features.segmentation) boxes.setOnClickListener { UiKit.haptic(it, false); onBoxesToggle() }
        if (features.voiceCommands) mic.setOnClickListener { onMicClick() }
        trial.setOnClickListener { onTrialClick() }
        pill.setOnLongClickListener { debugOn = !debugOn; if (!debugOn) debug.visibility = View.GONE; true }
        UiKit.setChip(pill, "● " + StatusPill.STARTING.text, StatusPill.STARTING.tone.argb)
    }

    private fun glassText(size: Float) = TextView(ctx).apply {
        textSize = size; setTextColor(UiKit.LABEL); background = UiKit.glass(ctx, 16)
        setPadding(dp(12), dp(6), dp(12), dp(6))
    }

    /** No-op while the debug line is toggled off (long-press the status pill to show it). */
    fun setDebug(text: String) {
        if (!debugOn) return
        debug.visibility = View.VISIBLE
        if (debug.text.toString() != text) debug.text = text
    }

    /** Set to handle taps on the voice button. */
    var onVoiceToggle: () -> Unit = {}

    val root = FrameLayout(ctx).apply {
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT
        // Top bar: close at the start, status pill centred, REC capsule at the end.
        val topBar = FrameLayout(ctx).apply {
            minimumHeight = dp(DesignTokens.TOUCH_TARGET)
            addView(closeButton, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.START or Gravity.CENTER_VERTICAL))
            addView(pill, FrameLayout.LayoutParams(wrap, wrap, Gravity.CENTER))
            addView(recRow, FrameLayout.LayoutParams(wrap, wrap, Gravity.END or Gravity.CENTER_VERTICAL))
        }
        val msgs = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            addView(detail, lp(bottom = 6)); addView(voiceLine, lp(bottom = 6)); addView(debug, lp(bottom = 6)); addView(result)
        }
        val middle = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(completeCard, LinearLayout.LayoutParams(wrap, wrap).apply { gravity = Gravity.CENTER_VERTICAL })
            addView(msgs, LinearLayout.LayoutParams(0, wrap, 1f).apply { leftMargin = dp(8) })
        }
        // Right column of 48 dp icon buttons, floating over the middle row's reserved end margin.
        val rightColumn = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            for (b in listOf(trial, voice, mic, boxes)) {
                addView(b, LinearLayout.LayoutParams(dp(48), dp(48)).apply { topMargin = dp(4); bottomMargin = dp(4) })
            }
        }

        // Camera shutter deck: symmetrical camera controls (Pause | Shutter | Spacer)
        val shutterDeck = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            addView(pauseButton, LinearLayout.LayoutParams(dp(50), dp(50)).apply { rightMargin = dp(28) })
            addView(FrameLayout(ctx).apply {
                addView(shutterRing, FrameLayout.LayoutParams(dp(88), dp(88), Gravity.CENTER))
                addView(button, FrameLayout.LayoutParams(dp(76), dp(76), Gravity.CENTER))
            }, LinearLayout.LayoutParams(dp(88), dp(88)))
            addView(View(ctx), LinearLayout.LayoutParams(dp(50), dp(50)).apply { leftMargin = dp(28) })
        }

        val column = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            addView(topBar, LinearLayout.LayoutParams(match, wrap))
            addView(bannerRow, LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(6) })
            addView(middle, LinearLayout.LayoutParams(match, 0, 1f).apply { topMargin = dp(6); bottomMargin = dp(6); rightMargin = dp(60) })
            addView(actionRow, LinearLayout.LayoutParams(wrap, wrap).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(8) })
            addView(coaching, LinearLayout.LayoutParams(wrap, wrap).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(12) })
            addView(shutterDeck, LinearLayout.LayoutParams(match, wrap).apply { bottomMargin = dp(2) })
        }

        addView(reticle, FrameLayout.LayoutParams(dp(84), dp(84), Gravity.CENTER))
        addView(column, FrameLayout.LayoutParams(match, match))
        addView(rightColumn, FrameLayout.LayoutParams(wrap, wrap, Gravity.END or Gravity.CENTER_VERTICAL))
        if (features.recalibrateCard) addView(recalibrate.card, FrameLayout.LayoutParams(wrap, wrap, Gravity.CENTER))   // above the column, never clickable
        UiKit.applyInsets(this)
    }

    private fun lp(bottom: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(bottom) }

    /**
     * The single status pill. [reasons] are the latest core frame-quality reason codes, [thermalLevel] the governor
     * policy level. [live] false = no camera frame recently (paused/stalled): neutral pill, never a tracking verdict.
     */
    fun setStatus(state: String, failure: String, reasons: List<String>, thermalLevel: Int, live: Boolean = true) {
        if (!live) { UiKit.setChip(pill, "● Camera paused", StatusPill.Tone.NEUTRAL.argb); return }
        if (state == "TRACKING") everTracked = true
        val p = StatusPill.statusPill(state, failure, reasons, thermalLevel, everTracked)
        UiKit.setChip(pill, "● " + p.text, p.tone.argb)
    }

    /** Tracking-only pill (screens without core quality/thermal, e.g. the raw recorder). */
    fun setTracking(state: String, failure: String, live: Boolean = true) = setStatus(state, failure, emptyList(), 0, live)

    /** Coverage ring (null hides it): percent in the ring and the highest-priority weak zone. UI thread only, ~4 Hz; no allocation unless the text changes. */
    fun setCompleteness(s: dev.capturekit.guidance.Completeness.Summary?) {
        if (s == null) {
            completeRing.visibility = View.GONE; completeHint.visibility = View.GONE
            shutterRing.visibility = View.INVISIBLE; ringPct = -1
            return
        }
        val pct = s.completenessPct
        completeRing.visibility = View.VISIBLE
        if (pct != ringPct) {
            ringPct = pct
            completeRing.setProgress(pct / 100f)
            completeRing.accent = if (pct >= 80) UiKit.GREEN else UiKit.ACCENT
            completeRing.contentDescription = "Scan is $pct percent complete"
            shutterRing.setProgress(pct / 100f, pct >= 80)
        }
        shutterRing.visibility = View.VISIBLE
        val z = s.weakZones.firstOrNull()
        completeHint.visibility = if (z == null) View.GONE else View.VISIBLE
        if (z != null && completeHint.text.toString() != z.text) completeHint.text = z.text
    }

    /** Voice-command feedback line; null hides it. Independent of [setDetail]. */
    fun setVoiceLine(text: String?) {
        voiceLine.visibility = if (text == null) View.GONE else View.VISIBLE
        if (text != null && voiceLine.text.toString() != text) voiceLine.text = text
    }

    fun setDetail(text: String?) {
        detail.visibility = if (text == null) View.GONE else View.VISIBLE
        if (text != null) detail.text = text
    }

    /** Crossfades to the new coaching sentence (instant under reduced motion). No-op when unchanged. */
    fun setCoaching(text: String, sub: String = "") {
        if (text == coachText) return
        coachText = text
        coaching.animate().cancel()
        val half = UiKit.motionMs(ctx, DesignTokens.MOTION_FAST)
        if (half == 0L) { coachLabel.text = text; coaching.alpha = 1f; return }
        coaching.animate().alpha(0f).setDuration(half).withEndAction {
            coachLabel.text = text
            coaching.animate().alpha(1f).setDuration(half).start()
        }.start()
    }

    /** Shows or hides the in-scan action row (not in the unguided trial arm). */
    fun setActions(on: Boolean) { actionRow.visibility = if (on) View.VISIBLE else View.GONE }

    fun setRecording(on: Boolean) {
        reticle.visibility = if (on) View.VISIBLE else View.GONE
        recRow.visibility = if (on) View.VISIBLE else View.GONE
        if (on) startPulse() else { pulse.cancel(); recDot.alpha = 1f; paused = false }
        (button as? ShutterButton)?.isRecording = on
        button.text = if (on) "Finish Scan" else "Start Scan"
        pauseButton.visibility = if (on && pauseEnabled) View.VISIBLE else View.GONE
        closeButton.visibility = if (on) View.GONE else View.VISIBLE
        if (!on) {
            pauseGlyph.setGlyph(R.drawable.ic_pause); pauseGlyph.contentDescription = "Pause"
            shutterRing.visibility = View.INVISIBLE; ringPct = -1
        }
        recSec = -1
    }

    /** Pause is offered only where a screen supports it (guided scan). */
    var pauseEnabled = false

    fun setPaused(on: Boolean) {
        if (on == paused) return
        paused = on
        pauseGlyph.setGlyph(if (on) R.drawable.ic_hud_play else R.drawable.ic_pause)
        pauseGlyph.contentDescription = if (on) "Resume" else "Pause"
        if (on) { pulse.cancel(); recDot.alpha = 0.3f } else startPulse()
    }

    /** REC clock; text is rebuilt only when the shown second, pause state or [counter] changes. */
    fun setRecInfo(elapsedMs: Long, counter: String = "") {
        val sec = elapsedMs / 1000
        if (sec == recSec && paused == recPaused && counter == recCounter) return
        recSec = sec; recPaused = paused; recCounter = counter
        recText.text = (if (paused) "PAUSED  " else "REC  ") + UiKit.mmss(elapsedMs) + if (counter.isEmpty()) "" else "  •  $counter"
    }

    fun setVoice(on: Boolean?) {   // null hides the button
        if (on == null) { voice.visibility = View.GONE; return }
        voice.visibility = View.VISIBLE
        voice.setIcon(if (on) R.drawable.ic_hud_vol_up else R.drawable.ic_hud_vol_off)
        voice.style(if (on) UiKit.ACCENT else UiKit.LABEL_3)
        voice.contentDescription = if (on) "Voice guidance on. Tap to turn off." else "Voice guidance off. Tap to turn on."
    }

    /** Set to handle taps on the object boxes button. */
    var onBoxesToggle: () -> Unit = {}

    /**
     * Object boxes button; null hides it (not recording, or the unguided trial arm). [unavailable] (only with null [on], flag on)
     * shows a dimmed button instead: segmentation is wanted but cannot run (ADR 0038).
     */
    fun setBoxes(on: Boolean?, unavailable: Boolean = false) {
        if (!features.segmentation) { boxes.visibility = View.GONE; return }
        if (on == null) {
            if (!unavailable) { boxes.visibility = View.GONE; return }
            boxes.visibility = View.VISIBLE
            boxes.style(UiKit.LABEL_3)
            boxes.alpha = 0.5f
            boxes.contentDescription = "Object boxes are unavailable on this device."
            return
        }
        boxes.visibility = View.VISIBLE
        boxes.alpha = 1f
        boxes.style(if (on) UiKit.GREEN else UiKit.LABEL_3)
        boxes.contentDescription = if (on) "Object boxes on the camera view are shown. Tap to hide them." else "Object boxes on the camera view are hidden. Tap to show them."
    }

    /** Set to handle taps on the trial button (field flavour: opens the trial setup). */
    var onTrialClick: () -> Unit = {}

    /** Trial button; [label] goes into its description. null hides it (standard flavour, or while recording). */
    fun setTrial(label: String?) {
        if (label == null) { trial.visibility = View.GONE; return }
        trial.visibility = View.VISIBLE
        trial.style(UiKit.ACCENT)
        trial.contentDescription = "Research trial: $label. Tap to change participant or guided arm."
    }

    /** Set to handle taps on the mic button (push-to-talk). */
    var onMicClick: () -> Unit = {}

    /**
     * Push-to-talk button. null hides it (no voice commands here). Listening is unmistakable: solid red button and a
     * spoken-by-TalkBack description; idle is the quiet glass button.
     */
    fun setMic(state: MicState?) {
        if (state == null || !features.voiceCommands) { mic.visibility = View.GONE; return }
        mic.visibility = View.VISIBLE
        val desc = when (state) {
            MicState.IDLE -> "Voice commands. Tap, then say pause, resume, repeat, what is missing, finish, louder or quieter."
            MicState.LISTENING -> "Listening for a command. Tap to cancel."
            MicState.THINKING -> "Understanding the command."
            MicState.NEEDS_PERMISSION -> "Voice commands need microphone permission. Tap to learn more."
        }
        when (state) {
            MicState.IDLE -> mic.style(UiKit.LABEL)
            MicState.LISTENING -> mic.style(Color.WHITE, UiKit.RED)
            MicState.THINKING -> mic.style(UiKit.AMBER)
            MicState.NEEDS_PERMISSION -> mic.style(UiKit.LABEL_3)
        }
        if (mic.contentDescription != desc) mic.contentDescription = desc
        mic.isEnabled = state != MicState.THINKING
    }

    /** Full-width strip under the top bar; reserved for errors and blocking conditions. */
    fun setBanner(msg: String?, kind: UiKit.Kind = UiKit.Kind.WARN, retryLabel: String? = null, retry: (() -> Unit)? = null) {
        if (msg == null) { bannerRow.visibility = View.GONE; bannerKey = null; return }
        if (retry != null) bannerButton.setOnClickListener { retry() }
        val key = msg + "|" + kind + "|" + retryLabel + "|" + (retry != null)
        if (key == bannerKey && bannerRow.visibility == View.VISIBLE) return   // unchanged: no new drawables
        bannerKey = key
        UiKit.applyBanner(bannerText, msg, kind)   // tinted container + status dot, tokens
        bannerText.textSize = UiKit.TEXT_M
        bannerButton.visibility = if (retry != null) View.VISIBLE else View.GONE
        if (retry != null) bannerButton.text = retryLabel ?: "Retry"
        bannerRow.visibility = View.VISIBLE
    }

    fun setResult(msg: String?, kind: UiKit.Kind = UiKit.Kind.OK) {
        if (msg == null) { result.visibility = View.GONE; return }
        result.text = msg
        result.background = UiKit.rounded(kind.color, dp(UiKit.RADIUS_DP).toFloat())
        result.visibility = View.VISIBLE
    }

    fun haptic(confirm: Boolean) = UiKit.haptic(button, confirm)
    fun hapticFor(haptic: String, priority: Int) = UiKit.hapticFor(button, haptic, priority)

    /**
     * Issue #1 / ADR 0031: the recalibration card. [text] = the core's sentence ([dev.capturekit.guidance.Recalibration.prompt]);
     * null hides it. Shown while the core recovers tracking (keyframe capture paused); dismissed when tracking is back.
     */
    fun setRecalibrate(text: String?) { if (features.recalibrateCard) recalibrate.set(text) }

    fun release() { pulse.cancel(); coaching.animate().cancel(); recalibrate.release() }
}

/** 48 dp circular glass icon button for the HUD's right column; [style] recolours it and only rebuilds drawables on change. */
private class HudIconButton(ctx: Context, private var iconRes: Int, desc: String) : FrameLayout(ctx) {
    private val d = ctx.resources.displayMetrics.density
    private val img: ImageView = UiKit.iconImage(ctx, iconRes, UiKit.LABEL)
    private var tint = UiKit.LABEL
    private var fill = UiKit.GLASS

    init {
        isClickable = true
        isFocusable = true
        minimumWidth = (DesignTokens.TOUCH_TARGET * d).toInt()
        minimumHeight = (DesignTokens.TOUCH_TARGET * d).toInt()
        contentDescription = desc
        addView(img, LayoutParams((22 * d).toInt(), (22 * d).toInt(), Gravity.CENTER))
        background = surface(fill)
        UiKit.pressScale(this)
    }

    private fun surface(color: Int): Drawable {
        if (color == UiKit.GLASS) return UiKit.rippleSurface(context, UiKit.RADIUS_PILL_DP, UiKit.GLASS)
        val mask = GradientDrawable().apply { setColor(Color.WHITE); shape = GradientDrawable.OVAL }
        val body = GradientDrawable().apply { setColor(color); shape = GradientDrawable.OVAL }
        return RippleDrawable(ColorStateList.valueOf(0x2E000000), body, mask)
    }

    fun setIcon(res: Int) { if (res != iconRes) { iconRes = res; img.setImageResource(res) } }

    fun style(tint: Int, fill: Int = UiKit.GLASS) {
        if (tint != this.tint) { this.tint = tint; img.imageTintList = ColorStateList.valueOf(tint) }
        if (fill != this.fill) { this.fill = fill; background = surface(fill) }
    }
}

/** Circular glass [Button] that draws a vector glyph instead of text (pause / resume). */
private class GlyphButton(ctx: Context, sizeDp: Int) : Button(ctx) {
    private val d = ctx.resources.displayMetrics.density
    private var glyph: Drawable? = null
    private var res = 0

    init {
        text = ""
        stateListAnimator = null
        background = UiKit.rippleSurface(ctx, UiKit.RADIUS_PILL_DP, UiKit.GLASS)
        minimumWidth = (sizeDp * d).toInt(); minWidth = minimumWidth
        minimumHeight = (sizeDp * d).toInt(); minHeight = minimumHeight
        setPadding(0, 0, 0, 0)
        UiKit.pressScale(this)
    }

    fun setGlyph(id: Int) {
        if (id == res) return
        res = id
        glyph = context.getDrawable(id)?.mutate()?.also { it.setTint(UiKit.LABEL) }
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val g = glyph ?: return
        val half = (12 * d).toInt()
        val cx = width / 2
        val cy = height / 2
        g.setBounds(cx - half, cy - half, cx + half, cy + half)
        g.draw(canvas)
    }
}

/** Thin ring around the shutter: grey track plus an arc that fills with the completeness; `setProgress` allocates nothing. */
private class ShutterRing(ctx: Context) : View(ctx) {
    private val d = ctx.resources.displayMetrics.density
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f * d; color = 0x33FFFFFF }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f * d; strokeCap = Paint.Cap.ROUND; color = UiKit.ACCENT }
    private val rect = RectF()
    private var sweep = 0f

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    fun setProgress(fraction: Float, done: Boolean) {
        val s = fraction.coerceIn(0f, 1f) * 360f
        val c = if (done) UiKit.GREEN else UiKit.ACCENT
        if (s == sweep && arc.color == c) return
        sweep = s; arc.color = c
        invalidate()
    }

    override fun onDraw(c: Canvas) {
        val inset = track.strokeWidth / 2f + 1f
        rect.set(inset, inset, width - inset, height - inset)
        c.drawArc(rect, 0f, 360f, false, track)
        if (sweep > 0f) c.drawArc(rect, -90f, sweep, false, arc)
    }
}
