import SwiftUI
#if os(iOS) && canImport(CCaptureKit)
import ARKit
import CoreMotion
import CaptureKit
import CaptureKitSegment
import UIKit

/// A box layer snapshot for one display frame: boxes in camera-image pixels plus what maps them to the view. Holds a plain
/// CGAffineTransform, never an ARFrame (retaining frames would starve ARKit's frame pool).
struct BoxSnapshot {
    let boxes: [DrawBox]
    let imageSize: CGSize
    /// ARFrame.displayTransform(for:viewportSize:): normalised image coordinates -> normalised view coordinates. UNVERIFIED on device.
    let display: CGAffineTransform

    /// Image-pixel rectangle -> view-point rectangle (all four corners, so a rotated display maps right).
    func map(_ r: CGRect, _ size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let w = imageSize.width, h = imageSize.height
        let corners = [CGPoint(x: r.minX / w, y: r.minY / h), CGPoint(x: r.maxX / w, y: r.minY / h),
                       CGPoint(x: r.maxX / w, y: r.maxY / h), CGPoint(x: r.minX / w, y: r.maxY / h)].map { $0.applying(display) }
        let xs = corners.map { $0.x }, ys = corners.map { $0.y }
        let x0 = xs.min() ?? 0, x1 = xs.max() ?? 0, y0 = ys.min() ?? 0, y1 = ys.max() ?? 0
        return CGRect(x: x0 * size.width, y: y0 * size.height, width: (x1 - x0) * size.width, height: (y1 - y0) * size.height)
    }
}

enum BoxesChip: Equatable { case hidden, on, off, unavailable }

struct CaptureBanner: Equatable {
    enum Kind { case info, warn, error }
    enum Action { case openSettings }
    let text: String
    let kind: Kind
    var action: Action?
}

struct RationaleAsk: Identifiable {
    let id = UUID()
    let answer: (Bool) -> Void
}

/// State and logic of the capture screen (twin of S/CaptureActivity.kt, ADR 0036/0037).
///
/// Threads: every `@Published` property is written on the MAIN thread only. `CaptureSessionDelegate` callbacks arrive on the core's poll
/// queue: they copy into the lock-protected `shared` state and hop to main for anything the UI or speech must do (nothing heavy there,
/// and never on ARKit's delegate queue). A 4 Hz timer on main turns `shared` into published state (Android `refresh()`).
final class CaptureModel: NSObject, ObservableObject, CaptureSessionDelegate, ScanActionsHost, VoiceHost, @unchecked Sendable {
    // MARK: published state (main thread)
    @Published var recording = false
    @Published var paused = false
    @Published var finishing = false
    @Published var coaching = "Getting ready..."
    @Published var detail: String?
    @Published var voiceLine: String?
    @Published var resultLine: String?
    @Published var banner: CaptureBanner?
    @Published var pill = StatusPill.starting
    @Published var summary: Completeness.Summary?
    @Published var recalPrompt: String?
    @Published var mic: MicState?
    @Published var voiceOn: Bool?
    @Published var boxesChip = BoxesChip.hidden
    @Published var showBoxes = true
    @Published var elapsedMs: Int64 = 0
    @Published var startEnabled = false
    @Published var calibUi = CalibrationUi.resettingAr
    @Published var calibProgress = 0.0
    @Published var finishAsk = false
    @Published var rationale: RationaleAsk?
    @Published var reviewSheet: ReviewSheetData?

    // MARK: collaborators
    let flags: FeatureFlags.Flags
    private let cs: CaptureSession
    var arSession: ARSession { cs.arSession }
    private let speech = SpeechRenderer()
    private(set) var actions: ScanActions!
    private var voice: VoiceController?
    private var live: LiveObjectsController?          // main thread; `shared.live` is the poll-thread copy

    /// Set by the view: consent is missing at Start (go back to the consent screen) / the scan was finished (open the Review screen).
    var onNeedConsent: () -> Void = {}
    var onFinished: (ReviewArgs) -> Void = { _ in }

