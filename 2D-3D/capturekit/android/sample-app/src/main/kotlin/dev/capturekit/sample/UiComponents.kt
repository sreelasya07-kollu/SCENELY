package dev.capturekit.sample

import android.animation.ValueAnimator
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import dev.capturekit.sample.UiKit.dp
import dev.capturekit.sample.UiKit.dpF

/*
 * Design-system components layered on [UiKit]: top bar, icon button, stat tile, empty state, skeleton,
 * bottom action bar, bottom sheet, progress ring, snackbar and motion helpers. All read [DesignTokens].
 */

// ---- Motion ----

/** False when the user turned animations off (Developer options or accessibility "remove animations"). */
fun UiKit.animationsEnabled(ctx: Context): Boolean =
    Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) != 0f

/** Token duration, collapsed to 0 under reduced motion. */
fun UiKit.motionMs(ctx: Context, ms: Long = DesignTokens.MOTION_MEDIUM): Long = if (animationsEnabled(ctx)) ms else 0L

/** Fades [v] in (reduced motion: shows it at once). */
fun UiKit.fadeIn(v: View, ms: Long = DesignTokens.MOTION_MEDIUM) {
    v.visibility = View.VISIBLE
    v.animate().cancel()
    val d = motionMs(v.context, ms)
    if (d == 0L) { v.alpha = 1f; return }
    v.alpha = 0f
    v.animate().alpha(1f).setDuration(d).setInterpolator(DecelerateInterpolator()).start()
}

/** Slides [v] up a little while fading in; the enter motion for cards and sheets. */
fun UiKit.slideUp(v: View, distanceDp: Int = 24, ms: Long = DesignTokens.MOTION_MEDIUM, delayMs: Long = 0L) {
    v.visibility = View.VISIBLE
    v.animate().cancel()
    val d = motionMs(v.context, ms)
    if (d == 0L) { v.alpha = 1f; v.translationY = 0f; return }
    v.alpha = 0f
    v.translationY = v.context.dpF(distanceDp.toFloat())
    v.animate().alpha(1f).translationY(0f).setStartDelay(delayMs).setDuration(d).setInterpolator(DecelerateInterpolator()).start()
}

/** Fade-through: [out] fades away, then [inn] fades in (swap of two states in the same slot). */
fun UiKit.fadeThrough(out: View?, inn: View) {
    val ctx = inn.context
    val half = motionMs(ctx, DesignTokens.MOTION_FAST)
    if (out == null || half == 0L || out.visibility != View.VISIBLE) {
        out?.visibility = View.GONE
        fadeIn(inn)
        return
    }
    out.animate().cancel()
    out.animate().alpha(0f).setDuration(half).withEndAction {
        out.visibility = View.GONE
        out.alpha = 1f
        fadeIn(inn, half * 2)
    }.start()
}

// ---- Primitives ----

/** Rounded tile with a tinted icon (leading icon of list rows, empty states). */
fun UiKit.iconTile(ctx: Context, icon: Int, tint: Int = ACCENT, sizeDp: Int = 36): FrameLayout = FrameLayout(ctx).apply {
    val bg = if (tint == ACCENT) ACCENT_CONTAINER else withAlpha(tint, 0x29)
    background = rounded(bg, ctx.dpF(DesignTokens.R_12.toFloat()))
    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    val inner = (sizeDp * 0.56f).toInt().coerceAtLeast(16)
    addView(iconImage(ctx, icon, if (tint == ACCENT) ON_ACCENT_CONTAINER else tint), FrameLayout.LayoutParams(ctx.dp(inner), ctx.dp(inner), Gravity.CENTER))
}

/** Hairline divider that starts [insetStartPx] from the left (rows with a leading tile). */
class InsetDivider(color: Int, private val thicknessPx: Int, private val insetStartPx: Int) : Drawable() {
    private val paint = Paint().apply { this.color = color }
    override fun draw(c: Canvas) {
        val b = bounds
        c.drawRect((b.left + insetStartPx).toFloat(), b.top.toFloat(), b.right.toFloat(), b.top + thicknessPx.toFloat(), paint)
    }
    override fun getIntrinsicHeight() = thicknessPx
    override fun getIntrinsicWidth() = -1
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter }
    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

