package dev.capturekit.sample

import android.app.Activity
import android.app.Dialog
import android.os.Build
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import dev.capturekit.capture.CoreEvent
import dev.capturekit.guidance.Completeness
import dev.capturekit.guidance.ObjectSummary
import dev.capturekit.guidance.ScanStateSnapshot
import dev.capturekit.sample.UiKit.dp

/**
 * Review-before-finish sheet. Shown after the core is paused and before finalize: the completeness % and the weak zones
 * (ADR 0035), plus the weak walls, with "Scan the gaps" (resume the same bundle) and "Finish anyway".
 * Wall names are "Wall N": N = the core's stable wall id (overlay v3, same names as the voice answers) or, for an older
 * core, the 1-based position in the last snapshot's surfaces. Only evidenced walls count (see
 * [ScanStateSnapshot.evidencedWalls]): hypothesised outline sides, plane-less inferred walls and walls entirely hidden
 * behind furniture are never called weak, so the sheet can always clear.
 */
object ReviewSheet {
    /** Walls below this percentage are called weak (guess until Gate 0 data; the scanning band starts at 20). */
    const val WEAK_PCT = 50

    /** Wall numbers (core ids on a v3 core) whose coverage is below [threshold]. */
    fun weakWalls(o: CoreEvent.Overlay?, threshold: Int = WEAK_PCT): List<Int> {
        if (o == null) return emptyList()
        if (!o.layoutV3) return o.surfaces.withIndex().filter { it.value.pct < threshold }.map { it.index + 1 }
        return ScanStateSnapshot.evidencedWalls(o).filter { it.pct < threshold }.map { it.id }
    }

    /** Nothing of the room captured: no snapshot at all, or no floor and no wall seen. */
    fun nothingFound(o: CoreEvent.Overlay?): Boolean = o == null || (!o.floorFound && o.walls == 0 && o.surfaces.isEmpty())

    /**
     * The sheet is skipped (finish straight away) only when something was captured and no wall is weak. With
     * [guidance] off (ADR 0032) the weak-wall part is gated: only the empty-scan notice remains.
     */
    fun needed(o: CoreEvent.Overlay?, guidance: Boolean): Boolean = nothingFound(o) || (guidance && weakWalls(o).isNotEmpty())

    /**
     * [guidance] off: minimal empty-scan notice (title, one line, the two buttons); no checklist or walls.
     * The "Found" line needs [detector] (ADR 0032), as on the Review screen.
     */
    fun show(act: Activity, o: CoreEvent.Overlay?, guidance: Boolean, detector: Boolean, summary: Completeness.Summary,
             onGaps: () -> Unit, onFinish: () -> Unit): Dialog {
        val weak = if (guidance) weakWalls(o) else emptyList()
        val empty = nothingFound(o)
        val gapsText = if (empty) "Nothing of the room was captured yet." else if (weak.isEmpty()) "All evidenced walls meet coverage targets." else
            "Needs more scanning: " + weak.joinToString(", ") { "Wall $it" } + "."
        val found = if (!detector) "" else o?.let { ObjectSummary.text(it.objects, it.openings) }.orEmpty()   // issue #2 D: what was recognised so far
        val wrap = ViewGroup.LayoutParams.WRAP_CONTENT
        val match = ViewGroup.LayoutParams.MATCH_PARENT
        var dlg: Dialog? = null

        // Completeness ring beside the headline numbers; the text carries the whole message for screen readers.
        val summaryRow = LinearLayout(act).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            val ring = UiKit.progressRing(act).apply {
                setProgress(summary.completenessPct / 100f)
                accent = if (empty || weak.isNotEmpty()) UiKit.AMBER else UiKit.ACCENT
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            addView(ring, LinearLayout.LayoutParams(wrap, wrap).apply { rightMargin = act.dp(DesignTokens.SP_16) })
            addView(LinearLayout(act).apply {
                orientation = LinearLayout.VERTICAL
                contentDescription = "Complete ${summary.completenessPct} percent. $gapsText"
                addView(UiKit.role(act, "Complete: ${summary.completenessPct}%", DesignTokens.TITLE_MEDIUM))
                addView(UiKit.role(act, gapsText, DesignTokens.BODY_MEDIUM, if (empty || weak.isNotEmpty()) UiKit.AMBER else UiKit.LABEL_2),
                    LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = act.dp(DesignTokens.SP_4) })
            }, LinearLayout.LayoutParams(0, wrap, 1f))
        }

        fun noteRow(icon: Int, tint: Int, text: String) = LinearLayout(act).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(UiKit.iconImage(act, icon, tint), LinearLayout.LayoutParams(act.dp(16), act.dp(16)).apply { rightMargin = act.dp(DesignTokens.SP_12) })
            addView(UiKit.role(act, text, DesignTokens.BODY_MEDIUM, UiKit.LABEL_2), LinearLayout.LayoutParams(0, wrap, 1f))
        }

        val body = LinearLayout(act).apply {
            orientation = LinearLayout.VERTICAL
            addView(summaryRow)
            for (z in summary.weakZones.take(5)) addView(noteRow(R.drawable.ic_warning, UiKit.AMBER, z.text),
                LinearLayout.LayoutParams(match, wrap).apply { topMargin = act.dp(DesignTokens.SP_12) })
            if (found.isNotEmpty()) addView(noteRow(R.drawable.ic_boxes, UiKit.ACCENT, "Found: $found."),
                LinearLayout.LayoutParams(match, wrap).apply { topMargin = act.dp(DesignTokens.SP_12) })
        }

        val buttons = LinearLayout(act).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            addView(UiKit.secondaryButton(act, "Finish anyway").apply {
                setOnClickListener { dlg?.dismiss(); onFinish() }
            }, LinearLayout.LayoutParams(0, wrap, 1f))
            addView(UiKit.bigButton(act, if (empty) "Keep scanning" else "Scan the gaps").apply {
                setOnClickListener { UiKit.haptic(this, true); dlg?.dismiss(); onGaps() }
            }, LinearLayout.LayoutParams(0, wrap, 1.4f).apply { marginStart = act.dp(DesignTokens.SP_12) })
        }

        val content = LinearLayout(act).apply {
            orientation = LinearLayout.VERTICAL
            addView(UiKit.role(act, "Before you finish", DesignTokens.HEADLINE_SMALL).apply {
                if (Build.VERSION.SDK_INT >= 28) isAccessibilityHeading = true
            }, LinearLayout.LayoutParams(match, wrap).apply { bottomMargin = act.dp(DesignTokens.SP_16) })
            // Landscape is short: the body scrolls while the two buttons stay in view.
            addView(ScrollView(act).apply { isVerticalScrollBarEnabled = false; addView(body) }, LinearLayout.LayoutParams(match, 0, 1f))
            addView(buttons, LinearLayout.LayoutParams(match, wrap).apply { topMargin = act.dp(DesignTokens.SP_24) })
        }

        // The scan is paused: the only ways out are the two buttons, so the sheet is not cancelable.
        val sheet = UiKit.sheet(act, content, cancelable = false)
        dlg = sheet
        sheet.show()
        return sheet
    }
}
