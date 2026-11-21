package dev.capturekit.segment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SegmentationSchedulerTest {
    private val posted = ArrayDeque<Runnable>()
    private val results = ArrayList<SegResult>()
    private val logs = ArrayList<String>()

    private fun runAll() { while (posted.isNotEmpty()) posted.removeFirst().run() }

    private val chairInstance = Instance(62, "chair", 0.9f, Box2(1f, 1f, 3f, 3f), 2f, 2f)

    /** Fake model: one chair per run, or null when [fail]. */
    private class FakeSegmenter(var fail: Boolean = false, val found: List<Instance>) : Segmenter {
        override val name = "fake"
        var runs = 0
        var closed = false
        var during: (() -> Unit)? = null
        override fun segment(image: SegImage, quarterTurns: Int): List<Instance>? {
            runs++
            during?.invoke()
            return if (fail) null else found
        }
        override fun close() { closed = true }
    }
    private fun fake(fail: Boolean = false) = FakeSegmenter(fail, listOf(chairInstance))

    private var disabledCalls = 0

    private fun scheduler(seg: Segmenter?, interval: Long = 200_000_000L) = SegmentationScheduler(
        open = { seg }, sink = { results.add(it) }, minIntervalNs = interval,
        post = { posted.addLast(it) }, log = { m, _ -> logs.add(m) }, onDisabled = { disabledCalls++ },
    )

    private val cam = CameraSnapshot(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 100.0, 100.0, 2.0, 2.0, 4, 4)
    private val img = SegImage(4, 4, ByteArray(16), 4, ByteArray(8), ByteArray(8), 4, 2)
    private fun job(t: Long) = SegJob(t, img, cam, 0)

    @Test fun busyDropsTheNewJobAndCountsIt() {
        val s = scheduler(fake())
        assertTrue(s.submit(job(0)))
        assertFalse(s.submit(job(1)))                   // one in flight (queue size 1): dropped
        assertEquals(1L, s.dropped)
        assertEquals(1, logs.count { it.contains("drop") })
        runAll()
        assertEquals(1L, s.processed)
        assertEquals(1, results.size)
        assertEquals(0L, results[0].tNs)                // the first job ran, the newer one was dropped
        assertTrue(s.submit(job(2)))                    // idle again: accepted
        runAll()
        assertEquals(2L, s.processed)
        assertEquals(1L, s.dropped)
    }

    @Test fun submitWhileTheModelRunsIsDropped() {
        val seg = fake()
        val s = scheduler(seg)
        var inner = true
        seg.during = { inner = s.submit(job(9)) }
        assertTrue(s.submit(job(0)))
        runAll()
        assertFalse(inner)
        assertEquals(1L, s.dropped)
        assertEquals(1, seg.runs)
    }

    @Test fun captureGateIsAtMostFiveHertzAndCountsBusyAsDrop() {
        assertEquals(200_000_000L, SegmentationScheduler.DEFAULT_INTERVAL_NS)
        val s = scheduler(fake())
        assertTrue(s.shouldCapture(0L))
        assertFalse(s.shouldCapture(100_000_000L))      // interval not over: not a drop
        assertEquals(0L, s.dropped)
        assertTrue(s.submit(job(0L)))
        assertFalse(s.shouldCapture(300_000_000L))      // due but busy: dropped and counted
        assertEquals(1L, s.dropped)
        runAll()
        assertFalse(s.shouldCapture(400_000_000L))      // the busy drop restarted the interval
        assertTrue(s.shouldCapture(600_000_000L))
        assertFalse(s.shouldCapture(2_000_000_000L, trackingNormal = false))
        assertFalse(s.shouldCapture(3_000_000_000L, mlRateScale = 0.0))
        assertTrue(s.shouldCapture(4_000_000_000L, mlRateScale = 0.5))
        assertFalse(s.shouldCapture(4_300_000_000L, mlRateScale = 0.5))   // thermal scale 0.5 -> 400 ms interval
    }

    @Test fun resultsCarryTheJobCameraAndTheInstances() {
        val s = scheduler(fake())
        s.submit(job(7)); runAll()
        assertEquals(7L, results[0].tNs)
        assertTrue(results[0].camera === cam)
        assertEquals("chair", results[0].instances.single().label)
    }

    @Test fun anEmptyRunStillDeliversSoTheBoxesAgeOut() {
        val s = scheduler(FakeSegmenter(found = emptyList()))
        s.submit(job(0)); runAll()
        assertEquals(1, results.size)
        assertTrue(results[0].instances.isEmpty())
    }

    @Test fun repeatedFailuresDisableTheWorker() {
        val s = scheduler(fake(fail = true))
        repeat(SegmentationScheduler.GIVE_UP_AFTER - 1) { assertTrue(s.submit(job(it.toLong()))); runAll() }
        assertEquals(0, disabledCalls)
        assertTrue(s.submit(job(50))); runAll()
        assertTrue(s.disabled)
        assertEquals(1, disabledCalls)                   // the host is told exactly once
        assertEquals(SegmentationScheduler.GIVE_UP_AFTER.toLong(), s.failures)
        assertFalse(s.submit(job(99)))
        assertFalse(s.shouldCapture(10_000_000_000L))
        assertTrue(results.isEmpty())
    }

    @Test fun missingModelOrGpuTurnsTheFeatureOffWithoutACpuFallback() {
        val s = scheduler(null)
        assertTrue(s.submit(job(0)))
        runAll()
        assertTrue(s.disabled)
        assertEquals(1, disabledCalls)
        assertTrue(results.isEmpty())
        assertTrue(logs.any { it.contains("not available") })
    }

    @Test fun closeReleasesTheModelOnTheWorker() {
        val seg = fake()
        val s = scheduler(seg)
        s.submit(job(0)); runAll()
        s.close()
        assertFalse(seg.closed)                          // released on the worker thread, not the caller's
        runAll()
        assertTrue(seg.closed)
        assertFalse(s.submit(job(1)))
    }
}