/** Icon-only button with a 48 dp touch target. [filled] adds a tonal circle; otherwise it is a bare ripple. */
fun UiKit.iconButton(
    ctx: Context, drawableId: Int, description: String, sizeDp: Int = DesignTokens.TOUCH_TARGET,
    tint: Int = LABEL, filled: Boolean = false,
): FrameLayout = FrameLayout(ctx).apply {
    isClickable = true
    isFocusable = true
    val px = ctx.dp(maxOf(sizeDp, DesignTokens.TOUCH_TARGET))
    minimumWidth = px
    minimumHeight = px
    contentDescription = description
    val mask = GradientDrawable().apply { setColor(Color.WHITE); shape = GradientDrawable.OVAL }
    val body: Drawable? = if (filled) GradientDrawable().apply { setColor(SURFACE_3); shape = GradientDrawable.OVAL } else null
    background = RippleDrawable(ColorStateList.valueOf(0x1FFFFFFF), body, mask)
    addView(iconImage(ctx, drawableId, tint), FrameLayout.LayoutParams(ctx.dp(24), ctx.dp(24), Gravity.CENTER))
    pressScale(this)
}

/** Screen header: optional back button, heading title, optional trailing view. */
fun UiKit.topBar(ctx: Context, title: String, onBack: (() -> Unit)? = null, trailing: View? = null): LinearLayout = LinearLayout(ctx).apply {
    orientation = LinearLayout.HORIZONTAL
    gravity = Gravity.CENTER_VERTICAL
    minimumHeight = ctx.dp(56)
    if (onBack != null) addView(iconButton(ctx, R.drawable.ic_arrow_back, "Back").apply { setOnClickListener { onBack() } },
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { rightMargin = ctx.dp(8) })
    addView(role(ctx, title, DesignTokens.TITLE_LARGE).apply {
        if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
    }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
    if (trailing != null) addView(trailing, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
}

/** Compact metric card: small label (optional icon) over a large value. The value TextView carries tag "value". */
fun UiKit.statTile(ctx: Context, icon: Int?, label: String, value: String, tint: Int = ACCENT): LinearLayout = LinearLayout(ctx).apply {
    orientation = LinearLayout.VERTICAL
    background = card(ctx, DesignTokens.R_16)
    setPadding(ctx.dp(16), ctx.dp(14), ctx.dp(16), ctx.dp(14))
    addView(LinearLayout(ctx).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        if (icon != null) addView(iconImage(ctx, icon, tint), LinearLayout.LayoutParams(ctx.dp(16), ctx.dp(16)).apply { rightMargin = ctx.dp(8) })
        addView(role(ctx, label, DesignTokens.LABEL_MEDIUM, LABEL_2))
    })
    addView(role(ctx, value, DesignTokens.HEADLINE_SMALL).apply { tag = "value"; maxLines = 1 },
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = ctx.dp(6) })
}

/** Centred illustration (icon on a large tinted disc), title, body and an optional primary call to action. */
fun UiKit.emptyState(
    ctx: Context, icon: Int, title: String, body: String, ctaLabel: String? = null, onCta: (() -> Unit)? = null,
): LinearLayout = LinearLayout(ctx).apply {
    orientation = LinearLayout.VERTICAL
    gravity = Gravity.CENTER_HORIZONTAL
    setPadding(ctx.dp(24), ctx.dp(32), ctx.dp(24), ctx.dp(32))
    addView(FrameLayout(ctx).apply {
        background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(ACCENT_CONTAINER) }
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        addView(iconImage(ctx, icon, ON_ACCENT_CONTAINER), FrameLayout.LayoutParams(ctx.dp(44), ctx.dp(44), Gravity.CENTER))
    }, LinearLayout.LayoutParams(ctx.dp(96), ctx.dp(96)))
    addView(role(ctx, title, DesignTokens.HEADLINE_SMALL).apply {
        gravity = Gravity.CENTER
        if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
    }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = ctx.dp(24) })
    addView(role(ctx, body, DesignTokens.BODY_LARGE, LABEL_2).apply { gravity = Gravity.CENTER },
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = ctx.dp(8) })
    if (ctaLabel != null && onCta != null) addView(bigButton(ctx, ctaLabel).apply { setOnClickListener { onCta() } },
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = ctx.dp(24) })
}

// ---- Skeleton ----

