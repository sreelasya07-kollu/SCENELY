import Foundation

/// Spoken-command parser. Pure Swift, no Speech framework types: the shell hands in the recogniser's N-best list and
/// gets back one intent or noMatch. Vocabulary is closed and lives in `PhraseTable` data per locale; no LLM, no network.
/// Port of the Kotlin VoiceIntent (ADR 0037).
public enum VoiceIntent: CaseIterable, Hashable {
    case pause, resume, repeatLast, missing
    /// Ends the scan: the shell must get a spoken or tap confirmation before acting.
    case finish
    case louder, quieter

    public var requiresConfirmation: Bool { self == .finish }

    /// Kotlin enum name (PAUSE, RESUME, REPEAT, MISSING, FINISH, LOUDER, QUIETER), for messages and logs.
    public var name: String {
        switch self {
        case .pause: return "PAUSE"
        case .resume: return "RESUME"
        case .repeatLast: return "REPEAT"
        case .missing: return "MISSING"
        case .finish: return "FINISH"
        case .louder: return "LOUDER"
        case .quieter: return "QUIETER"
        }
    }
}

/// One recogniser hypothesis. `confidence` in 0..1; nil or <= 0 means "not reported".
public struct Hypothesis: Equatable {
    public let text: String
    public let confidence: Float?
    public init(_ text: String, _ confidence: Float? = nil) { self.text = text; self.confidence = confidence }
}

public struct VoiceMatch: Equatable {
    public let intent: VoiceIntent
    public let score: Float
    public let heard: String
    public var needsConfirmation: Bool { intent.requiresConfirmation }
}

public enum VoiceParse: Equatable {
    case match(VoiceMatch)
    case noMatch(String)
}

public enum Confirmation { case yes, no, unknown }

/// Locale vocabulary as data. Phrases are normalised with the same rules as the utterance. Add a locale by adding another
/// `PhraseTable` to `PhraseTables.all`; the parser has no language-specific code.
public struct PhraseTable {
    public var locale: String
    public var phrases: [VoiceIntent: [String]]
    /// Words dropped before matching ("um", "please"). Multi-word fillers allowed.
    public var fillers: [String]
    /// Any of these tokens anywhere in the utterance -> noMatch (never act on "don't stop").
    public var negations: [String]
    public var yes: [String]
    public var no: [String]

    public init(locale: String, phrases: [VoiceIntent: [String]], fillers: [String], negations: [String], yes: [String], no: [String]) {
        self.locale = locale; self.phrases = phrases; self.fillers = fillers; self.negations = negations; self.yes = yes; self.no = no
    }
}

public enum PhraseTables {
    public static let en = PhraseTable(
        locale: "en",
        phrases: [
            .pause: [
                "pause", "stop", "hold on", "hold", "wait", "pause scan", "pause the scan",
                "pause scanning", "stop scan", "stop the scan", "stop scanning", "take a break",
            ],
            .resume: [
                "resume", "continue", "go on", "carry on", "keep going", "resume scan",
                "resume the scan", "resume scanning", "continue scan", "continue scanning",
                "unpause", "go again",
            ],
            .repeatLast: [
                "repeat", "repeat that", "say again", "say that again", "say it again",
                "what did you say", "come again", "pardon",
            ],
            .missing: [
                "what is missing", "what's missing", "what is left", "what's left",
                "how much is left", "how much left", "how much more", "what remains",
                "what else", "what is left to scan", "what's left to scan", "where next", "what next",
                "what's next", "missing",
            ],
            .finish: [
                "finish", "finish scan", "finish the scan", "finish scanning", "i'm done",
                "i am done", "done", "end scan", "end the scan", "we're done", "all done",
                "complete scan", "that's it",
            ],
            .louder: [
                "louder", "speak up", "volume up", "turn it up", "turn up the volume",
                "can't hear you", "cannot hear you", "more volume",
            ],
            .quieter: [
                "quieter", "softer", "volume down", "turn it down", "turn down the volume",
                "too loud", "less volume", "lower the volume", "lower volume",
            ],
        ],
        fillers: [
            "um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "please", "okay", "ok", "hey",
            "so", "now", "just", "like", "well", "the app", "app", "capturekit", "could you",
            "can you", "would you", "will you", "kindly", "thanks", "thank you",
        ],
        negations: ["don't", "dont", "do not", "not", "never", "no"],
        yes: ["yes", "yeah", "yep", "yup", "sure", "confirm", "correct", "finish", "yes finish", "do it", "go ahead", "affirmative"],
        no: ["no", "nope", "cancel", "don't", "do not", "not yet", "keep scanning", "continue", "wait"])