    // MARK: state shared with the poll queue (guarded by `lock`)
    private struct Shared {
        var recal = Recalibration()
        var overlay: OverlayEvent?
        var reasons: [String] = []
        var hasQuality = false
        var policy: Policy?
        var keyframes = 0
        var instruction = "", instructionLong = "", instructionType = ""
        var instructionAtMs: Int64 = 0
        var finishing = false
        var recording = false
        var paused = false
        var live: LiveObjectsController?
    }
    private let lock = NSLock()
    private var shared = Shared()
    private func locked<T>(_ f: (inout Shared) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(&shared) }

    // MARK: main-thread bookkeeping
    private var timer: Timer?
    private var recStartMs: Int64 = 0
    private var pausedAtMs: Int64 = 0
    private var pausedTotalMs: Int64 = 0
    private var everTracked = false, everFramed = false
    private var recoveryDone = false
    private var recoveredNote: String?
    private var noSensors = false
    private var floorY: Float?
    private var orientation = UIInterfaceOrientation.portrait
    private var viewport = CGSize(width: 390, height: 844)
    private var voiceLineToken = 0
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()

    private static let scanPrompt = "Move slowly and keep the camera steady"

    override init() {
        flags = Prefs.flags()
        cs = CaptureSession(dir: ScanStorage.newDir())
        super.init()
        cs.delegate = self
        actions = ScanActions(speech: speech, host: self)
        if flags.voiceCommands { voice = VoiceController(speech: speech, actions: actions, host: self) }
        voiceOn = speech.enabled
        Task { [weak self] in
            let n = await Recovery.result()
            DispatchQueue.main.async {
                guard let self else { return }
                self.recoveryDone = true
                if n > 0 { self.recoveredNote = HomeText.recoveredNote }
            }
        }
    }

    // MARK: screen lifecycle (main thread)

    /// Screen appeared or the app became active again: camera permission, then the hold-still step with a fresh AR origin (ADR 0036).
    func begin() {
        guard !recording, !finishing else { return }
        startTimer()
        guard CameraAccess.granted else {
            if CameraAccess.denied { banner = CaptureBanner(text: "Camera permission is needed to scan the room.", kind: .error, action: .openSettings) }
            else { CameraAccess.request { [weak self] _ in self?.begin() } }   // granted: calibration starts; refused: the banner above
            return
        }
        noSensors = !(CMMotionManager().isGyroAvailable && CMMotionManager().isAccelerometerAvailable)
        cs.resetForCalibration()
        everFramed = false
        tick()
    }

    /// App went to the background (`active` false) or came back. Mid-scan: pause the core so the gap is not recorded as tracking data.
    func appActive(_ active: Bool) {
        if active { if !recording { begin() }; return }
        voice?.onPause(); speech.stopNow()
        if recording && !paused && !finishing { pauseScan() }
        else if !recording && !finishing { cs.stopPreview() }
    }

