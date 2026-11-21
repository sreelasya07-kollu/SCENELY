package dev.capturekit.results

import dev.capturekit.verdict.MiniJson

/**
 * Backend job status, mirror of roomscan-recon/spec/jobs/job_status.schema.json ("roomscan.job/1"). Pure: parsed by
 * the tiny reader in verdict/VerdictText.kt because org.json is stubbed in JVM unit tests. Unknown keys are ignored.
 * The app never computes a verdict; [verdict] comes from the server's job_report.json only.
 */
data class JobIssue(val code: String, val severity: String, val message: String)
data class JobValidation(val verdict: String, val issues: List<JobIssue>)
data class JobStage(val name: String, val status: String, val reason: String?, val where: String?)
data class RescanItem(val surface: String, val reason: String, val priority: Double, val areaM2: Double?, val instruction: String)
data class JobFile(val name: String, val kind: String, val url: String, val size: Long, val sha256: String)

data class JobStatus(
    val schema: String,
    val bundleId: String,
    val state: String,
    val created: String?,
    val updated: String?,
    val error: String?,
    val validation: JobValidation?,
    val stages: List<JobStage>,
    val verdict: String?,
    val rescan: List<RescanItem>,
    /** measurements.json verbatim (numbers are Double); null until the export stage has run. */
    val measurements: Map<String, Any?>?,
    val files: List<JobFile>,
) {
    /** The server is still working: poll again. */
    val isActive: Boolean get() = state == "queued" || state == "running"

    /** Highest priority first (stable for equal priority). */
    val rescanByPriority: List<RescanItem> get() = rescan.sortedByDescending { it.priority }

    fun file(kind: String): JobFile? = files.firstOrNull { it.kind == kind }

    fun stage(name: String): JobStage? = stages.firstOrNull { it.name == name }

    /** A numeric measurement, or null when absent or not a number. */
    fun measure(key: String): Double? = measurements?.get(key) as? Double

    companion object {
        /** Null when the text is not a roomscan.job/1 object; never throws. */
        @Suppress("UNCHECKED_CAST")
        fun parse(json: String): JobStatus? = try {
            val root = MiniJson(json).value() as? Map<String, Any?>
            val schema = root?.get("schema") as? String
            val id = root?.get("bundle_id") as? String
            if (root == null || schema == null || !schema.startsWith("roomscan.job/") || id == null) null
            else JobStatus(
                schema = schema,
                bundleId = id,
                state = root["state"] as? String ?: "queued",
                created = root["created"] as? String,
                updated = root["updated"] as? String,
                error = root["error"] as? String,
                validation = (root["validation"] as? Map<String, Any?>)?.let { v ->
                    JobValidation(v["verdict"] as? String ?: "", maps(v["issues"]).map {
                        JobIssue(it["code"] as? String ?: "", it["severity"] as? String ?: "", it["message"] as? String ?: "")
                    })
                },
                stages = maps(root["stages"]).map {
                    JobStage(it["name"] as? String ?: "", it["status"] as? String ?: "pending", it["reason"] as? String, it["where"] as? String)
                },
                verdict = root["verdict"] as? String,
                rescan = maps(root["rescan"]).map {
                    RescanItem(it["surface"] as? String ?: "", it["reason"] as? String ?: "", it["priority"] as? Double ?: 0.0,
                        it["area_m2"] as? Double, it["instruction"] as? String ?: "")
                },
                measurements = root["measurements"] as? Map<String, Any?>,
                files = maps(root["files"]).map {
                    JobFile(it["name"] as? String ?: "", it["kind"] as? String ?: "", it["url"] as? String ?: "",
                        (it["size"] as? Double)?.toLong() ?: 0L, it["sha256"] as? String ?: "")
                },
            )
        } catch (t: Throwable) { null }

        @Suppress("UNCHECKED_CAST")
        private fun maps(v: Any?): List<Map<String, Any?>> = (v as? List<Any?>).orEmpty().mapNotNull { it as? Map<String, Any?> }
    }
}