    public static let all: [String: PhraseTable] = [en.locale: en]

    /// "en-US" -> en table. Unknown language -> nil (shell hides the mic and says so).
    public static func forLocale(_ tag: String) -> PhraseTable? {
        let low = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        let lang = String(low.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return all[tag.lowercased()] ?? all[lang]
    }
}

public struct VoiceIntentParserConfig {
    /// Minimum combined score (match quality x recogniser confidence) to act.
    public var minScore: Float = 0.45
    /// Quality of a phrase found inside a longer utterance vs. an exact match (1.0).
    public var containedQuality: Float = 0.8
    /// Extra tokens tolerated around a contained phrase; more = background talk -> noMatch.
    public var maxExtraTokens: Int = 3
    /// Prior when the recogniser reports no confidence: rankDecay^rank.
    public var rankDecay: Float = 0.8
    /// Two different intents within this score margin -> ambiguous -> noMatch.
    public var ambiguityMargin: Float = 0.1
    public init() {}
}

public enum VoiceIntentParserError: Error, Equatable {
    /// A phrase listed under two intents makes the table ambiguous.
    case phraseUnderSeveralIntents(locale: String, phrases: [String])
}

public final class VoiceIntentParser {
    public typealias Config = VoiceIntentParserConfig

    private struct Entry { let intent: VoiceIntent; let tokens: [String] }
    private enum MatchResult { case hit(VoiceIntent, Float); case miss(String) }

    private let config: Config
    private let fillers: [[String]]
    private let negations: [[String]]
    private let entries: [Entry]
    private let yes: [[String]]
    private let no: [[String]]

    public init(_ table: PhraseTable, config: Config = Config()) throws {
        self.config = config
        let fl = table.fillers.map { VoiceIntentParser.tokens($0) }.filter { !$0.isEmpty }
        // Stable sort by size descending.
        let sortedFillers = fl.enumerated().sorted { a, b in a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset }.map { $0.element }
        self.fillers = sortedFillers
        self.negations = table.negations.map { VoiceIntentParser.tokens($0) }.filter { !$0.isEmpty }
        func strip(_ t: [String]) -> [String] { VoiceIntentParser.stripFillers(t, sortedFillers) }
        var es: [Entry] = []
        for intent in VoiceIntent.allCases {
            for ph in table.phrases[intent] ?? [] {
                let t = strip(VoiceIntentParser.tokens(ph))
                if !t.isEmpty { es.append(Entry(intent: intent, tokens: t)) }
            }
        }
        self.entries = es
        self.yes = table.yes.map { strip(VoiceIntentParser.tokens($0)) }.filter { !$0.isEmpty }
        self.no = table.no.map { strip(VoiceIntentParser.tokens($0)) }.filter { !$0.isEmpty }
        var byTokens: [[String]: Set<VoiceIntent>] = [:]
        for e in es { byTokens[e.tokens, default: []].insert(e.intent) }
        let dup = byTokens.filter { $0.value.count > 1 }.map { $0.key.joined(separator: " ") }.sorted()
        if !dup.isEmpty { throw VoiceIntentParserError.phraseUnderSeveralIntents(locale: table.locale, phrases: dup) }
    }

    public func parse(_ text: String) -> VoiceParse { parse([Hypothesis(text)]) }

    public func parse(_ nBest: [Hypothesis]) -> VoiceParse {
        if nBest.isEmpty { return .noMatch("empty") }
        var best: VoiceMatch?
        var bestOther: VoiceMatch?   // best match of a different intent than `best`
        var lastReason = "no_phrase"
        let pr = priors(nBest)
        for (rank, h) in nBest.enumerated() {
            switch matchOne(h.text) {
            case .hit(let intent, let quality):
                let c = VoiceMatch(intent: intent, score: quality * pr[rank], heard: h.text)
                if let b = best {
                    if c.score > b.score {
                        if b.intent != c.intent { bestOther = b }
                        best = c
                    } else if c.intent != b.intent && (bestOther == nil || c.score > bestOther!.score) {
                        bestOther = c
                    }
                } else {
                    best = c
                }
            case .miss(let reason):
                if rank == 0 { lastReason = reason }
            }
        }
        guard let b = best else { return .noMatch(lastReason) }
        if let o = bestOther, b.score - o.score < config.ambiguityMargin { return .noMatch("ambiguous") }
        if b.score < config.minScore { return .noMatch("low_confidence") }
        return .match(b)
    }

