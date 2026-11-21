import AVFoundation
import CaptureKit
import Foundation
import Speech

enum MicState { case idle, listening, thinking, needsPermission }

/// What the scan screen offers the voice controller. All calls are on the main thread.
protocol VoiceHost: AnyObject {
    /// Plain-language rationale before the system permission prompts; `answer(true)` = go on and ask.
    func voiceAskRationale(_ answer: @escaping (Bool) -> Void)
    /// "Finish the scan?" question (yes/no by voice or by tap).
    func voiceAskFinish()
    func voiceDismissFinish()
    /// Only after the user confirmed (spoken yes).
    func voiceFinishConfirmed()
    /// Short line under the top bar; nil clears it.
    func voiceFeedback(_ text: String?, ms: Int)
    func voiceStateChanged()
}

/// Push-to-talk voice commands on the ON-DEVICE recogniser only (`requiresOnDeviceRecognition = true`; when
/// `supportsOnDeviceRecognition` is false voice commands are off with a message, the buttons still work). The microphone listens only
/// after the user taps Mic. Phrases and parsing live in the tested `VoiceIntentParser`; every command except Finish goes through
/// `ScanActions` (the same path as the buttons); Finish asks a yes/no first. Guidance speech is held off while listening.
/// UNVERIFIED on a device: on-device availability per locale, audio session switching, latency.
final class VoiceController {
    private enum Mode { case command, confirm }

    private let speech: SpeechRenderer
    private let actions: ScanActions
    private weak var host: VoiceHost?
    private let parser: VoiceIntentParser?
    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var tapInstalled = false
    private var mode = Mode.command
    private var permissionAsked = false
    private var lastHypotheses: [Hypothesis] = []
    private var listenTimer: Timer?, hardTimer: Timer?, silenceTimer: Timer?

    private(set) var state = MicState.idle
    /// True once an on-device English recogniser exists. The mic chip is hidden until then.
    private(set) var available = false
    /// Plain reason when `available` is false.
    private(set) var unavailableReason: String?

    private static let listenSeconds = 6.0, hardSeconds = 2.5, silenceSeconds = 1.0
    private static let notHeard = "I did not hear a command. Tap Mic and try again."
    private static let notUnderstood = "I did not catch that. Say pause, resume, repeat, what is missing, finish, louder or quieter."

    init(speech: SpeechRenderer, actions: ScanActions, host: VoiceHost) {
        self.speech = speech; self.actions = actions; self.host = host
        parser = PhraseTables.forLocale("en").flatMap { try? VoiceIntentParser($0) }
        probe()
    }

    var micState: MicState { state == .idle && !permissionsGranted ? .needsPermission : state }