    /// Screen left. Mid-scan (Back swipe, system): finish the session so the work is kept as a bundle (Android onDestroy); nothing leaks.
    func teardown() {
        timer?.invalidate(); timer = nil
        voice?.release(); speech.release()
        if recording && !finishing {
            locked { $0.finishing = true; $0.recording = false }
            finishing = true
            closeSegmentation()
            let s = cs
            DispatchQueue.global(qos: .userInitiated).async { _ = s.finish() }   // finalizes a complete bundle; recovery covers a kill
        } else if !recording && !finishing {
            cs.stopPreview()
        }
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport = size
        cs.viewportSize = size
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Start

    /// Shutter pressed before a scan: with voice commands on, ask for the microphone first (rationale), then begin; a refusal only
    /// turns voice commands off. With them off (default, ADR 0032) there is no microphone request.
    func startPressed() {
        guard !recording, !finishing else { return }
        if let v = voice { v.ensurePermissionThen { [weak self] in self?.startScan() } } else { startScan() }
    }

    private func startScan() {
        guard !recording, !finishing else { return }
        // The hold-still step is never skippable: still AND normal tracking (contract C4).
        let ui = CalibrationCard.ui(arResetting: cs.arResetting, state: cs.calibrationState)
        guard CalibrationCard.startAllowed(ui, trackingState: cs.trackingStateName) else {
            banner = CaptureBanner(text: "Hold the phone still for a moment before starting.", kind: .warn)
            return
        }
        // Consent keys (consent_version + consent_at + redaction_mode) always travel together; no consent, no scan.
        var f = flags
        f.understanding = FeatureFlags.understandingFor(override: flags.understanding, guidedScan: true)   // ADR 0036: guided scan = level 2
        guard let config = SessionConfigBuilder.build(flags: f, consent: ConsentStore.standard().sessionConfig(), calibration: nil,
                                                      extra: ["frame_slots": .int(8)]) else {
            onNeedConsent(); return
        }
        // Live object boxes (ADR 0035): inert when the flag is off or the model files are missing (isActive false).
        let controller = LiveObjectsController(arSession: cs.arSession, enabled: flags.segmentation,
                                               onDisabled: { [weak self] in self?.objectWillChange.send() })
        cs.interfaceOrientation = orientation
        cs.viewportSize = viewport
        cs.segmentationGate = { [weak self] t, normal in
            guard let self else { return false }
            let (ok, ctrl) = self.locked { s -> (Bool, LiveObjectsController?) in
                (s.recording && !s.paused && !s.finishing && s.policy?.mustPause != true, s.live)
            }
            return ok && (ctrl?.gate(t, normal) ?? false)
        }
        cs.segmentationSink = { [weak self] frame in
            guard let ctrl = self?.locked({ $0.live }) else { return }
            ctrl.sink(frame)
        }
        locked { $0.live = controller; $0.recording = true; $0.paused = false; $0.finishing = false
                 $0.recal = Recalibration(); $0.overlay = nil; $0.reasons = []; $0.hasQuality = false; $0.keyframes = 0
                 $0.instruction = ""; $0.instructionLong = ""; $0.instructionType = "" }
        do { try cs.start(config: config) }
        catch CaptureSessionError.consentRequired { resetAfterFailedStart(); onNeedConsent(); return }
        catch {
            resetAfterFailedStart()
            banner = CaptureBanner(text: "Could not start the capture session. Check free storage and try again.", kind: .error)
            return
        }
        live = controller
        floorY = nil
        pausedAtMs = 0; pausedTotalMs = 0
        recStartMs = Self.uptimeMs()
        paused = false
        recording = true
        resultLine = nil; detail = nil
        coaching = Self.scanPrompt
        showBoxes = true
        play(HapticMap.pulses("tap"))
        tick()
    }

    private func resetAfterFailedStart() {
        locked { $0.live = nil; $0.recording = false }
        live?.close(); live = nil
        cs.segmentationGate = nil; cs.segmentationSink = nil
    }

    // MARK: pause / resume (ScanActionsHost)

    func isPaused() -> Bool { paused }
    func snapshot() -> ScanStateSnapshot? { locked { $0.overlay }.map { ScanStateSnapshot.fromOverlay($0) } }

    func pauseScan() {
        guard recording, !paused, !finishing else { return }
        if cs.pause() == CK_OK {
            applyPaused(true)
            coaching = "Paused. Press Resume when you are ready"
            play(HapticMap.pulses("tap"))
        }
    }

    func resumeScan() {
        guard recording, paused, !finishing else { return }
        if cs.resume() == CK_OK {
            applyPaused(false)
            clearInstruction()
            coaching = Self.scanPrompt
        } else {
            banner = CaptureBanner(text: "Cannot resume yet: the phone needs to cool down or charge.", kind: .warn)
        }
    }

    /// Single place of the paused flag (button, voice, forced thermal pause, core state event). Keeps the REC clock honest.
    private func applyPaused(_ p: Bool) {
        guard p != paused else { return }
        if p { pausedAtMs = Self.uptimeMs(); speech.stopNow() }
        else if pausedAtMs != 0 { pausedTotalMs += Self.uptimeMs() - pausedAtMs; pausedAtMs = 0 }
        paused = p
        locked { $0.paused = p }
    }

    // MARK: Finish

    /// Finish button: ask first (a tap on the shutter is easy to hit by accident), then `stop()`.
    func finishPressed() {
        guard recording, !finishing, reviewSheet == nil else { return }
        finishAsk = true
    }

    func finishAnswered(_ yes: Bool) {
        finishAsk = false
        voice?.finishDialogClosed()
        if yes { stop() }
    }

    /// When a wall is weak (or nothing was captured): pause the core and show the review sheet before finalize; "Scan the gaps" resumes
    /// the same bundle, "Finish anyway" finalizes. With guidance off only the empty-scan notice remains (ReviewRules.needed).
    private func stop() {
        guard recording, !finishing, reviewSheet == nil else { return }
        let room = locked { $0.overlay }
        guard ReviewRules.needed(room, guidance: flags.guidance) else { finishScan(); return }
        if !paused {
            guard cs.pause() == CK_OK else {
                banner = CaptureBanner(text: "Could not pause the scan to review it. Press Finish again.", kind: .warn)
                return
            }
            applyPaused(true)
        }
        speech.stopNow()
        play(HapticMap.pulses("tap"))
        reviewSheet = ReviewSheetData.make(overlay: room, summary: Completeness.compute(room, live: liveObjects()),
                                           guidance: flags.guidance, detector: flags.detector)
    }

    func reviewGaps() {
        guard reviewSheet != nil else { return }   // one-shot
        reviewSheet = nil
        resumeScan()
    }

    func reviewFinish() {
        guard reviewSheet != nil else { return }
        reviewSheet = nil
        finishScan()
    }

    private func finishScan() {
        guard recording, !finishing else { return }
        finishing = true
        voice?.onPause(); speech.stopNow()
        let elapsed = elapsedNow()
        let room = locked { $0.overlay }
        let liveNow = liveObjects()                       // before closeSegmentation clears the tracker
        let summaryJSON = Completeness.toJSON(Completeness.compute(room, live: liveNow))
        let kf = locked { s -> Int in s.finishing = true; s.recording = false; s.recal = Recalibration(); return s.keyframes }
        closeSegmentation()
        recalPrompt = nil
        recording = false
        voiceLine = nil; detail = nil
        resultLine = "Saving the scan..."
        coaching = "Saving. Keep the app open"
        play(HapticMap.pulses("success"))
        let expected = flags.detector && (FeatureFlags.understandingFor(override: flags.understanding, guidedScan: true) ?? 0) >= 1
        let s = cs, dir = cs.dir.path
        let objects = room.map { EventParser.encodeObjects($0.objects) } ?? "", openings = room.map { EventParser.encodeOpenings($0.openings) } ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let st = s.finish()   // stops ARKit, encodes pending keyframes, finalizes the bundle (blocks: not on main)
            DispatchQueue.main.async {
                self?.onFinished(ReviewArgs(dir: dir, status: Int(st.rawValue), elapsedMs: elapsed, keyframes: kf, objectsExpected: expected,
                                            summaryJSON: summaryJSON, objects: objects, openings: openings))
            }
        }
    }

