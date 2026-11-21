import Foundation

/// What `ScanActions` needs from the speech side. The app's SpeechRenderer implements it; tests use a fake. Main thread only.
public protocol ScanSpeech: AnyObject {
    var enabled: Bool { get }
    /// "Repeat that": false = nothing to repeat, muted or no voice.
    func repeatLast() -> Bool
    /// Speaks a voice-command answer now. False = not spoken (muted / no voice). `remember` false keeps "repeat" on the last guidance line.
    @discardableResult func say(_ text: String, remember: Bool) -> Bool
    /// One step louder / quieter. False at the limit.
    func louder() -> Bool
    func quieter() -> Bool
}

/// The scan screen's side of `ScanActions`.
public protocol ScanActionsHost: AnyObject {
    func isPaused() -> Bool
    func pauseScan()
    func resumeScan()
    func snapshot() -> ScanStateSnapshot?
}

/// The one code path of every in-scan action that is not Start / Finish (ADR 0036): the HUD buttons and the voice commands both call
/// `run`, so a button and a spoken command do exactly the same and say the same. Finish is the explicit Finish button; by voice it
/// first asks for a yes/no confirmation and then takes the same Finish path. Port of the Kotlin ScanActions (ADR 0037). Main thread only.
public final class ScanActions {
    public enum Kind: CaseIterable { case pause, resume, repeatLast, missing, louder, quieter }

    /// What to show: `text` for `ms` on the feedback line (nil = nothing to show).
    public struct Outcome: Equatable {
        public let text: String?
        public let ms: Int
        public init(_ text: String?, _ ms: Int) { self.text = text; self.ms = ms }
    }

    private let speech: ScanSpeech
    private weak var host: ScanActionsHost?

    public init(speech: ScanSpeech, host: ScanActionsHost) { self.speech = speech; self.host = host }

    public func run(_ kind: Kind) -> Outcome {
        guard let host else { return Outcome(nil, 0) }
        switch kind {
        case .pause:
            if host.isPaused() { return Outcome("Already paused.", 3_000) }
            host.pauseScan(); return Outcome("Paused.", 3_000)
        case .resume:
            if !host.isPaused() { return Outcome("Already scanning.", 3_000) }
            host.resumeScan(); return Outcome("Resuming.", 3_000)
        case .repeatLast:
            if speech.repeatLast() { return Outcome(nil, 0) }
            return Outcome(speech.enabled ? "Nothing to repeat yet." : "Voice guidance is off. Turn it on to hear it again.", 4_000)
        case .missing:
            let a = StateAnswers.answer(StateAnswers.questionFor(.missing), host.snapshot())
            speech.say(a.text, remember: true)
            return Outcome(a.text, 9_000)   // always visible, also when voice guidance is muted
        case .louder: return volume(speech.louder(), "Louder.", "Already at the loudest.")
        case .quieter: return volume(speech.quieter(), "Quieter.", "Already at the quietest.")
        }
    }

    private func volume(_ changed: Bool, _ done: String, _ limit: String) -> Outcome {
        let msg = changed ? done : limit
        speech.say(msg, remember: false)   // spoken at the new level so the change is audible
        return Outcome(msg, 3_000)
    }

    /// Voice intent -> action; nil for `.finish` (confirmed first, then the Finish path).
    public static func kind(of intent: VoiceIntent) -> Kind? {
        switch intent {
        case .pause: return .pause
        case .resume: return .resume
        case .repeatLast: return .repeatLast
        case .missing: return .missing
        case .louder: return .louder
        case .quieter: return .quieter
        case .finish: return nil
        }
    }
}
