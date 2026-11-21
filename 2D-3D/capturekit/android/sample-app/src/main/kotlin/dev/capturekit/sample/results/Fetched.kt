package dev.capturekit.sample.results

/** Result of a [ResultsGate] call: [text] on success, otherwise a short plain-language [error]. Never thrown. */
data class Fetched(val text: String?, val error: String?)