/** Loading placeholder: tonal block with a soft highlight sweeping across (static under reduced motion). */
class SkeletonView(ctx: Context, private val radiusDp: Int) : View(ctx) {
    private val base = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = UiKit.SURFACE_2 }
    private val sweep = Paint(Paint.ANTI_ALIAS_FLAG)
    private val matrix = Matrix()
    private val rect = RectF()
    private var shader: LinearGradient? = null
    private var phase = 0f
    private var animator: ValueAnimator? = null

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        val band = maxOf(1f, w * 0.6f)
        shader = LinearGradient(0f, 0f, band, 0f, intArrayOf(0x00FFFFFF, 0x12FFFFFF, 0x00FFFFFF), null, Shader.TileMode.CLAMP)
        sweep.shader = shader
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (!UiKit.animationsEnabled(context)) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1400L
            repeatCount = ValueAnimator.INFINITE
            addUpdateListener { phase = it.animatedValue as Float; invalidate() }
            start()
        }
    }

    override fun onDetachedFromWindow() {
        animator?.cancel(); animator = null
        super.onDetachedFromWindow()
    }

    override fun onDraw(c: Canvas) {
        val r = context.dpF(radiusDp.toFloat())
        rect.set(0f, 0f, width.toFloat(), height.toFloat())
        c.drawRoundRect(rect, r, r, base)
        if (animator != null && shader != null) {
            matrix.setTranslate(-width * 0.6f + phase * width * 1.6f, 0f)
            shader!!.setLocalMatrix(matrix)
            c.drawRoundRect(rect, r, r, sweep)
        }
    }
}

/** Skeleton block; [widthDp] < 0 = match parent. */
fun UiKit.skeleton(ctx: Context, widthDp: Int, heightDp: Int, radiusDp: Int = DesignTokens.R_12): View =
    SkeletonView(ctx, radiusDp).apply {
        layoutParams = ViewGroup.LayoutParams(if (widthDp < 0) ViewGroup.LayoutParams.MATCH_PARENT else ctx.dp(widthDp), ctx.dp(heightDp))
    }

// ---- Insets, bottom bar, sheet ----

/** Like [UiKit.applyInsets] but leaves the bottom free for a sticky bar below the content. */
fun UiKit.applyInsetsAboveBar(v: View, basePadDp: Int = 12) {
    val base = v.context.dp(basePadDp)
    v.setPadding(base, base, base, base)
    v.setOnApplyWindowInsetsListener { view, ins ->
        if (Build.VERSION.SDK_INT >= 30) {
            val b = ins.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            view.setPadding(base + b.left, base + b.top, base + b.right, base)
        }
        ins
    }
    v.requestApplyInsets()
}