    /// Spoken answer to "Finish the scan?". Same priors and minScore as `parse`. A yes and a no anywhere in the N-best =
    /// unknown, so a finish is never confirmed on a coin flip. Anything unclear is unknown (shell keeps the tap buttons).
    public func parseConfirmation(_ nBest: [Hypothesis]) -> Confirmation {
        let pr = priors(nBest)
        var yesScore: Float = -1
        var noScore: Float = -1
        for (rank, h) in nBest.enumerated() {
            let t = VoiceIntentParser.stripFillers(VoiceIntentParser.tokens(h.text), fillers)
            if t.isEmpty { continue }
            let isNo = no.contains { $0 == t }
            let isYes = yes.contains { $0 == t }
            if isNo && !isYes { noScore = max(noScore, pr[rank]) }
            if isYes && !isNo { yesScore = max(yesScore, pr[rank]) }
        }
        if yesScore >= 0 && noScore >= 0 { return .unknown }
        if yesScore >= config.minScore { return .yes }
        if noScore >= config.minScore { return .no }
        return .unknown
    }

    public func parseConfirmation(_ text: String) -> Confirmation { parseConfirmation([Hypothesis(text)]) }

    /// Recogniser prior per rank. A reported confidence (> 0) is used as is. Unreported (nil or 0) gets rankDecay^rank; if any
    /// hypothesis reports a confidence, that is also capped at rankDecay x the prior of the hypothesis ranked above.
    private func priors(_ nBest: [Hypothesis]) -> [Float] {
        let anyReported = nBest.contains { ($0.confidence ?? 0) > 0 }
        var out = [Float](repeating: 0, count: nBest.count)
        for (rank, h) in nBest.enumerated() {
            if let c = h.confidence, c > 0 {
                out[rank] = min(c, 1)
            } else if anyReported && rank > 0 {
                out[rank] = min(VoiceIntentParser.pow(config.rankDecay, rank), out[rank - 1] * config.rankDecay)
            } else {
                out[rank] = VoiceIntentParser.pow(config.rankDecay, rank)
            }
        }
        return out
    }

    private func matchOne(_ text: String) -> MatchResult {
        let raw = VoiceIntentParser.tokens(text)
        if raw.isEmpty { return .miss("empty") }
        if negations.contains(where: { VoiceIntentParser.indexOf(raw, $0) >= 0 }) { return .miss("negated") }
        let t = VoiceIntentParser.stripFillers(raw, fillers)
        if t.isEmpty { return .miss("filler_only") }
        if let e = entries.first(where: { $0.tokens == t }) { return .hit(e.intent, 1) }
        // Contained phrases: the longest one wins; equal-length phrases of different intents = ambiguous.
        let hits = entries.filter { t.count - $0.tokens.count <= config.maxExtraTokens && VoiceIntentParser.indexOf(t, $0.tokens) >= 0 }
        if hits.isEmpty { return .miss("no_phrase") }
        let longest = hits.map { $0.tokens.count }.max()!
        let longestHits = hits.filter { $0.tokens.count == longest }
        let top = Set(longestHits.map { $0.intent })
        // A shorter phrase of another intent inside the longest one is fine ("stop scanning" vs "stop"), but a shorter one
        // elsewhere in the utterance means two commands were spoken.
        let other = hits.filter { !top.contains($0.intent) }.contains { s in
            !longestHits.contains { VoiceIntentParser.indexOf($0.tokens, s.tokens) >= 0 }
        }
        if top.count > 1 || other { return .miss("ambiguous") }
        return .hit(top.first!, config.containedQuality)
    }

    private static func stripFillers(_ t: [String], _ fillers: [[String]]) -> [String] {
        if fillers.isEmpty { return t }
        var out: [String] = []
        var i = 0
        outer: while i < t.count {
            for f in fillers {
                if i + f.count <= t.count && (0..<f.count).allSatisfy({ t[i + $0] == f[$0] }) { i += f.count; continue outer }
            }
            out.append(t[i]); i += 1
        }
        return out
    }

    /// Lower-case, apostrophes dropped ("what's" -> "whats"), other punctuation -> space.
    public static func tokens(_ text: String) -> [String] {
        var s = ""
        for u in text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "").unicodeScalars {
            s.unicodeScalars.append(CharacterSet.alphanumerics.contains(u) ? u : " ")
        }
        return s.split(separator: " ").map(String.init)
    }

    private static func indexOf(_ hay: [String], _ needle: [String]) -> Int {
        if needle.isEmpty || needle.count > hay.count { return -1 }
        for i in 0...(hay.count - needle.count) where (0..<needle.count).allSatisfy({ hay[i + $0] == needle[$0] }) { return i }
        return -1
    }

    private static func pow(_ b: Float, _ e: Int) -> Float {
        var r: Float = 1
        for _ in 0..<e { r *= b }
        return r
    }
}
