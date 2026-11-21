package dev.capturekit.capture

/**
 * Feature switches (issue #6, ADR 0032; generalises the U11-A debug overrides). The default build shows only features
 * that passed on the phone (docs/DEVICE_TEST_LOG.md); everything else is OFF here and can be switched on in a
 * debuggable build only: `adb shell setprop debug.capturekit.<name> 1` (0 forces off), then force-stop the app
 * (the host reads the properties once per process). An unset, blank or junk value keeps the default.
 *  - `guidance`: navigation / progress prompts, live room card, weak-wall review sheet, review room drawing
 *  - `detector`: 2D detector, camera boxes chip, object labels, review "Found" counts (supersedes ADR 0030 "on")
 *  - `voice_commands`: push-to-talk mic chip, VoiceController, StateAnswers
 *  - `recalibrate_card`: the issue #1 recalibration card (the core keyframe pause always stays)
 *  - `segmentation`: live green object boxes with per-scan memory (ADR 0035; also needs the fetched RF-DETR-Seg model files)
 *  - `understanding 0|1|2`: core `guide.understanding` override (default 2 since ADR 0036, see [understandingFor])
 *  - `record_imu`: keep the IMU channels in the bundle (the Android app default is ON since ADR 0036; the core default is lean)
 * Precedence (ADR 0032 update): debug property > user setting ([PREF_KEYS], SharedPreferences "capturekit") > [Flags.DEFAULTS], see [resolve].
 * The core still records every instruction in /events; only display, speech and haptics are gated.
 */
object FeatureFlags {
    const val PROP_UNDERSTANDING = "debug.capturekit.understanding"
    const val PROP_DETECTOR = "debug.capturekit.detector"
    const val PROP_GUIDANCE = "debug.capturekit.guidance"
    const val PROP_VOICE_COMMANDS = "debug.capturekit.voice_commands"
    const val PROP_RECALIBRATE_CARD = "debug.capturekit.recalibrate_card"
    const val PROP_SEGMENTATION = "debug.capturekit.segmentation"
    const val PROP_RECORD_IMU = "debug.capturekit.record_imu"

    /** Understanding level of a guided scan when no property overrides it (ADR 0036): objects + gaps (the gaps feed the completeness card; steering lines stay hidden while guidance is off). */
    const val DEFAULT_UNDERSTANDING = 2

    /** User settings keys (SharedPreferences "capturekit", Boolean; contract C4). */
    const val PREF_GUIDANCE = "ck.guidance"
    const val PREF_VOICE_COMMANDS = "ck.voice_commands"
    const val PREF_RECALIBRATE_CARD = "ck.recalibrate_card"
    const val PREF_RECORD_IMU = "ck.record_imu"
    const val PREF_OBJECT_BOXES = "ck.object_boxes"
    val PREF_KEYS: List<String> = listOf(PREF_GUIDANCE, PREF_VOICE_COMMANDS, PREF_RECALIBRATE_CARD, PREF_RECORD_IMU, PREF_OBJECT_BOXES)

    /**
     * Instruction types shown/spoken/felt with guidance OFF: the safety and tracking prompts (core InstrType SlowDown,
     * HoldStill, Relocalize, MoreLight, AimTextured, Recalibrate). Every other type (navigation, Progress, Finish) is guidance.
     */
    val SAFETY_INSTRUCTIONS: Set<String> = setOf("SLOW_DOWN", "HOLD_STILL", "RELOCALIZE", "MORE_LIGHT", "AIM_TEXTURED", "RECALIBRATE")

    /** Resolved switches for one process. [DEFAULTS] = release build or no property set. */
    data class Flags(
        val understanding: Int? = null,
        val detector: Boolean = false,
        val guidance: Boolean = false,
        val voiceCommands: Boolean = false,
        val recalibrateCard: Boolean = false,
        /** Live object boxes + memory (ADR 0035). Needs the fetched model files, otherwise it stays off by itself. */
        val segmentation: Boolean = true,
        /** Keep /imu/gyro and /imu/accel in the bundle (ADR 0034; app default ON since ADR 0036). Off = the lean bundle. */
        val recordImu: Boolean = true,
    ) {
        companion object { val DEFAULTS = Flags() }
    }

    /** "1" = on, "0" = off (surrounding whitespace ignored); anything else (unset, blank, junk) keeps [default]. */
    fun switchOn(raw: String?, default: Boolean): Boolean = when (raw?.trim()) {
        "1" -> true
        "0" -> false
        else -> default
    }

    /** Flags from property values ([get] returns the raw value or null). Call only in a debuggable build. */
    fun fromProps(get: (String) -> String?): Flags {
        val d = Flags.DEFAULTS
        return Flags(
            understanding = understandingLevel(get(PROP_UNDERSTANDING)),
            detector = detectorOn(get(PROP_DETECTOR)),
            guidance = switchOn(get(PROP_GUIDANCE), d.guidance),
            voiceCommands = switchOn(get(PROP_VOICE_COMMANDS), d.voiceCommands),
            recalibrateCard = switchOn(get(PROP_RECALIBRATE_CARD), d.recalibrateCard),
            segmentation = switchOn(get(PROP_SEGMENTATION), d.segmentation),
            recordImu = switchOn(get(PROP_RECORD_IMU), d.recordImu),
        )
    }

