import Foundation

/// Pure scheduling logic for spoken guidance (no AVFoundation types, time is passed in). Text always comes from the
/// core's templates; this only decides whether/when to say it. Not thread-safe: callers synchronize.
/// Priorities follow the core: 3 = urgent, 2 = guidance, 1 = info. Port of the Kotlin SpeechScheduler.
public final class SpeechScheduler {
    public struct Config {
        public var minGapMs: Int64 = 2_000
        public var maxPerMinute: Int = 6
        public var repeatWindowMs: Int64 = 12_000
        public var pendingTtlMs: Int64 = 4_000
        public var urgentPriority: Int = 3
        public var speakTimeoutMs: Int64 = 10_000
        public init() {}
    }

    public enum Action: Equatable {
        case speak(utteranceId: String, text: String, priority: Int, flush: Bool)
        case queued
        case drop(reason: String)
    }

    private struct Pending { let id: Int; let text: String; let priority: Int; let atMs: Int64 }

    private let cfg: Config
    public var enabled = true
    /// Called when a queued line is discarded unspoken: replaced by a newer line or past pendingTtlMs.
    public var onStale: (() -> Void)?
    private var seenIds = Set<Int>()
    private var lastSaid: [String: Int64] = [:]
    private var startTimes: [Int64] = []
    private var speakingId: String?
    private var speakingPriority = 0
    private var lastEndMs = Int64.min / 2
    private var lastStartMs = Int64.min / 2
    private var pending: Pending?
    private var manualSeq = 0

    /// Last text issued for speech. Survives `reset` so "repeat" works after a pause.
    public private(set) var lastText: String?

    public static let manualPriority = 2

    public init(_ cfg: Config = Config()) { self.cfg = cfg }

    public func isSpeaking() -> Bool { speakingId != nil }

    /// Watchdog: an utterance issued/started more than speakTimeoutMs ago with no onDone = the engine is stuck.
    /// Clears the speaking state and returns true so the caller can stop the engine.
    @discardableResult
    public func expireStuck(_ nowMs: Int64) -> Bool {
        if speakingId == nil || nowMs - lastStartMs < cfg.speakTimeoutMs { return false }
        speakingId = nil; speakingPriority = 0; lastEndMs = nowMs
        return true
    }

    public func onInstruction(id: Int, text: String, priority: Int, nowMs: Int64) -> Action {
        expireStuck(nowMs)
        if !enabled { return .drop(reason: "muted") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .drop(reason: "empty") }
        if seenIds.contains(id) { return .drop(reason: "repeat") }
        if let prev = lastSaid[text], nowMs - prev < cfg.repeatWindowMs { seenIds.insert(id); return .drop(reason: "repeat") }
        let urgent = priority >= cfg.urgentPriority
        if speakingId != nil {
            if priority > speakingPriority { return speak(id, text, priority, nowMs, flush: true) }
            if priority == speakingPriority {
                seenIds.insert(id)
                if pending != nil { onStale?() }
                pending = Pending(id: id, text: text, priority: priority, atMs: nowMs)
                return .queued
            }
            return .drop(reason: "busy")
        }
        if !urgent {
            if nowMs - max(lastEndMs, lastStartMs) < cfg.minGapMs { return .drop(reason: "gap") }
            while let f = startTimes.first, nowMs - f >= 60_000 { startTimes.removeFirst() }
            if startTimes.count >= cfg.maxPerMinute { return .drop(reason: "budget") }
        }
        return speak(id, text, priority, nowMs, flush: false)
    }

    /// Voice-command speech (answer to "what is missing", volume feedback): user-requested, so it bypasses the repeat
    /// window, the gap and the per-minute budget, and cuts any current utterance. Muted or blank = drop.
    /// `remember` false keeps `lastText` (so "repeat" does not repeat "Louder").
    public func speakNow(_ text: String, nowMs: Int64, remember: Bool = true) -> Action {
        expireStuck(nowMs)
        if !enabled { return .drop(reason: "muted") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .drop(reason: "empty") }
        manualSeq += 1
        let id = -manualSeq   // negative ids never collide with the core's instruction ids
        return speak(id, text, Self.manualPriority, nowMs, flush: speakingId != nil, countBudget: false, remember: remember)
    }

    /// "Repeat that": the last spoken text again, bypassing the repeat window. Nothing said yet = drop("nothing").
    public func repeatLast(nowMs: Int64) -> Action {
        guard let t = lastText else { return .drop(reason: "nothing") }
        return speakNow(t, nowMs: nowMs)
    }

    private func speak(_ id: Int, _ text: String, _ priority: Int, _ nowMs: Int64, flush: Bool,
                       countBudget: Bool = true, remember: Bool = true) -> Action {
        seenIds.insert(id)
        lastSaid[text] = nowMs
        if countBudget { startTimes.append(nowMs) }
        if remember { lastText = text }
        speakingId = "ck-\(id)"; speakingPriority = priority; lastStartMs = nowMs
        if flush && pending != nil { pending = nil; onStale?() }
        return .speak(utteranceId: "ck-\(id)", text: text, priority: priority, flush: flush)
    }

    public func onStart(_ utteranceId: String, nowMs: Int64) { if utteranceId == speakingId { lastStartMs = nowMs } }

    /// Utterance finished, errored or was stopped.
    public func onDone(_ utteranceId: String, nowMs: Int64) {
        if utteranceId != speakingId { return }   // a flushed utterance finishing late must not clear its successor
        speakingId = nil; speakingPriority = 0; lastEndMs = nowMs
    }

    /// After onDone: the queued line to speak now, if it is still fresh.
    public func nextPending(nowMs: Int64) -> Action? {
        guard let p = pending else { return nil }
        if speakingId != nil { return nil }
        pending = nil
        if !enabled { return nil }
        if nowMs - p.atMs > cfg.pendingTtlMs { onStale?(); return nil }
        return speak(p.id, p.text, p.priority, nowMs, flush: false)
    }

    public func reset() {
        seenIds.removeAll(); lastSaid.removeAll(); startTimes.removeAll()
        speakingId = nil; speakingPriority = 0; pending = nil
    }
}
