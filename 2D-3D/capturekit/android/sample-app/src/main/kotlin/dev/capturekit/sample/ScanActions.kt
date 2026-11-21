package dev.capturekit.sample

import dev.capturekit.guidance.ScanStateSnapshot
import dev.capturekit.guidance.StateAnswers
import dev.capturekit.guidance.VoiceIntent

/**
 * The one code path of every in-scan action that is not Start / Finish (ADR 0036): the HUD buttons and the voice commands
 * ([VoiceController.act]) both call [run], so a button and a spoken command do exactly the same and say the same. Finish is
 * the explicit Finish button; by voice it first asks for a yes/no confirmation (VoiceController) and then takes the same
 * [CaptureActivity] finish path. Main thread only.
 */
class ScanActions(private val speech: SpeechRenderer, private val host: Host) {
    /** The scan screen's side. */
    interface Host {
        fun isPaused(): Boolean
        fun pauseScan()
        fun resumeScan()
        fun snapshot(): ScanStateSnapshot?
    }

    enum class Kind { PAUSE, RESUME, REPEAT, MISSING, LOUDER, QUIETER }

    /** What to show: [text] for [ms] on the feedback line (null = nothing to show). */
    class Outcome(val text: String?, val ms: Long)

    fun run(kind: Kind): Outcome = when (kind) {
        Kind.PAUSE -> if (host.isPaused()) Outcome("Already paused.", 3_000) else { host.pauseScan(); Outcome("Paused.", 3_000) }
        Kind.RESUME -> if (!host.isPaused()) Outcome("Already scanning.", 3_000) else { host.resumeScan(); Outcome("Resuming.", 3_000) }
        Kind.REPEAT ->
            if (speech.repeatLast()) Outcome(null, 0)
            else Outcome(if (!speech.enabled) "Voice guidance is off. Turn it on to hear it again." else "Nothing to repeat yet.", 4_000)
        Kind.MISSING -> {
            val a = StateAnswers.answer(StateAnswers.questionFor(VoiceIntent.MISSING), host.snapshot())
            speech.say(a.text)
            Outcome(a.text, 9_000)   // always visible, also when voice guidance is muted
        }
        Kind.LOUDER -> volume(speech.louder(), "Louder.", "Already at the loudest.")
        Kind.QUIETER -> volume(speech.quieter(), "Quieter.", "Already at the quietest.")
    }

    private fun volume(changed: Boolean, done: String, limit: String): Outcome {
        val msg = if (changed) done else limit
        speech.say(msg, remember = false)   // spoken at the new level so the change is audible
        return Outcome(msg, 3_000)
    }

    companion object {
        /** Voice intent -> action; null for FINISH (confirmed first, then the Finish path). */
        fun kindOf(i: VoiceIntent): Kind? = when (i) {
            VoiceIntent.PAUSE -> Kind.PAUSE
            VoiceIntent.RESUME -> Kind.RESUME
            VoiceIntent.REPEAT -> Kind.REPEAT
            VoiceIntent.MISSING -> Kind.MISSING
            VoiceIntent.LOUDER -> Kind.LOUDER
            VoiceIntent.QUIETER -> Kind.QUIETER
            VoiceIntent.FINISH -> null
        }
    }
}
