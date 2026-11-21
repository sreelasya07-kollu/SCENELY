package dev.capturekit.sample.results

import dev.capturekit.sample.BuildConfig
import java.io.FileNotFoundException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Field flavour only (needs BuildConfig.JOBS_URL and the INTERNET permission). Talks to the roomscan-recon job
 * server over plain HttpURLConnection. Blocking: call from a worker thread. Same API as the standard stub.
 */
object ResultsGate {
    val available: Boolean get() = BuildConfig.JOBS_URL.isNotBlank()

    private val base: String get() = BuildConfig.JOBS_URL.trimEnd('/')

    /** Absolute URL for a server-relative path such as "/jobs/<id>/files/x"; absolute URLs pass through. */
    fun absoluteUrl(rel: String): String? {
        if (rel.startsWith("http://") || rel.startsWith("https://")) return if (rel.startsWith("$base/")) rel else null
        return base + (if (rel.startsWith("/")) rel else "/$rel")
    }

    private fun seg(id: String): String = URLEncoder.encode(id, "UTF-8").replace("+", "%20")

    /** GET /jobs/<id>; on 404 asks the server to start the job (POST /jobs, idempotent) and reads it again. */
    fun status(bundleId: String): Fetched {
        if (!available) return Fetched(null, "The results server is not set up in this build.")
        return try {
            val first = try { get("$base/jobs/${seg(bundleId)}") } catch (e: FileNotFoundException) { null }
            if (first != null) return Fetched(first, null)
            post("$base/jobs", """{"bundle_id":"${bundleId.replace("\\", "\\\\").replace("\"", "\\\"")}"}""")
            Fetched(get("$base/jobs/${seg(bundleId)}"), null)
        } catch (e: FileNotFoundException) {
            Fetched(null, "The server does not know this scan yet. Upload it first.")
        } catch (e: java.io.IOException) {
            Fetched(null, "Could not reach the results server.")
        } catch (t: Throwable) {
            Fetched(null, "Could not load the results.")
        }
    }

    /** Fetches a text file (for example the floor plan SVG) from a server-relative or absolute URL. */
    fun fetchText(rel: String): Fetched = try {
        Fetched(get(absoluteUrl(rel) ?: return Fetched(null, "That file is not on the results server.")), null)
    } catch (t: Throwable) { Fetched(null, "Could not load the file.") }

    private fun open(url: String, method: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply { connectTimeout = 10_000; readTimeout = 20_000; requestMethod = method }

    private fun get(url: String): String {
        val c = open(url, "GET")
        try { return c.inputStream.use { it.readBytes().decodeToString() } } finally { c.disconnect() }
    }

    private fun post(url: String, body: String) {
        val c = open(url, "POST")
        try {
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.outputStream.use { it.write(body.toByteArray()) }
            c.inputStream.use { it.readBytes() }
        } finally { c.disconnect() }
    }
}