    private var permissionsGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
    }

    // MARK: availability

    private func probe() {
        guard parser != nil else { return unavailable("Voice commands could not start on this phone. The buttons still work.") }
        // en-IN first (like Android), then en-US; the first recogniser that can run on the device wins.
        for tag in ["en-IN", "en-US"] {
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: tag)), r.isAvailable else { continue }
            if r.supportsOnDeviceRecognition { recognizer = r; available = true; unavailableReason = nil; return }
        }
        unavailable("This phone has no offline speech recogniser. The buttons still work.")
    }

    private func unavailable(_ why: String) {
        available = false; unavailableReason = why; recognizer = nil
        NSLog("CK/Voice: voice commands unavailable: %@", why)
        host?.voiceStateChanged()
    }

    // MARK: permissions (asked once, before Start, never in the middle of a scan)

    /// Start pressed: asks for speech recognition + microphone (rationale first) BEFORE the scan runs. `proceed` runs exactly once:
    /// at once when voice is unavailable, permitted, or already asked this session; otherwise after the user answers.
    func ensurePermissionThen(_ proceed: @escaping () -> Void) {
        if !available || permissionsGranted || permissionAsked { proceed(); return }
        guard let host else { proceed(); return }
        host.voiceAskRationale { [weak self] allow in
            guard let self else { proceed(); return }
            self.permissionAsked = true
            guard allow else { self.host?.voiceStateChanged(); proceed(); return }
            SFSpeechRecognizer.requestAuthorization { speechStatus in
                AVAudioApplication.requestRecordPermission { micOK in
                    DispatchQueue.main.async {
                        if speechStatus != .authorized || !micOK {
                            self.host?.voiceFeedback("The microphone is off, so voice commands are off. Allow it in Settings. The buttons still work.", ms: 8_000)
                        }
                        self.host?.voiceStateChanged()
                        proceed()
                    }
                }
            }
        }
    }

    // MARK: push to talk

    /// Mic chip tapped.
    func onMicTapped() {
        guard available else { return }
        switch state {
        case .listening: cancelListening(); host?.voiceFeedback(nil, ms: 0)
        case .thinking: break
        default:
            if !permissionsGranted {
                host?.voiceFeedback("Voice commands need the microphone and speech recognition. Allow them in Settings. The buttons still work.", ms: 8_000)
            } else { startListening(.command) }
        }
    }

    /// The finish question was closed by a tap: stop listening for its answer.
    func finishDialogClosed() { if mode == .confirm && state != .idle { cancelListening() } }

    /// Leaving the screen: stop listening.
    func onPause() { cancelListening() }

    func release() { cancelListening(); recognizer = nil }

    private func startListening(_ m: Mode) {
        guard let recognizer, state == .idle else { return }
        mode = m
        lastHypotheses = []
        speech.holdOff = true   // before stopNow: nothing may start speaking in between
        speech.stopNow()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true   // never the server
            req.shouldReportPartialResults = true
            req.taskHint = .confirmation
            req.contextualStrings = PhraseTables.en.phrases.values.flatMap { $0 }
            request = req
            let input = engine.inputNode
            if tapInstalled { input.removeTap(onBus: 0) }
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak req] buf, _ in req?.append(buf) }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            generation += 1
            let gen = generation
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async { self?.onRecognition(gen, result, error) }
            }
        } catch {
            NSLog("CK/Voice: could not start listening: %@", String(describing: error))
            teardown()
            host?.voiceFeedback("Could not start listening. Try again.", ms: 4_000)
            return
        }
        setState(.listening)
        listenTimer = Timer.scheduledTimer(withTimeInterval: Self.listenSeconds, repeats: false) { [weak self] _ in self?.beginThinking() }
    }

    /// Listening window over (or silence after speech): ask the recogniser for what it heard so far.
    private func beginThinking() {
        guard state == .listening else { return }
        listenTimer?.invalidate(); silenceTimer?.invalidate()
        setState(.thinking)
        request?.endAudio()
        hardTimer?.invalidate()
        hardTimer = Timer.scheduledTimer(withTimeInterval: Self.hardSeconds, repeats: false) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            NSLog("CK/Voice: no recogniser result after the timeout: cancelled")
            self.cancelListening()
            self.host?.voiceFeedback(Self.notHeard, ms: 5_000)
        }
    }

    private func onRecognition(_ gen: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard gen == generation, state != .idle else { return }   // cancelled meanwhile, or a stale task
        if let result {
            lastHypotheses = result.transcriptions.map { t in
                let c = t.segments.map { $0.confidence }
                let avg = c.isEmpty ? 0 : c.reduce(0, +) / Float(c.count)
                return Hypothesis(t.formattedString, avg > 0 ? avg : nil)
            }
            if result.isFinal { handle(lastHypotheses); return }
            if state == .listening {   // end of speech = a short silence after the last words
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: Self.silenceSeconds, repeats: false) { [weak self] _ in self?.beginThinking() }
            }
        }
        if error != nil {
            if !lastHypotheses.isEmpty { handle(lastHypotheses); return }
            teardown()
            host?.voiceFeedback(Self.notHeard, ms: 5_000)
        }
    }

    private func handle(_ hyps: [Hypothesis]) {
        let m = mode
        teardown()
        guard let parser else { return }
        if m == .confirm {
            switch parser.parseConfirmation(hyps) {
            case .yes: host?.voiceDismissFinish(); host?.voiceFinishConfirmed()
            case .no: host?.voiceDismissFinish(); host?.voiceFeedback("Okay, still scanning.", ms: 3_000)
            case .unknown: host?.voiceFeedback("Tap Finish or Keep scanning.", ms: 5_000)
            }
            return
        }
        switch parser.parse(hyps) {
        case .match(let match): act(match.intent)
        case .noMatch: host?.voiceFeedback(Self.notUnderstood, ms: 6_000)
        }
    }

    private func act(_ intent: VoiceIntent) {
        guard let kind = ScanActions.kind(of: intent) else {   // finish: yes/no first, then the Finish path
            host?.voiceAskFinish()
            startListening(.confirm)
            return
        }
        let o = actions.run(kind)
        if let t = o.text { host?.voiceFeedback(t, ms: o.ms) }
    }

    private func cancelListening() { teardown() }

    private func teardown() {
        listenTimer?.invalidate(); hardTimer?.invalidate(); silenceTimer?.invalidate()
        listenTimer = nil; hardTimer = nil; silenceTimer = nil
        generation += 1   // late callbacks of the old task are ignored
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }   // never touch inputNode before the first listen
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        let wasActive = state != .idle
        speech.holdOff = false
        if wasActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        setState(.idle)
    }

    private func setState(_ s: MicState) { if state != s { state = s; host?.voiceStateChanged() } }
}
