package dev.capturekit.sample

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import dev.capturekit.capture.ARAdapter
import dev.capturekit.capture.CalibrationCard
import dev.capturekit.capture.CalibrationUi
import dev.capturekit.capture.StillnessCalibrator
import dev.capturekit.capture.StillnessSensors
import dev.capturekit.capture.CoreEvent
import dev.capturekit.capture.DetectedBox
import dev.capturekit.capture.LiteRtKeyframeDetector
import dev.capturekit.capture.Policy
import dev.capturekit.capture.SensorBridge
import dev.capturekit.capture.SessionManager
import dev.capturekit.guidance.Completeness
import dev.capturekit.guidance.Recalibration
import dev.capturekit.guidance.ScanStateSnapshot
import dev.capturekit.nativebridge.Status
import dev.capturekit.platform.PlatformSignals
import dev.capturekit.platform.ThermalAdapter
import dev.capturekit.capture.FeatureFlags
import dev.capturekit.sample.research.ResearchLog
import dev.capturekit.segment.SegmentationFeed
import dev.capturekit.segment.SegmentationScheduler
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Guided scan screen: a real core session (quality, keyframe selection, governor, guidance) over the live
 * camera image with a friendly HUD. Features not yet verified on a device are switched off by [FeatureFlags]
 * (ADR 0032; debug builds can switch them on): with `detector` on, the 2D detector labels keyframes for the core, which lifts
 * them to the labelled objects of the review screen; with `segmentation` on (default, ADR 0035; needs the fetched model) live
 * green object boxes with per-scan memory follow the camera ([ObjectBoxOverlayView], "Boxes" chip; never saved). Core instructions (only safety/tracking ones unless `guidance` is on) are shown (speak_text as coaching,
 * long_text as subtitle), spoken verbatim by [SpeechRenderer] and mapped to haptics. Finish hands over to [ReviewActivity].
 * Bundles land in getExternalFilesDir("bundles"); interrupted sessions are recovered on the next launch.
 * Pull with: adb pull /sdcard/Android/data/dev.capturekit.sample/files/bundles
 */
class CaptureActivity : Activity(), SessionManager.Listener {
    private lateinit var ar: ArHost
    private lateinit var hud: Hud
    private lateinit var objectView: ObjectBoxOverlayView
    /** Live segmentation for this scan; null when the flag is off, the model is missing, or not scanning. */
    private var segmentation: SegmentationScheduler? = null
    @Volatile private var segFeed: SegmentationFeed? = null   // read on the GL and core event threads
    private lateinit var speech: SpeechRenderer
    /** Null when voice commands are switched off (ADR 0032): no recognizer, no mic permission request. */
    private var voice: VoiceController? = null
    private lateinit var research: ResearchLog
    private var session: SessionManager? = null
    @Volatile private var adapter: ARAdapter? = null
    @Volatile private var arActive = true
    private var sensors: SensorBridge? = null
    private var thermal: ThermalAdapter? = null
    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var lastQuality = -1.0
    @Volatile private var lastReasons: List<String> = emptyList()
    @Volatile private var lastPolicy: Policy? = null
    @Volatile private var keyframes = 0
    @Volatile private var lastGovernor = "-"
    @Volatile private var instruction = ""
    @Volatile private var instructionLong = ""
    @Volatile private var instructionType = ""
    /** elapsedRealtime when [instruction] arrived: with guidance off a safety prompt expires (FeatureFlags.instructionStillShown). */
    @Volatile private var instructionAtMs = 0L
    /** Issue #1 / ADR 0031: tracking recalibration prompt (immutable; replaced on the core event thread, read on the UI thread). */
    @Volatile private var recal = Recalibration()
    /**
     * Guards the read-modify-write updates of [recal] and of the instruction fields: the core event thread and the UI
     * thread (scan start / finish) both write them, so a late event must not overwrite a reset. Reads stay lock-free.
     */
    private val recalLock = Any()
    @Volatile private var overlay: CoreEvent.Overlay? = null
    @Volatile private var trackState = "?"
    @Volatile private var trackFailure = "NONE"
    @Volatile private var corePaused = false
    /** This scan lifts detections to objects (detector running AND understanding >= 1): the review may say "none found". */
    private var objectsExpected = false
    private var recStartMs = 0L
    private var pausedAtMs = 0L
    private var pausedTotalMs = 0L
    @Volatile private var recording = false   // also read on the detector thread (onDetections)
    @Volatile private var finishing = false
    private var reviewDialog: android.app.Dialog? = null
    private var arMessage: String? = null
    private var recovering = true
    /** Pre-scan hold-still calibration (ADR 0036): runs from onResume until READY; its frozen result goes into the session config. */
    private var calib: StillnessCalibrator? = null
    private var calibSensors: StillnessSensors? = null
    private var calibResult: StillnessCalibrator.Result? = null
    private var calibNoSensors = false
    private var recoveredNote: String? = null