    /**
     * Flags with the full precedence (ADR 0032 update): debug property ([props], exact "1"/"0") > user setting ([prefs],
     * null = never set) > [Flags.DEFAULTS]. Pure; a release build passes `props = { null }`. `detector` and `understanding`
     * have no user setting (property only).
     */
    fun resolve(props: (String) -> String?, prefs: (String) -> Boolean?): Flags {
        val d = Flags.DEFAULTS
        fun sw(prop: String, pref: String, def: Boolean) = switchOn(props(prop), prefs(pref) ?: def)
        return Flags(
            understanding = understandingLevel(props(PROP_UNDERSTANDING)),
            detector = detectorOn(props(PROP_DETECTOR)),
            guidance = sw(PROP_GUIDANCE, PREF_GUIDANCE, d.guidance),
            voiceCommands = sw(PROP_VOICE_COMMANDS, PREF_VOICE_COMMANDS, d.voiceCommands),
            recalibrateCard = sw(PROP_RECALIBRATE_CARD, PREF_RECALIBRATE_CARD, d.recalibrateCard),
            segmentation = sw(PROP_SEGMENTATION, PREF_OBJECT_BOXES, d.segmentation),
            recordImu = sw(PROP_RECORD_IMU, PREF_RECORD_IMU, d.recordImu),
        )
    }

    /** Property prefix of every switch; [parseGetprop] keeps only these. */
    const val PROP_PREFIX = "debug.capturekit."

    /**
     * Output of one argument-less `getprop` call ("[name]: [value]" per line) -> the `debug.capturekit.*` entries.
     * Malformed lines are skipped; a repeated name keeps the last value.
     */
    fun parseGetprop(output: String): Map<String, String> {
        val m = HashMap<String, String>()
        for (line in output.lineSequence()) {
            val r = GETPROP_LINE.matchEntire(line.trim()) ?: continue
            val name = r.groupValues[1]
            if (name.startsWith(PROP_PREFIX)) m[name] = r.groupValues[2]
        }
        return m
    }
    private val GETPROP_LINE = Regex("""\[([^\]]+)\]:\s*\[(.*)\]""")

    /**
     * Coaching-line rule for the latest shown instruction (ADR 0032). With [guidance] on it stays until the next one
     * (unchanged behaviour). With guidance off only safety prompts arrive and nothing would replace them, so a prompt
     * is shown for [holdMs] after it arrived, then the screen falls back to the plain scan prompt; a RECALIBRATE prompt
     * stays while the core is still recovering ([recalibrating]).
     */
    fun instructionStillShown(text: String, arrivedMs: Long, nowMs: Long, guidance: Boolean, recalibrating: Boolean,
                              holdMs: Long = PROMPT_HOLD_MS): Boolean =
        text.isNotEmpty() && (guidance || recalibrating || nowMs - arrivedMs < holdMs)

    /** How long a safety prompt stays on the coaching line with guidance off (guess; tune on device). */
    const val PROMPT_HOLD_MS = 4_000L

    /** 0 = off, 1 = objects, 2 = objects + gap steering (core `guide.understanding`); null = property unset / blank / junk / out of range. */
    fun understandingLevel(raw: String?): Int? = raw?.trim()?.toIntOrNull()?.takeIf { it in 0..2 }

    /** The detector is off unless the property is exactly "1" (ADR 0032; it still needs the packaged model). */
    fun detectorOn(raw: String?): Boolean = switchOn(raw, Flags.DEFAULTS.detector)

    /** Show / speak / vibrate an instruction of core [type]: always with [guidance], else only the [SAFETY_INSTRUCTIONS]. */
    fun showInstruction(type: String, guidance: Boolean): Boolean = guidance || type in SAFETY_INSTRUCTIONS

    /**
     * Understanding level to pass: the [override] when set (including 0), else [DEFAULT_UNDERSTANDING] when [guidedScan]
     * (everything but the unguided research control arm), else null (no key: the core default, off).
     */
    fun understandingFor(override: Int?, guidedScan: Boolean): Int? =
        override ?: if (guidedScan) DEFAULT_UNDERSTANDING else null

    /**
     * Extra session config for [SessionManager.start]: `guide.understanding` is passed explicitly whenever a level is
     * given (including 0), null = no key; `record_imu` = 1 only when [recordImu] (the core default is lean: no IMU, so the app asks for it).
     */
    fun extraConfig(understanding: Int?, recordImu: Boolean = false): Map<String, Any> =
        buildMap {
            if (understanding != null && understanding in 0..2) put("guide.understanding", understanding)
            if (recordImu) put("record_imu", 1)
        }
}
