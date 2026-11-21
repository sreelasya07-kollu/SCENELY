package dev.capturekit.results

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JobStatusTest {
    private fun example(): String =
        javaClass.getResourceAsStream("/results/example_job.json")!!.readBytes().toString(Charsets.UTF_8)

    @Test fun parsesTheContractExample() {
        val j = JobStatus.parse(example())
        assertNotNull(j); j!!
        assertEquals("roomscan.job/1", j.schema)
        assertEquals("example-bundle-0001", j.bundleId)
        assertEquals("done", j.state); assertFalse(j.isActive)
        assertNull(j.error)
        assertEquals("WARN", j.validation!!.verdict); assertEquals("POSE_GAP", j.validation!!.issues[0].code)
        assertEquals(7, j.stages.size)
        assertEquals("failed", j.stage("recon")!!.status)
        assertEquals("pending", j.stage("splat")!!.status); assertEquals("gpu_worker", j.stage("splat")!!.where)
        assertEquals("needs_rescan", j.verdict)
        assertEquals(12.5, j.measure("floor_area_m2")!!, 1e-9)
        assertEquals(2.55, j.measure("ceiling_height_m")!!, 1e-9)
        assertNull(j.measure("wall_lengths_m"))
        assertEquals(7, j.files.size)
        assertEquals("/jobs/example-bundle-0001/files/export/floorplan.svg", j.file("floorplan_svg")!!.url)
        assertEquals(150000000L, j.file("spatial_map_zip")!!.size)
        assertNull(j.file("splat_ply"))
    }

    @Test fun rescanSortedByPriorityDescending() {
        val j = JobStatus.parse(example())!!
        assertEquals(listOf("wall", "ceiling"), j.rescanByPriority.map { it.surface })
        assertEquals(3.2, j.rescan[0].areaM2!!, 1e-9)
    }

    @Test fun unknownKeysIgnoredAndMissingOptionalsTolerated() {
        val j = JobStatus.parse("""{"schema":"roomscan.job/1","bundle_id":"b","state":"running","extra":{"x":[1,2]},"stages":[{"name":"validate","status":"running","new":1}]}""")!!
        assertTrue(j.isActive); assertNull(j.verdict); assertNull(j.measurements); assertTrue(j.files.isEmpty()); assertTrue(j.rescan.isEmpty())
        assertEquals("running", j.stage("validate")!!.status)
    }

    @Test fun rejectsGarbageAndForeignJson() {
        assertNull(JobStatus.parse(""))
        assertNull(JobStatus.parse("not json"))
        assertNull(JobStatus.parse("[1,2]"))
        assertNull(JobStatus.parse("""{"bundle_id":"b"}"""))
        assertNull(JobStatus.parse("""{"schema":"other/1","bundle_id":"b"}"""))
        assertNull(JobStatus.parse("""{"schema":"roomscan.job/1","bundle_id":"b","state":"""))
    }
}
