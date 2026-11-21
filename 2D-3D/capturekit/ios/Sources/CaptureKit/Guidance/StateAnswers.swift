import Foundation

/// Questions the app can answer about the scan from a `ScanStateSnapshot` alone.
public enum StateQuestion { case missing, progress }

/// A spoken/shown answer. `cites` are region names that exist in the snapshot; empty when `abstained` or a whole-room statement.
public struct Answer: Equatable {
    public let text: String
    public let abstained: Bool
    public let cites: [String]
    public init(text: String, abstained: Bool, cites: [String] = []) { self.text = text; self.abstained = abstained; self.cites = cites }
}

/// Fixed-template answers over the last overlay snapshot (ADR 0019). No LLM, no network, no guessing: if the snapshot is
/// missing, empty or tracking is lost, or the question is unknown, the answer is `abstain`. Port of the Kotlin StateAnswers.
public enum StateAnswers {
    public static let abstain = "I am not sure yet. Keep scanning."
    /// A wall below this percentage counts as not fully scanned.
    public static let wallDonePct = 80
    /// Completeness at or above this lets "what is missing" say the scan can be finished.
    public static let finishCompleteness = 0.9
    private static let maxListed = 3
    private static let abstained = Answer(text: abstain, abstained: true)

    /// Voice shell entry: only `VoiceIntent.missing` is a state question.
    public static func questionFor(_ intent: VoiceIntent) -> StateQuestion? { intent == .missing ? .missing : nil }

    public static func answer(_ question: StateQuestion?, _ snapshot: ScanStateSnapshot?) -> Answer {
        guard let q = question, let s = snapshot, s.hasScanData, s.tracking != 3 else { return abstained }
        switch q {
        case .missing: return missing(s)
        case .progress: return progress(s)
        }
    }

    private static func missing(_ s: ScanStateSnapshot) -> Answer {
        var items: [(String, String?)] = []
        if !s.wallFound && s.walls.isEmpty { items.append(("no wall found yet", nil)) }
        // Stable sort by pct ascending.
        let sorted = s.walls.enumerated().sorted { a, b in a.element.pct != b.element.pct ? a.element.pct < b.element.pct : a.offset < b.offset }.map { $0.element }
        for w in sorted where w.pct < wallDonePct { items.append(("\(w.name), \(w.pct) percent", w.name)) }
        if !s.floorFound { items.append(("the floor", nil)) }
        // The ceiling is optional for completeness: never listed as missing.
        for g in s.gaps { items.append((g, g)) }
        if items.isEmpty {
            return s.completeness >= finishCompleteness
                ? Answer(text: "Nothing is missing. You can finish.", abstained: false)
                : Answer(text: "Nothing specific yet. Keep scanning.", abstained: false)
        }
        let shown = Array(items.prefix(maxListed))
        let more = items.count - shown.count
        let text = "Missing: " + shown.map { $0.0 }.joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "") + "."
        return Answer(text: text, abstained: false, cites: shown.compactMap { $0.1 })
    }

    private static func progress(_ s: ScanStateSnapshot) -> Answer {
        let pct = min(max(Int((s.completeness * 100.0).rounded(.toNearestOrAwayFromZero)), 0), 100)
        let n = s.wallCount
        let wallText = n == 0 ? "no walls found yet" : (n == 1 ? "1 wall found" : "\(n) walls found")
        return Answer(text: "Scan is \(pct) percent complete, \(wallText).", abstained: false)
    }
}