/** Sticky action bar: hairline on top, buttons in one row (or stacked), padded by the system bars. */
fun UiKit.bottomActionBar(ctx: Context, vararg actions: View, stacked: Boolean = false): LinearLayout = LinearLayout(ctx).apply {
    orientation = LinearLayout.VERTICAL
    setBackgroundColor(SURFACE_1)
    addView(View(ctx).apply { setBackgroundColor(SEPARATOR) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, maxOf(1, ctx.dp(1) / 2)))
    val row = LinearLayout(ctx).apply {
        orientation = if (stacked) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    actions.forEachIndexed { i, a ->
        val lp = if (stacked) LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        else LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        if (i > 0) { if (stacked) lp.topMargin = ctx.dp(8) else lp.leftMargin = ctx.dp(12) }
        row.addView(a, lp)
    }
    addView(row)
    val base = ctx.dp(DesignTokens.SP_16)
    row.setPadding(base, ctx.dp(DesignTokens.SP_12), base, ctx.dp(DesignTokens.SP_12))
    setOnApplyWindowInsetsListener { _, ins ->
        if (Build.VERSION.SDK_INT >= 30) {
            val b = ins.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            row.setPadding(base + b.left, ctx.dp(DesignTokens.SP_12), base + b.right, ctx.dp(DesignTokens.SP_12) + b.bottom)
        }
        ins
    }
    requestApplyInsets()
}

/** Page with scrolling [content] and a sticky [bar] under it. */
fun UiKit.stickyPage(ctx: Context, content: View, bar: View): FrameLayout = page(ctx, LinearLayout(ctx).apply {
    orientation = LinearLayout.VERTICAL
    addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
    addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
})

/** Bottom sheet: scrim, drag handle, rounded top corners, slides up. [content] is added below the handle. */
fun UiKit.sheet(act: Activity, content: View, cancelable: Boolean = true, onDismiss: (() -> Unit)? = null): Dialog {
    val dlg = Dialog(act)
    dlg.requestWindowFeature(Window.FEATURE_NO_TITLE)
    val r = act.dpF(DesignTokens.R_28.toFloat())
    val panel = LinearLayout(act).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply { setColor(SURFACE_2); cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f) }
        val pad = act.dp(DesignTokens.SP_24)
        setPadding(pad, act.dp(DesignTokens.SP_12), pad, pad)
        addView(View(act).apply { background = rounded(0x4DFFFFFF, act.dpF(2f)) },
            LinearLayout.LayoutParams(act.dp(32), act.dp(4)).apply { gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = act.dp(DesignTokens.SP_16) })
        addView(content, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        setOnApplyWindowInsetsListener { v, ins ->
            if (Build.VERSION.SDK_INT >= 30) {
                val b = ins.getInsets(WindowInsets.Type.systemBars())
                v.setPadding(pad, act.dp(DesignTokens.SP_12), pad, pad + b.bottom)
            }
            ins
        }
    }
    dlg.setContentView(panel)
    dlg.setCancelable(cancelable)
    dlg.window?.apply {
        setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        setGravity(Gravity.BOTTOM)
        addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        attributes = attributes.apply { dimAmount = 0.6f }
        val screenW = act.resources.displayMetrics.widthPixels
        setLayout(minOf(screenW, act.dp(560)), ViewGroup.LayoutParams.WRAP_CONTENT)
    }
    dlg.setOnShowListener { slideUp(panel, 48, DesignTokens.MOTION_MEDIUM) }
    if (onDismiss != null) dlg.setOnDismissListener { onDismiss() }
    return dlg
}

// ---- Progress ring ----

/** Circular progress with the percentage in the middle. [setProgress] is cheap (no allocation) and redraws only when the whole percent changes. */
class ProgressRing(ctx: Context) : View(ctx) {
    private val d = ctx.resources.displayMetrics.density
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 4f * d; color = 0x33FFFFFF
    }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 4f * d; strokeCap = Paint.Cap.ROUND; color = UiKit.ACCENT
    }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = UiKit.LABEL; textAlign = Paint.Align.CENTER; typeface = UiKit.MEDIUM
        textSize = DesignTokens.LABEL_MEDIUM.sizeSp * ctx.resources.displayMetrics.density * ctx.resources.configuration.fontScale
    }
    private val rect = RectF()
    private val texts = Array(101) { "$it%" }
    private var pct = 0

    init {
        contentDescription = "Coverage 0 percent"
    }

    var showLabel = true
    var accent: Int
        get() = arc.color
        set(value) { if (arc.color != value) { arc.color = value; invalidate() } }

    /** [fraction] 0..1. */
    fun setProgress(fraction: Float) {
        val p = (fraction.coerceIn(0f, 1f) * 100f + 0.5f).toInt()
        if (p == pct) return
        pct = p
        contentDescription = "Coverage ${p} percent"
        invalidate()
    }

    val percent: Int get() = pct

    override fun onMeasure(w: Int, h: Int) {
        val s = (56f * d).toInt()
        setMeasuredDimension(resolveSize(s, w), resolveSize(s, h))
    }

    override fun onDraw(c: Canvas) {
        val inset = track.strokeWidth / 2f + 1f
        rect.set(inset, inset, width - inset, height - inset)
        c.drawArc(rect, 0f, 360f, false, track)
        if (pct > 0) c.drawArc(rect, -90f, 360f * pct / 100f, false, arc)
        if (showLabel) c.drawText(texts[pct], width / 2f, height / 2f - (label.ascent() + label.descent()) / 2f, label)
    }
}

fun UiKit.progressRing(ctx: Context): ProgressRing = ProgressRing(ctx)

// ---- Snackbar ----

private const val SNACKBAR_TAG = "ck_snackbar"

