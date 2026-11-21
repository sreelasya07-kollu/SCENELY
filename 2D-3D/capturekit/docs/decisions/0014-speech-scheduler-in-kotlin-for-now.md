# 0014: SpeechScheduler lives in Kotlin for now, not in the C++ core

Status: accepted (2026-11-16). Phase 10 build 1 asks for a C++ SpeechScheduler whose output is recorded in the guidance log.
Android shipped it as pure Kotlin (`android/capturekit/.../guidance/SpeechScheduler.kt`, ac76a25): no Android types, time passed in,
budget/cooldowns from a Kotlin Config data class (defaults in code, not session config keys), unit-tested. Consequence: spoken prompts are NOT in the guidance log, and iOS must port it.
Text still comes only from core templates; the scheduler only decides whether/when to speak. Revisit before the iOS voice work:
either move the logic into the core (C API returns an utterance plan, logged) or port it to Swift and log prompts from both shells.