    /// Stops feeding frames, releases the model and hides the boxes. Main thread; idempotent.
    private func closeSegmentation() {
        locked { $0.live = nil }
        cs.segmentationGate = nil; cs.segmentationSink = nil
        live?.close(); live = nil
        boxesChip = .hidden
    }

    private func liveObjects() -> [LiveObject] { live?.tracker.objects(nowMs: LiveObjectsController.nowMs()) ?? [] }

    // MARK: buttons

    /// Pause / Resume / Repeat / What's missing / Volume: the same path as the voice commands (ADR 0036).
    func perform(_ kind: ScanActions.Kind) {
        guard recording, !finishing else { return }
        let o = actions.run(kind)
        if let t = o.text { showVoiceLine(t, ms: o.ms) }
    }

    func togglePause() { perform(paused ? .resume : .pause) }
    func toggleVoice() { speech.enabled.toggle(); voiceOn = speech.enabled }
    func toggleBoxes() { if boxesChip == .on || boxesChip == .off { showBoxes.toggle(); tick() } }
    func micTapped() { voice?.onMicTapped() }

    private func showVoiceLine(_ text: String?, ms: Int) {
        voiceLineToken += 1
        let token = voiceLineToken
        voiceLine = text
        guard text != nil, ms > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
            if let self, self.voiceLineToken == token { self.voiceLine = nil }
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    // MARK: VoiceHost (main thread)

    func voiceAskRationale(_ answer: @escaping (Bool) -> Void) { rationale = RationaleAsk(answer: answer) }
    func voiceAskFinish() { if recording && !finishing { finishAsk = true } }
    func voiceDismissFinish() { finishAsk = false }
    func voiceFinishConfirmed() { finishAsk = false; stop() }
    func voiceFeedback(_ text: String?, ms: Int) { showVoiceLine(text, ms: ms) }
    func voiceStateChanged() { mic = currentMic() }

    func answerRationale(_ allow: Bool) {
        let r = rationale
        rationale = nil
        r?.answer(allow)
    }

    private func currentMic() -> MicState? {
        guard let v = voice, v.available, recording, !finishing else { return nil }
        return v.micState
    }

    // MARK: CaptureSessionDelegate (poll queue: copy, then hop to main)

    func captureSession(_ s: CaptureSession, didEmit event: [String: Any]) {}

    func captureSession(_ s: CaptureSession, didUpdatePolicy p: ck_policy) {
        let pol = Policy(level: Int(p.level), keyframeRateScale: p.keyframe_rate_scale, mlRateScale: p.ml_rate_scale,
                         resolutionTier: Int(p.capture_resolution_tier), overlay: p.overlay_enabled != 0, upload: p.upload_allowed != 0,
                         mustPause: p.must_pause != 0)
        let ctrl = locked { s -> LiveObjectsController? in s.policy = pol; return s.live }
        ctrl?.mlRateScale = pol.mlRateScale
    }

    func captureSession(_ s: CaptureSession, didParse event: CoreEvent) {
        // Pure reducer; after finishScan() a late event is ignored.
        locked { if !$0.finishing { $0.recal = $0.recal.on(event) } }
        switch event {
        case .frameQuality(_, _, _, let reasons):
            locked { $0.reasons = reasons; $0.hasQuality = true }
        case .keyframeRequest:
            locked { $0.keyframes += 1 }
        case .trackingLost:
            DispatchQueue.main.async { [weak self] in self?.tick() }   // show the card now, not at the next tick
        case .trackingReset(_, let lostS, let driftM, let driftDeg):
            NSLog("CK/Capture: tracking reset after %.1f s, drift %.2f m / %.1f deg", lostS, driftM, driftDeg)
            // The prompt auto-dismisses; a stale "turn in a circle" line must not stay up until the next instruction.
            let wasRecal = locked { s -> Bool in
                let w = s.instructionType == Recalibration.recalibrate
                if w { s.instruction = ""; s.instructionType = "" }
                return w
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.recording && !self.paused && !self.finishing {
                    if wasRecal { self.coaching = Self.scanPrompt }
                    self.play(HapticMap.pulses("success"))
                }
                self.tick()
            }
        case .instruction(let id, let type, let speak, let long, let priority, let haptic, _):
            // Guidance gate (ADR 0032): with guidance off only safety / tracking prompts are shown, spoken and felt.
            guard FeatureFlags.showInstruction(type: type, guidance: flags.guidance) else { return }
            let at = Self.uptimeMs()
            locked { $0.instruction = speak; $0.instructionLong = long; $0.instructionType = type; $0.instructionAtMs = at }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.paused else { return }
                self.speech.onInstruction(id: id, text: speak, priority: priority)
                self.play(HapticMap.pulses(haptic, priority: priority))
            }
        case .overlay(let o):
            locked { $0.overlay = o }
        case .stateChange(_, let to, _):
            // A pause the core made itself (thermal / battery policy) or a resume: keep the flag and the REC clock in step.
            if to == "PAUSED" || to == "SCANNING" {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.recording, !self.finishing else { return }
                    self.applyPaused(to == "PAUSED")
                }
            }
        default:
            break
        }
    }

    // MARK: ~4 Hz refresh (main thread) = Android refresh()

    private func tick() {
        let now = Self.uptimeMs()
        orientation = Self.currentOrientation()
        cs.interfaceOrientation = orientation
        let trackName = cs.trackingStateName
        let frame = cs.arSession.currentFrame
        var fresh = true
        if let f = frame { everFramed = true; fresh = Double(now) / 1000 - f.timestamp < 1.5 } else if everFramed { fresh = false }
        if trackName == "TRACKING" { everTracked = true }

        if !recording && !finishing { refreshCalibration(trackName: trackName) }

        let s = locked { $0 }
        let level = recording ? (s.policy?.level ?? 0) : 0
        let reasons = recording && !paused && s.hasQuality ? s.reasons : []
        let p: StatusPill.Pill = fresh
            ? StatusPill.statusPill(trackState: trackName, failure: Self.failureName(frame), reasons: reasons, thermalLevel: level, everTracked: everTracked)
            : StatusPill.Pill("Camera paused", .neutral)
        upd(\.pill, p)

        if recording && !finishing {
            upd(\.elapsedMs, elapsedNow())
            if flags.segmentation, live != nil { floorY = Self.floorHeight(frame) ?? floorY }
            let sum = s.overlay != nil ? Completeness.compute(s.overlay, live: liveObjects()) : nil
            if summary != sum { summary = sum }
            // Recalibration card (issue #1): only while scanning and not user-paused; the core resumes the recovery on Resume.
            let r = s.recal
            upd(\.recalPrompt, (flags.recalibrateCard && !paused && r.active) ? r.prompt : nil)
            // Coaching line: with guidance off a prompt expires back to the scan prompt (RECALIBRATE stays while recovering).
            if !paused && !s.instruction.isEmpty {
                let recalibrating = r.active && s.instructionType == Recalibration.recalibrate
                if FeatureFlags.instructionStillShown(text: s.instruction, arrivedMs: s.instructionAtMs, nowMs: now, guidance: flags.guidance, recalibrating: recalibrating) {
                    upd(\.coaching, s.instruction)
                } else if locked({ st -> Bool in
                    guard st.instructionAtMs == s.instructionAtMs else { return false }   // a newer prompt arrived meanwhile: keep it
                    st.instruction = ""; st.instructionLong = ""; st.instructionType = ""; return true
                }) { upd(\.coaching, Self.scanPrompt) }
            }
            // Boxes chip (ADR 0038): flag on but the model/GPU cannot run -> grey "unavailable" chip.
            if !flags.segmentation { upd(\.boxesChip, .hidden) }
            else if let ctrl = live, ctrl.isActive { upd(\.boxesChip, showBoxes ? .on : .off) }
            else { upd(\.boxesChip, .unavailable) }
        } else {
            upd(\.recalPrompt, nil)
            if summary != nil { summary = nil }
        }
        upd(\.mic, currentMic())

        // Banner: errors and blocking conditions only.
        var b: CaptureBanner?
        if CameraAccess.denied { b = CaptureBanner(text: "Camera permission is needed to scan the room.", kind: .error, action: .openSettings) }
        else if noSensors && !recording { b = CaptureBanner(text: "This phone has no gyroscope or accelerometer, so the scan cannot start.", kind: .error) }
        else if recording && !speech.available { b = CaptureBanner(text: "Voice guidance is unavailable: no offline text-to-speech voice. On-screen prompts still work.", kind: .info) }
        else if recording && s.policy?.mustPause == true { b = CaptureBanner(text: "Capture paused: the phone is too hot or the battery is low. Let it rest.", kind: .warn) }
        else if let cur = banner, transientBanner(cur) { b = cur }   // start errors stay until the next successful action
        if banner != b { banner = b }
    }

    /// Banners raised by an action (not recomputed by `tick`): start failure, hold-still reminder, resume refused.
    private func transientBanner(_ b: CaptureBanner) -> Bool {
        b.text.hasPrefix("Could not") || b.text.hasPrefix("Hold the phone") || b.text.hasPrefix("Cannot resume")
    }

    /// Hold-still card + Start gate. Only before a scan exists.
    private func refreshCalibration(trackName: String) {
        let ui = CalibrationCard.ui(arResetting: cs.arResetting, state: cs.calibrationState)
        let (head, sub) = CalibrationCard.text(ui, progress: cs.calibrationProgress, tableHint: cs.calibrationNeedsTableHint, trackingState: trackName)
        upd(\.coaching, head)
        upd(\.detail, sub.isEmpty ? recoveredNote : sub)
        upd(\.calibUi, ui)
        upd(\.calibProgress, ui == .holdStill ? (cs.calibrationProgress * 20).rounded() / 20 : (ui == .ready ? 1 : 0))
        upd(\.startEnabled, recoveryDone && CalibrationCard.startAllowed(ui, trackingState: trackName))
        if ui == .ready && banner?.text.hasPrefix("Hold the phone") == true { banner = nil }
    }

    private func upd<T: Equatable>(_ kp: ReferenceWritableKeyPath<CaptureModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    private func clearInstruction() { locked { $0.instruction = ""; $0.instructionLong = ""; $0.instructionType = "" } }

    private func elapsedNow() -> Int64 {
        let now = (paused && pausedAtMs != 0) ? pausedAtMs : Self.uptimeMs()
        return max(now - recStartMs - pausedTotalMs, 0)
    }

    // MARK: boxes (display rate, main thread, read-only: never touches published state)

    /// Boxes for the camera as it is right now: each track's 3D centre projected into the CURRENT camera (own pinhole projection,
    /// `LiveObjectTracker.drawBoxes`), drawn by `BoxOverlay`. nil = nothing to draw.
    func boxSnapshot() -> BoxSnapshot? {
        guard recording, !paused, !finishing, showBoxes, let live, live.isActive, live.tracker.any,
              let frame = cs.arSession.currentFrame, case .normal = frame.camera.trackingState else { return nil }
        let cam = Self.cameraSnapshot(frame.camera)
        let core = locked { $0.overlay?.objects } ?? []
        let boxes = live.tracker.drawBoxes(cam, nowMs: LiveObjectsController.nowMs(), core: core, floorY: floorY)
        return BoxSnapshot(boxes: boxes, imageSize: CGSize(width: cam.w, height: cam.h),
                           display: frame.displayTransform(for: orientation, viewportSize: viewport))
    }

    private static func cameraSnapshot(_ cam: ARCamera) -> CameraSnapshot {
        let tf = cam.transform, K = cam.intrinsics, res = cam.imageResolution
        let flat: [Float] = [tf.columns.0.x, tf.columns.0.y, tf.columns.0.z, tf.columns.0.w,
                             tf.columns.1.x, tf.columns.1.y, tf.columns.1.z, tf.columns.1.w,
                             tf.columns.2.x, tf.columns.2.y, tf.columns.2.z, tf.columns.2.w,
                             tf.columns.3.x, tf.columns.3.y, tf.columns.3.z, tf.columns.3.w]
        return CameraSnapshot(columnMajor: flat, fx: Double(K[0][0]), fy: Double(K[1][1]), cx: Double(K[2][0]), cy: Double(K[2][1]),
                              w: Int(res.width), h: Int(res.height))
    }

    /// Lowest upward-facing plane (the floor), like Android's min centre height of horizontal planes.
    private static func floorHeight(_ frame: ARFrame?) -> Float? {
        frame?.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }.map { $0.transform.columns.3.y }.min()
    }

    // MARK: helpers

    private static func uptimeMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    private static func currentOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
    }

    /// ARKit tracking limits as the Android failure names StatusPill understands.
    private static func failureName(_ frame: ARFrame?) -> String {
        guard let f = frame, case .limited(let r) = f.camera.trackingState else { return "NONE" }
        switch r {
        case .excessiveMotion: return "EXCESSIVE_MOTION"
        case .insufficientFeatures: return "INSUFFICIENT_FEATURES"
        default: return "NONE"
        }
    }

    /// Haptic pulses from `HapticMap` (tick = light impact, confirm = success notification).
    private func play(_ pulses: [HapticMap.Pulse]) {
        for p in pulses {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(p.delayMs))) { [weak self] in
                guard let self else { return }
                switch p.kind {
                case .tick: self.impact.impactOccurred()
                case .confirm: self.notify.notificationOccurred(.success)
                }
            }
        }
    }
}
#endif