/** Transient message at the bottom of the screen (replaces Toast); optional single action. */
fun UiKit.snackbar(a: Activity, msg: String, kind: UiKit.Kind = UiKit.Kind.INFO, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    val host = a.findViewById<ViewGroup>(android.R.id.content) ?: return
    host.findViewWithTag<View>(SNACKBAR_TAG)?.let { host.removeView(it) }
    val bar = LinearLayout(a).apply {
        tag = SNACKBAR_TAG
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = rounded(SURFACE_3, a.dpF(DesignTokens.R_16.toFloat()), withAlpha(if (kind == UiKit.Kind.INFO) 0xFFFFFF else kind.color, 0x40), maxOf(1, a.dp(1) / 2))
        elevation = a.dpF(6f)
        setPadding(a.dp(16), a.dp(12), a.dp(8), a.dp(12))
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        if (kind != UiKit.Kind.INFO) addView(View(a).apply { background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(kind.color) } },
            LinearLayout.LayoutParams(a.dp(8), a.dp(8)).apply { rightMargin = a.dp(12) })
        addView(role(a, msg, DesignTokens.BODY_MEDIUM).apply { maxWidth = a.dp(420) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        if (actionLabel != null && onAction != null) addView(
            role(a, actionLabel, DesignTokens.LABEL_LARGE, ACCENT).apply {
                minimumHeight = a.dp(DesignTokens.TOUCH_TARGET)
                gravity = Gravity.CENTER
                setPadding(a.dp(16), 0, a.dp(8), 0)
                setOnClickListener { host.removeView(parent as View); onAction() }
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
    val lp = FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL)
    lp.bottomMargin = a.dp(DesignTokens.SP_24)
    if (Build.VERSION.SDK_INT >= 30) host.rootWindowInsets?.getInsets(WindowInsets.Type.systemBars())?.let { lp.bottomMargin += it.bottom }
    host.addView(bar, lp)
    slideUp(bar, 16, DesignTokens.MOTION_MEDIUM)
    bar.announceForAccessibility(msg)
    bar.postDelayed({
        if (bar.parent == null) return@postDelayed
        val d = motionMs(a, DesignTokens.MOTION_FAST)
        if (d == 0L) host.removeView(bar)
        else bar.animate().alpha(0f).setDuration(d).withEndAction { host.removeView(bar) }.start()
    }, if (actionLabel != null) 6000L else 3500L)
}

/** Tonal, outline-free text button for low-emphasis actions (Decline, Skip). */
fun UiKit.textButton(ctx: Context, label: String, color: Int = LABEL_2): Button = Button(ctx).apply {
    text = label
    textSize = DesignTokens.LABEL_LARGE.sizeSp
    isAllCaps = false
    stateListAnimator = null
    typeface = UiKit.MEDIUM
    setTextColor(color)
    minimumHeight = ctx.dp(DesignTokens.TOUCH_TARGET)
    minHeight = ctx.dp(DesignTokens.TOUCH_TARGET)
    setPadding(ctx.dp(16), 0, ctx.dp(16), 0)
    background = RippleDrawable(ColorStateList.valueOf(0x1FFFFFFF), null, rounded(Color.WHITE, ctx.dpF(DesignTokens.R_PILL.toFloat())))
}

/** Animated page dots: the selected dot widens and takes the accent. */
class PageDots(ctx: Context, private val count: Int) : LinearLayout(ctx) {
    private val dots = List(count) { View(ctx) }
    private var selected = -1

    init {
        gravity = Gravity.CENTER
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        dots.forEach { v ->
            addView(v, LayoutParams(context.dp(8), context.dp(8)).apply { leftMargin = context.dp(4); rightMargin = context.dp(4) })
        }
        select(0)
    }

    fun select(i: Int, animate: Boolean = true) {
        if (i == selected) return
        selected = i
        dots.forEachIndexed { idx, v ->
            val on = idx == i
            v.background = UiKit.rounded(if (on) UiKit.ACCENT else DesignTokens.OUTLINE, context.dpF(4f))
            val target = context.dp(if (on) 24 else 8)
            val lp = v.layoutParams
            val d = if (animate) UiKit.motionMs(context, DesignTokens.MOTION_FAST) else 0L
            if (d == 0L || lp.width == target) { lp.width = target; v.layoutParams = lp }
            else ValueAnimator.ofInt(lp.width, target).apply {
                duration = d
                addUpdateListener { lp.width = it.animatedValue as Int; v.layoutParams = lp }
                start()
            }
        }
    }
}
