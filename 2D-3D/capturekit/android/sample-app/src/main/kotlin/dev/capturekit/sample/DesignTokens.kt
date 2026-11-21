package dev.capturekit.sample

/**
 * CaptureKit design tokens: the single source of truth for colour, type, spacing, radii and motion.
 * Pure Kotlin (no android imports) so contrast and grid rules are unit-testable on the JVM.
 * Colours mirror res/values/colors.xml (used by the theme); keep both in sync.
 */
object DesignTokens {
    // ---- Colour (dark first) ----
    const val BG = 0xFF0B0D0E.toInt()
    const val SURFACE_1 = 0xFF14181A.toInt()
    const val SURFACE_2 = 0xFF1B2023.toInt()
    const val SURFACE_3 = 0xFF242B2E.toInt()
    const val ON_SURFACE = 0xFFF2F5F5.toInt()
    const val ON_SURFACE_VARIANT = 0xFFB4BEC0.toInt()
    /** Captions and hints: weaker than onSurfaceVariant but still readable (>= 4.5:1 on every surface). */
    const val ON_SURFACE_MUTED = 0xFF8E999C.toInt()
    const val OUTLINE = 0xFF3A4548.toInt()

    const val ACCENT = 0xFF2DD4BF.toInt()
    const val ON_ACCENT = 0xFF00201C.toInt()
    const val ACCENT_CONTAINER = 0xFF0F3B36.toInt()
    const val ON_ACCENT_CONTAINER = 0xFF9EF2E5.toInt()

    const val SUCCESS = 0xFF30D158.toInt()
    const val WARNING = 0xFFFF9F0A.toInt()
    const val ERROR = 0xFFFF453A.toInt()
    const val SUCCESS_CONTAINER = 0xFF12341D.toInt()
    const val WARNING_CONTAINER = 0xFF3A2A08.toInt()
    const val ERROR_CONTAINER = 0xFF3F1512.toInt()

    const val SCRIM = 0x99000000.toInt()
    /** Translucent surface for chrome over the camera preview. */
    const val GLASS = 0x8C1B2023.toInt()
    const val GLASS_STRONG = 0xB31B2023.toInt()

    // ---- Type (Material 3 baseline sizes, sp) ----
    class TextRole(val sizeSp: Float, val lineHeightSp: Float, val weight: Int)

    val DISPLAY_LARGE = TextRole(57f, 64f, 400)
    val DISPLAY_MEDIUM = TextRole(45f, 52f, 400)
    val DISPLAY_SMALL = TextRole(36f, 44f, 400)
    val HEADLINE_LARGE = TextRole(32f, 40f, 700)
    val HEADLINE_MEDIUM = TextRole(28f, 36f, 700)
    val HEADLINE_SMALL = TextRole(24f, 32f, 700)
    val TITLE_LARGE = TextRole(22f, 28f, 700)
    val TITLE_MEDIUM = TextRole(16f, 24f, 500)
    val TITLE_SMALL = TextRole(14f, 20f, 500)
    val BODY_LARGE = TextRole(16f, 24f, 400)
    val BODY_MEDIUM = TextRole(14f, 20f, 400)
    val BODY_SMALL = TextRole(12f, 16f, 400)
    val LABEL_LARGE = TextRole(14f, 20f, 500)
    val LABEL_MEDIUM = TextRole(12f, 16f, 500)
    val LABEL_SMALL = TextRole(11f, 16f, 500)

    // ---- Spacing (dp, 4 dp grid) ----
    const val SP_4 = 4
    const val SP_8 = 8
    const val SP_12 = 12
    const val SP_16 = 16
    const val SP_24 = 24
    const val SP_32 = 32
    const val SP_48 = 48
    val SPACING = intArrayOf(SP_4, SP_8, SP_12, SP_16, SP_24, SP_32, SP_48)

    // ---- Radii (dp) ----
    const val R_8 = 8
    const val R_12 = 12
    const val R_16 = 16
    const val R_24 = 24
    const val R_28 = 28
    const val R_PILL = 999

    // ---- Motion (ms) ----
    const val MOTION_FAST = 150L
    const val MOTION_MEDIUM = 250L
    const val MOTION_SLOW = 400L

    // ---- Touch ----
    const val TOUCH_TARGET = 48

    // ---- Contrast (WCAG 2.x) ----
    private fun channel(c: Int): Double {
        val v = c / 255.0
        return if (v <= 0.03928) v / 12.92 else Math.pow((v + 0.055) / 1.055, 2.4)
    }

    fun luminance(argb: Int): Double =
        0.2126 * channel((argb shr 16) and 0xFF) + 0.7152 * channel((argb shr 8) and 0xFF) + 0.0722 * channel(argb and 0xFF)

    fun contrast(fg: Int, bg: Int): Double {
        val a = luminance(fg)
        val b = luminance(bg)
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }
}
