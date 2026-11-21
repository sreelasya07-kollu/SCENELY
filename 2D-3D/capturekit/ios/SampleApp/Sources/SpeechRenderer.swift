import AVFoundation
import CaptureKit
import Foundation

/// Speaks the core's guidance templates verbatim with AVSpeechSynthesizer (on-device voices only, no network path). Scheduling
/// (priority preemption, repeat suppression, budget) lives in `SpeechScheduler` (CaptureKit, host-tested); this class owns the
/// synthesizer, the audio session and the volume step. Main thread only (the synthesizer callbacks hop to it).
/// UNVERIFIED on a device: audio ducking, voice availability, `stopSpeaking(at: .immediate)` ordering with the scheduler.
final class SpeechRenderer: NSObject, ScanSpeech, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let sched = SpeechScheduler()
    private var utteranceIds: [ObjectIdentifier: String] = [:]
    private var volume: VolumeSteps
    private var watchdog: Timer?

    /// False when the phone has no usable English voice (we never fall back to anything networked).
    let available: Bool
    /// True while the microphone listens: guidance is dropped so the recogniser never hears the app's own voice.
    var holdOff = false

    var enabled: Bool {
        get { sched.enabled }
        set {
            sched.enabled = newValue
            Prefs.voiceEnabled = newValue
            if !newValue { stopNow() }
        }
    }

    override init() {
        volume = VolumeSteps(initialIndex: Prefs.app.object(forKey: Prefs.voiceVolumeKey) as? Int ?? VolumeSteps.defaultIndex)
        available = AVSpeechSynthesisVoice(language: "en-US") != nil
        super.init()
        sched.enabled = Prefs.voiceEnabled
        synth.delegate = self
    }

    private static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Entry point for a core instruction (`speakText` is the template output, spoken as is).
    func onInstruction(id: Int, text: String, priority: Int) {
        guard available, !holdOff else { return }
        play(sched.onInstruction(id: id, text: text, priority: priority, nowMs: Self.nowMs()))
    }

    /// Speaks a voice-command answer now (cuts current speech, outside the guidance budget). False = not spoken.
    @discardableResult
    func say(_ text: String, remember: Bool) -> Bool {
        guard available else { return false }
        let a = sched.speakNow(text, nowMs: Self.nowMs(), remember: remember)
        if case .speak = a { play(a); return true }
        return false
    }

    /// "Repeat that": the last spoken line again. False = nothing to repeat, muted or no voice.
    func repeatLast() -> Bool {
        guard available else { return false }
        let a = sched.repeatLast(nowMs: Self.nowMs())
        if case .speak = a { play(a); return true }
        return false
    }

    func louder() -> Bool { let ok = volume.louder(); Prefs.app.set(volume.index, forKey: Prefs.voiceVolumeKey); return ok }
    func quieter() -> Bool { let ok = volume.quieter(); Prefs.app.set(volume.index, forKey: Prefs.voiceVolumeKey); return ok }

    private func play(_ a: SpeechScheduler.Action) {
        guard case let .speak(uid, text, _, flush) = a else { return }
        activateAudio()
        if flush && synth.isSpeaking { synth.stopSpeaking(at: .immediate) }   // the cancelled utterance reports didCancel: the scheduler ignores that stale id
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.volume = volume.volume
        utteranceIds[ObjectIdentifier(u)] = uid
        synth.speak(u)
        armWatchdog()
    }

    /// Stops speaking immediately and forgets queued lines (pause, finish, mute).
    func stopNow() {
        watchdog?.invalidate(); watchdog = nil
        synth.stopSpeaking(at: .immediate)
        utteranceIds.removeAll()
        sched.reset()
        deactivateAudio()
    }

    func release() { stopNow(); synth.delegate = nil }

    // MARK: audio session

    private func activateAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? s.setActive(true)
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: engine stuck watchdog (the engine never reported didStart/didFinish)

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 10.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.sched.expireStuck(Self.nowMs()) {
                self.synth.stopSpeaking(at: .immediate); self.utteranceIds.removeAll()
                if let next = self.sched.nextPending(nowMs: Self.nowMs()) { self.play(next) } else { self.deactivateAudio() }
            }
        }
    }

    // MARK: AVSpeechSynthesizerDelegate (hop to the main thread)

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in
            if let uid = utteranceIds[ObjectIdentifier(utterance)] { sched.onStart(uid, nowMs: Self.nowMs()) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { ended(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { ended(utterance) }

    private func ended(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [self] in
            guard let uid = utteranceIds.removeValue(forKey: ObjectIdentifier(utterance)) else { return }
            let now = Self.nowMs()
            sched.onDone(uid, nowMs: now)
            if let next = sched.nextPending(nowMs: now) { play(next) }
            else if !sched.isSpeaking() { watchdog?.invalidate(); watchdog = nil; deactivateAudio() }
        }
    }
}