    /** What the action buttons AND the voice commands may do on this screen (main thread only): one dispatcher, [ScanActions]. */
    private val scanHost = object : ScanActions.Host {
        override fun isPaused() = corePaused
        override fun pauseScan() { if (recording && !corePaused) togglePause() }
        override fun resumeScan() { if (recording && corePaused) togglePause() }
        override fun snapshot() = overlay?.let { ScanStateSnapshot.fromOverlay(it) }
    }
    private val scanActions by lazy { ScanActions(speech, scanHost) }
    private val clearActionLine = Runnable { hud.setVoiceLine(null) }

    /** What voice commands may do on this screen beyond [ScanActions] (main thread only). */
    private val voiceHost = object : VoiceController.Host {
        override fun finishConfirmed() { stop() }   // same path as the Finish button (review sheet when a wall is weak)
        override fun feedback(text: String?) { hud.setVoiceLine(text) }
        override fun voiceStateChanged() = refreshMic()
    }

    private fun refreshMic() {
        val v = voice
        hud.setMic(if (v != null && v.available && recording && !finishing && !research.unguided) v.micState else null)
    }

    /** Trial chip (field flavour, not while recording) and the voice chip (hidden in the unguided arm). */
    private fun applyTrial() {
        hud.setTrial(if (research.enabled && !recording) research.label else null)
        hud.setVoice(if (research.unguided) null else speech.enabled)
        refreshMic()
    }

    private fun scanPrompt() = if (research.unguided) "Scan the room" else "Move slowly and keep the camera steady"

