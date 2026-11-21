package dev.capturekit.sample.results

/** Standard flavour: offline build (INTERNET is stripped from the manifest), so there is no results screen. Same API as field. */
@Suppress("UNUSED_PARAMETER")
object ResultsGate {
    val available: Boolean get() = false
    fun absoluteUrl(rel: String): String? = null
    fun status(bundleId: String): Fetched = Fetched(null, "Results are not available in this build.")
    fun fetchText(rel: String): Fetched = Fetched(null, "Results are not available in this build.")
}
