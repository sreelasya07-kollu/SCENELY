package dev.capturekit.sample

import org.junit.Assert.assertTrue
import org.junit.Test

class DesignTokensTest {
    private val t = DesignTokens
    private val surfaces = intArrayOf(t.BG, t.SURFACE_1, t.SURFACE_2, t.SURFACE_3)

    @Test fun textContrastOnSurfaces() {
        for (s in surfaces) {
            assertTrue("muted on ${s.toString(16)}", t.contrast(t.ON_SURFACE_MUTED, s) >= 4.5)
            assertTrue("onSurface on ${s.toString(16)}", t.contrast(t.ON_SURFACE, s) >= 4.5)
            assertTrue("onSurfaceVariant on ${s.toString(16)}", t.contrast(t.ON_SURFACE_VARIANT, s) >= 4.5)
        }
    }

    @Test fun accentContrast() {
        for (s in surfaces) assertTrue("accent on ${s.toString(16)}", t.contrast(t.ACCENT, s) >= 3.0)
        assertTrue("onAccent on accent", t.contrast(t.ON_ACCENT, t.ACCENT) >= 4.5)
        assertTrue("onAccentContainer on accentContainer", t.contrast(t.ON_ACCENT_CONTAINER, t.ACCENT_CONTAINER) >= 4.5)
    }

    @Test fun statusContrastOnBackground() {
        for (c in intArrayOf(t.SUCCESS, t.WARNING, t.ERROR)) assertTrue(t.contrast(c, t.BG) >= 3.0)
    }

    @Test fun spacingOnFourDpGrid() {
        for (s in t.SPACING) assertTrue("spacing $s", s % 4 == 0)
        assertTrue(t.TOUCH_TARGET % 4 == 0)
    }

    @Test fun typeScaleIsM3() {
        assertTrue(t.TITLE_LARGE.sizeSp == 22f && t.BODY_MEDIUM.sizeSp == 14f && t.LABEL_SMALL.sizeSp == 11f)
        assertTrue(t.TITLE_LARGE.lineHeightSp >= t.TITLE_LARGE.sizeSp)
    }
}