    /** Drops the last instruction so the coaching line goes back to [scanPrompt] (prompt expired, or the scan resumed). */
    private fun clearInstruction() = synchronized(recalLock) { instruction = ""; instructionLong = ""; instructionType = "" }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        speech = SpeechRenderer(this)
        objectView = ObjectBoxOverlayView(this)   // before ArHost: its frame callback projects the boxes
        ar = ArHost(this) { frame ->
            if (!arActive) return@ArHost   // no Frame use once onPause started tearing the Session down
            adapter?.onFrame(frame)
            trackState = frame.camera.trackingState.name
            trackFailure = frame.camera.trackingFailureReason.name
            // Segmentation (ADR 0035): one rate check per frame; a due frame is copied and handed to the worker.
            val p = lastPolicy
            if (recording && !corePaused && !finishing && p?.mustPause != true) segFeed?.onArFrame(frame, p?.mlRateScale ?: 1.0)
            if (recording && !corePaused) objectView.onArFrame(frame, ar.session, overlay?.objects ?: emptyList())   // hit test + projection
        }
        ar.onError = { msg -> arMessage = msg; refresh() }
        hud = Hud(this, features)
        hud.pauseEnabled = true
        hud.button.setOnClickListener { if (session == null) start() else stop() }
        hud.pauseButton.setOnClickListener { hud.onAction(if (corePaused) ScanActions.Kind.RESUME else ScanActions.Kind.PAUSE) }   // same path as the voice command
        hud.onAction = { k ->
            if (recording && !finishing) {
                val o = scanActions.run(k)
                if (o.text != null) { hud.setVoiceLine(o.text); ui.removeCallbacks(clearActionLine); ui.postDelayed(clearActionLine, o.ms) }
            }
        }
        hud.onVoiceToggle = { speech.enabled = !speech.enabled; hud.setVoice(speech.enabled) }
        if (features.segmentation) hud.onBoxesToggle = { if (segmentation != null) { objectView.showBoxes = !objectView.showBoxes; hud.setBoxes(objectView.showBoxes) } }
        else objectView.visibility = android.view.View.GONE
        research = ResearchLog(this)
        if (features.voiceCommands) {
            val v = VoiceController(this, speech, voiceHost, scanActions)
            v.onIntent = { research.onIntent(it.name) }
            hud.onMicClick = { v.onMicTapped() }
            voice = v
        }
        hud.onTrialClick = { if (!recording) research.showSetup { applyTrial() } }
        applyTrial()
        hud.setCoaching("Press Start, then move slowly around the room")
        setContentView(FrameLayout(this).apply {
            addView(ar.view, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            addView(objectView, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)   // same frame as ar.view
            addView(hud.root, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        })
        if (!CameraPermission.granted(this)) CameraPermission.request(this)
        hud.button.isEnabled = false
        hud.setDetail("Checking for interrupted sessions...")
        Thread {
            getExternalFilesDir("bundles")?.let { dev.capturekit.upload.BundleArchive.cleanTmp(it) }   // a zip pack the process was killed in (ADR 0040)
            val recovered = SessionManager.recoverInterrupted(this)
            runOnUiThread {
                recovering = false
                recoveredNote = if (recovered.isEmpty()) null else "Recovered ${recovered.size} interrupted session(s)"
                hud.setDetail(recoveredNote)
                refresh()   // Start is enabled there: needs the hold-still calibration and tracking too
            }
        }.start()
    }

    /**
     * Start pressed: with voice commands on, ask for the microphone first (rationale), then begin; a refusal only turns
     * voice commands off. With them off (default, ADR 0032) there is no microphone request.
     */
    private fun start() { val v = voice; if (v != null) v.ensurePermissionThen { startScan() } else startScan() }

    /** Feature switches (ADR 0032): defaults everywhere, debug-build `setprop` overrides; see [Features]. */
    private val features: FeatureFlags.Flags by lazy { Features.get(this) }

    private fun startScan() {
        if (session != null || finishing) return
        val calibration = calibResult
        if (calibration == null) { hud.setBanner("Hold the phone still for a moment before starting.", UiKit.Kind.WARN); return }
        // Consent keys (consent_version + consent_at + redaction_mode) are always passed together; no consent, no scan.
        val consentCfg = dev.capturekit.consent.ConsentStore.get(this).sessionConfig()
        if (consentCfg == null) {
            startActivity(Intent(this, ConsentActivity::class.java).putExtra(ConsentActivity.EXTRA_START_SCAN, true))
            finish()
            return
        }
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val dir = File(getExternalFilesDir("bundles"), "scan_$stamp")
        // Detector off by default (ADR 0032); debug builds can override: `adb shell setprop debug.capturekit.detector 1` and
        // `debug.capturekit.understanding 0|1|2`. With no understanding override a guided scan gets level 2 (ADR 0036: objects
        // when the detector runs, plus the gaps that feed the completeness card).
        val detector = features.detector
        val detectorWillRun = detector && LiteRtKeyframeDetector.available(this)
        // The unguided trial arm is the no-guidance control: no understanding by default (detections are still recorded).
        val understanding = FeatureFlags.understandingFor(features.understanding, !research.unguided)
        val s = SessionManager(this, dir, listener = this, detectorEnabled = detector)
        // 8 core frame slots (default 4): absorbs ~800 ms worker stalls at 10 candidates/s before ErrFull.
        if (!s.start(mapOf<String, Any>("frame_slots" to 8) + consentCfg + FeatureFlags.extraConfig(understanding, features.recordImu) + calibration.toSessionConfig())) {
            hud.setBanner("Could not start the capture session. Check free storage and try again.", UiKit.Kind.ERROR)
            return
        }
        session = s
        ar.stats = s.stats
        objectsExpected = s.detectorActive && (understanding ?: 0) >= 1
        if (detectorWillRun && !s.detectorActive) Log.w(TAG, "detector model packaged but the detector did not start")
        objectView.reset()
        // ADR 0035: on by default, off when the model files are missing or the GPU cannot run them (create / open give null); not in the unguided arm.
        var seg: SegmentationScheduler? = null
        seg = if (research.unguided) null else SegmentationScheduler.create(this, features.segmentation,
            sink = { r -> if (recording && !corePaused && !finishing) objectView.setResult(r) },
            // The worker turned itself off (model would not load / kept failing): drop the boxes chip.
            onDisabled = { runOnUiThread { if (segmentation != null && segmentation === seg) segmentationFailed() } })
        segmentation = seg
        segFeed = seg?.let { SegmentationFeed(it) }
        val boxesWanted = features.segmentation && !research.unguided
        if (boxesWanted && seg == null) Log.w(TAG, "object boxes unavailable: segmentation did not start (model files missing or GPU cannot run them)")
        hud.setBoxes(if (seg != null) objectView.showBoxes else null, unavailable = boxesWanted && seg == null)
        ar.recording = true
        adapter = ARAdapter(s, 0L) { ar.session }
        stopCalibration()
        sensors = SensorBridge(this, s).also { it.start() }
        thermal = ThermalAdapter(this) { p -> pushPlatform(s, p) }.also { it.start() }
        keyframes = 0; overlay = null; lastQuality = -1.0; lastReasons = emptyList()
        synchronized(recalLock) { instruction = ""; instructionLong = ""; instructionType = ""; recal = Recalibration() }
        corePaused = false; pausedTotalMs = 0; pausedAtMs = 0
        recStartMs = SystemClock.elapsedRealtime(); recording = true
        speech.stats.reset(); speech.stats.begin(recStartMs)
        research.begin(s.stats, speech.stats, recStartMs)
        applyTrial()
        hud.setResult(null)
        hud.setRecording(true)
        hud.setActions(!research.unguided)
        hud.setDetail(null)
        hud.setCoaching(scanPrompt())
        hud.haptic(false)
    }

    private fun pushPlatform(s: SessionManager, p: PlatformSignals) =
        s.onPlatform(SystemClock.elapsedRealtimeNanos(), p.thermalLevel, p.lowPowerMode, p.batteryPct, p.charging, 0.0)

    private fun togglePause() {
        val s = session ?: return
        if (!recording) return
        if (!corePaused) {
            if (s.pause() == Status.OK) {
                speech.stopNow()
                objectView.clear()
                hud.setCoaching("Paused. Press Resume when you are ready")
                hud.haptic(false)
            }
        } else {
            val st = s.resume()
            if (st == Status.OK) { clearInstruction(); hud.setCoaching(scanPrompt()) }
            else hud.setBanner("Cannot resume yet: the phone needs to cool down or charge (status ${UiKit.statusName(st)}).", UiKit.Kind.WARN)
        }
    }

    /**
     * Finish pressed: when a wall is weak, pause the core and show [ReviewSheet] before finalize ("Scan the gaps"
     * resumes the same bundle, "Finish anyway" finalizes); otherwise finish straight away. With guidance off (ADR 0032)
     * only the empty-scan notice remains (nothing of the room captured).
     */
    private fun stop() {
        val s = session ?: return
        if (finishing || reviewDialog != null) return
        val room = overlay
        // Unguided trial arm: no review sheet (it is guidance); finish straight away.
        if (!recording || research.unguided || !ReviewSheet.needed(room, features.guidance)) { finishScan(); return }
        if (!corePaused) {
            if (s.pause() != Status.OK) {
                hud.setBanner("Could not pause the scan to review it. Press Finish again.", UiKit.Kind.WARN)
                return
            }
            corePaused = true   // synchronously, so onPause does not pause a second time
            pausedAtMs = SystemClock.elapsedRealtime()
        }
        speech.stopNow()
        hud.haptic(false)
        reviewDialog = ReviewSheet.show(this, room, features.guidance, features.detector, Completeness.compute(room, objectView.live),
            onGaps = {
                if (reviewDialog == null) return@show   // one-shot: resume runs once
                reviewDialog = null
                val st = s.resume()
                if (st == Status.OK) { clearInstruction(); hud.setCoaching(scanPrompt()) }
                else hud.setBanner("Cannot resume yet: the phone needs to cool down or charge (status ${UiKit.statusName(st)}). Press Resume when it is ready.", UiKit.Kind.WARN)
            },
            onFinish = { reviewDialog = null; finishScan() })
    }

    private fun finishScan() {
        val s = session ?: return
        if (finishing) return
        finishing = true
        voice?.onPause()
        speech.stopNow()
        sensors?.stop(); thermal?.stop(); adapter = null
        hud.button.isEnabled = false
        hud.pauseButton.isEnabled = false
        closeSegmentation()
        synchronized(recalLock) { recal = Recalibration() }
        hud.setRecalibrate(null)
        val elapsed = elapsedMs()
        recording = false
        ar.recording = false
        hud.setRecording(false)
        hud.setActions(false)
        hud.setDetail(null)
        hud.setVoiceLine(null)
        hud.setResult("Saving the scan...", UiKit.Kind.INFO)
        hud.setCoaching("Saving. Keep the app open")
        hud.haptic(true)
        val kf = keyframes
        // Last room snapshot for the Review screen (Intent extras only; no bundle schema change): objects / openings for "Found"
        // and the completeness summary JSON (contract C3).
        val room = overlay
        val summaryJson = if (research.unguided) null else Completeness.toJson(Completeness.compute(room, objectView.live))
        Thread {
            val st = s.finish()
            research.end(s.dir, st, kf, elapsed, SystemClock.elapsedRealtime())   // field only; sibling file, after the bundle is closed
            runOnUiThread {
                session = null
                startActivity(Intent(this, ReviewActivity::class.java)
                    .putExtra(ReviewActivity.EXTRA_DIR, (s.archive ?: s.dir).absolutePath)   // the zip, or the folder if packing failed (ADR 0040)
                    .putExtra(ReviewActivity.EXTRA_STATUS, st)
                    .putExtra(ReviewActivity.EXTRA_ELAPSED_MS, elapsed)
                    .putExtra(ReviewActivity.EXTRA_KEYFRAMES, kf)
                    .putExtra(ReviewActivity.EXTRA_OBJECTS_EXPECTED, objectsExpected)
                    .apply {
                        if (summaryJson != null) putExtra(Completeness.EXTRA, summaryJson)
                        if (room != null) {
                            putExtra(ReviewActivity.EXTRA_OBJECTS, dev.capturekit.capture.EventParser.encodeObjects(room.objects))
                            putExtra(ReviewActivity.EXTRA_OPENINGS, dev.capturekit.capture.EventParser.encodeOpenings(room.openings))
                        }
                    })
                finish()
            }
        }.start()
    }

    /** Stops feeding frames, releases the model on its worker and hides the masks + chip. Main thread; idempotent. */
    private fun closeSegmentation() {
        segFeed = null
        segmentation?.close(); segmentation = null
        objectView.clear(); hud.setBoxes(null)
    }

    /** Main thread: segmentation disabled itself mid-scan (model failed): the boxes and their chip go, the scan continues. */
    private fun segmentationFailed() {
        Log.w(TAG, "segmentation disabled itself: live object boxes off")
        closeSegmentation()
        if (features.segmentation && !research.unguided) hud.setBoxes(null, unavailable = true)
    }

    private fun elapsedMs(): Long {
        val now = if (corePaused && pausedAtMs != 0L) pausedAtMs else SystemClock.elapsedRealtime()
        return now - recStartMs - pausedTotalMs
    }

    /** UI refresh at ~4 Hz while resumed: reads volatile state written by the AR/core threads. */
    private val tick = object : Runnable {
        override fun run() {
            ar.checkStall()
            refresh()
            ui.postDelayed(this, 250)
        }
    }

    /** Fresh AR origin + a new still window (onResume without a session). Main thread. */
    private fun beginCalibration() {
        stopCalibration()
        calibResult = null
        ar.close()   // the next ar.resume() creates a new ARCore Session = a new world origin (ADR 0036)
    }

    /** After ar.resume(): start collecting the still window. */
    private fun startCalibrationWindow() {
        val c = StillnessCalibrator(SystemClock.elapsedRealtimeNanos())
        calib = c
        val sn = StillnessSensors(this, c)
        calibNoSensors = !sn.start()
        calibSensors = sn
    }

    private fun stopCalibration() { calibSensors?.stop(); calibSensors = null; calib = null }

    /** Hold-still card + Start gate (UI thread, ~4 Hz). Only before a scan exists. */
    private fun refreshCalibration() {
        val c = calib
        if (c != null && calibResult == null && c.state == StillnessCalibrator.State.READY) { calibResult = c.result(); calibSensors?.stop(); calibSensors = null }
        val ui = CalibrationCard.ui(c == null && calibResult == null, if (calibResult != null) StillnessCalibrator.State.READY else c?.state)
        val (head, sub) = CalibrationCard.text(ui, c?.progress ?: 0.0, c?.needsTableHint(SystemClock.elapsedRealtimeNanos()) == true, trackState)
        hud.setCoaching(head)
        hud.setDetail(sub.ifEmpty { recoveredNote })
        hud.button.isEnabled = !recovering && CalibrationCard.startAllowed(ui, trackState)
    }

    private fun refresh() {
        if (session == null && !finishing && !recording) refreshCalibration()
        val p = lastPolicy
        // One pill: tracking + latest frame-quality reasons + thermal level (warming/hot no longer use the banner).
        hud.setStatus(trackState, trackFailure, if (recording && !corePaused && lastQuality >= 0) lastReasons else emptyList(),
            if (recording && p != null) p.level else 0, ar.live() || ar.lastFrameMs == 0L || ar.state != ArState.READY)
        if (hud.debugOn) session?.let { hud.setDebug(it.stats.hudLine()) }
        hud.setCompleteness(if (recording && !research.unguided && overlay != null) Completeness.compute(overlay, objectView.live) else null)
        // Recalibration card (issue #1): only while scanning; the unguided trial arm gets no guidance, but the core still
        // pauses keyframes there. A user pause hides it (the core keeps tracking the recovery and resumes it on Resume).
        val r = recal
        hud.setRecalibrate(if (recording && !corePaused && !finishing && !research.unguided && r.active) r.prompt else null)
        refreshMic()
        if (recording) {
            hud.setPaused(corePaused)
            hud.setRecInfo(elapsedMs())
            if (!corePaused && instruction.isNotEmpty() && !research.unguided) {
                // Guidance off: nothing replaces a safety prompt, so it expires back to the scan prompt (RECALIBRATE stays while recovering).
                val recalibrating = r.active && instructionType == Recalibration.RECALIBRATE
                val at = instructionAtMs
                if (FeatureFlags.instructionStillShown(instruction, at, SystemClock.elapsedRealtime(), features.guidance, recalibrating))
                    hud.setCoaching(instruction, instructionLong)
                else if (synchronized(recalLock) { (instructionAtMs == at).also { if (it) { instruction = ""; instructionLong = ""; instructionType = "" } } })
                    hud.setCoaching(scanPrompt())   // a prompt that arrived meanwhile is kept and shown at the next tick
            }
        }
        // Banner is for errors only: a forced thermal/battery pause blocks capture, so it stays here.
        val thermalMsg = if (recording && p != null && p.mustPause) "Capture paused: the phone is too hot or the battery is low. Let it rest." else null
        val am = arMessage
        when {
            am != null && ar.state == ArState.NO_PERMISSION ->
                hud.setBanner("Camera permission is needed to scan the room.", UiKit.Kind.ERROR, CameraPermission.retryLabel()) { CameraPermission.retry(this) }
            am != null && ar.state != ArState.READY ->
                hud.setBanner(am, UiKit.Kind.ERROR, "Retry") { arMessage = null; ar.retry(); refresh() }
            calibNoSensors && session == null -> hud.setBanner("This phone has no gyroscope or accelerometer, so the scan cannot start.", UiKit.Kind.ERROR)
            !speech.available && recording && !research.unguided -> hud.setBanner("Voice guidance is unavailable: no offline text-to-speech voice. On-screen prompts still work.", UiKit.Kind.INFO)
            thermalMsg != null -> hud.setBanner(thermalMsg, UiKit.Kind.WARN)
            else -> hud.setBanner(null)
        }
    }

    // Core event thread (not the AR thread).
    override fun onEvent(e: CoreEvent) {
        // Pure reducer (same instance for unrelated events); after finishScan() reset it, a late event is ignored.
        synchronized(recalLock) { if (!finishing) recal = recal.on(e) }
        when (e) {
            is CoreEvent.FrameQuality -> { lastQuality = e.quality; lastReasons = e.reasons }
            is CoreEvent.KeyframeRequest -> keyframes++
            is CoreEvent.TrackingLost -> {
                Log.i(TAG, "tracking lost for ${e.degradedS} s (state ${e.trackingState}, reason ${e.reason}): recalibrating")
                ui.post { refresh() }   // show the card now, not at the next 250 ms tick
            }
            is CoreEvent.TrackingReset -> {
                Log.i(TAG, "tracking reset after ${e.lostS} s, drift ${e.driftM} m / ${e.driftDeg} deg")
                // The prompt auto-dismisses; a stale "turn in a circle" line must not stay up until the next instruction.
                val wasRecal = synchronized(recalLock) {
                    (instructionType == Recalibration.RECALIBRATE).also { if (it) { instruction = ""; instructionType = "" } }
                }
                ui.post {
                    if (recording && !corePaused && !finishing && !research.unguided) {
                        if (wasRecal) hud.setCoaching(scanPrompt())
                        hud.haptic(true)   // confirm: back on track
                    }
                    refresh()
                }
            }
            is CoreEvent.Instruction -> {
                research.onInstruction()
                // Guidance gate (ADR 0032): with guidance off only safety/tracking prompts are shown, spoken and felt.
                // The core has already recorded every instruction in /events.
                if (FeatureFlags.showInstruction(e.type, features.guidance)) {
                    synchronized(recalLock) {
                        instruction = e.speakText; instructionLong = e.longText; instructionType = e.type
                        instructionAtMs = SystemClock.elapsedRealtime()
                    }
                    if (!corePaused && !research.unguided) {
                        speech.onInstruction(e.id, e.speakText, e.priority)
                        hud.hapticFor(e.haptic, e.priority)
                    }
                }
            }
            is CoreEvent.Overlay -> overlay = e
            is CoreEvent.Governor -> lastGovernor = "${e.from}->${e.to} (${e.reason})"
            else -> {}
        }
    }
    override fun onPolicy(p: Policy) { lastPolicy = p; research.onThermal(p.level, SystemClock.elapsedRealtime()) }

    // Detector thread: one keyframe's boxes (already sent to the core). Not drawn: the live boxes come from segmentation (ADR 0035).
    override fun onDetections(frameId: Int, tNs: Long, boxes: List<DetectedBox>) {}

    override fun onState(state: Int) {
        val nowPaused = state == STATE_PAUSED
        if (nowPaused == corePaused) return
        if (nowPaused) { pausedAtMs = SystemClock.elapsedRealtime(); speech.stopNow() }
        else if (pausedAtMs != 0L) { pausedTotalMs += SystemClock.elapsedRealtime() - pausedAtMs; pausedAtMs = 0 }
        corePaused = nowPaused
    }

    override fun onResume() {
        super.onResume()
        arMessage = null
        val calibrate = session == null && !finishing && !recording
        if (calibrate) beginCalibration()
        ar.resume()
        arActive = true
        if (calibrate) startCalibrationWindow()
        ui.post(tick)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) UiKit.immersive(this)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == VoiceController.REQ_CODE) { voice?.onPermissionResult(grantResults); return }
        if (CameraPermission.onResult(this, grantResults)) { arMessage = null; ar.resume() }
        else { arMessage = "Camera permission is needed to scan the room."; refresh() }
    }

    override fun onPause() {
        val t0 = SystemClock.elapsedRealtime()
        ui.removeCallbacks(tick)
        if (session == null) stopCalibration()
        // Leaving the screen mid-scan: pause the core session so no gap is recorded as tracking data.
        if (recording && !corePaused && !finishing) session?.pause()
        voice?.onPause()
        speech.stopNow()
        val t1 = SystemClock.elapsedRealtime()
        arActive = false
        ar.pause()
        val t2 = SystemClock.elapsedRealtime()
        super.onPause()
        Log.i(TAG, "timing Activity.onPause total=${SystemClock.elapsedRealtime() - t0}ms core+speech=${t1 - t0}ms ar.pause=${t2 - t1}ms")
    }

    override fun onDestroy() {
        // Destroyed mid-scan (Back, swipe-away, system): finish the session so the work is kept as a bundle and
        // nothing leaks (native handle, ck-events thread, sensor/thermal listeners). finish() writes a complete
        // bundle; if the process dies before it ends, the DB still says "recording" and next launch recovers it.
        reviewDialog?.dismiss(); reviewDialog = null
        val s = session
        if (s != null && !finishing) {
            finishing = true
            ar.recording = false
            sensors?.stop(); thermal?.stop(); adapter = null
            session = null
            Log.w(TAG, "destroyed mid-scan: finishing ${s.dir.name} so the scan is kept")
            val kf = keyframes
            val elapsed = elapsedMs()
            val r = research
            Thread {
                val st = s.finish()
                r.end(s.dir, st, kf, elapsed, SystemClock.elapsedRealtime())
                Log.w(TAG, "mid-scan finish of ${s.dir.name}: status ${UiKit.statusName(st)}")
            }.start()
        }
        segFeed = null; segmentation?.close(); segmentation = null
        hud.release()
        voice?.release()
        speech.release()
        ar.close()
        super.onDestroy()
    }

    private companion object { const val STATE_PAUSED = 3; const val TAG = "CKCapture" }
}
