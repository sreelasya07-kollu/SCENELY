import Foundation

/// One plain-language status pill merging ARKit tracking, the core's frame-quality reasons and the thermal policy level.
/// Priority: tracking lost > too fast > hold steady > more light > warming up > good. Port of the Kotlin StatusPill.
public enum StatusPill {
    public enum Tone: UInt32 {
        case good = 0xFF2E7D32, warn = 0xFFEF8F00, bad = 0xFFC62828, neutral = 0xFF455A64
        public var argb: UInt32 { rawValue }
    }

    public struct Pill: Equatable {
        public let text: String
        public let tone: Tone
        public init(_ text: String, _ tone: Tone) { self.text = text; self.tone = tone }
    }

    /// Every reason code the core quality module emits.
    public static let reasonCodes = [
        "TRACKING_LOST", "TRACKING_LIMITED", "MOTION_BLUR", "BLUR", "SOFT_FOCUS", "OVEREXPOSED", "UNDEREXPOSED",
        "LOW_TEXTURE", "POOR_SPREAD", "NO_IMAGE", "NOT_NOVEL", "MIN_GAP", "NOT_BEST", "RECALIBRATING", "DUPLICATE",
    ]

    public static let lost = Pill("Tracking lost", .bad)
    public static let recalibrating = Pill("Recalibrating", .bad)
    public static let tooFast = Pill("Move slower", .warn)
    public static let hold = Pill("Hold steady", .warn)
    public static let light = Pill("More light", .warn)
    public static let hot = Pill("Phone is hot", .warn)
    public static let warming = Pill("Warming up", .warn)
    public static let keepGoing = Pill("Keep going", .good)
    public static let good = Pill("Good", .good)
    public static let starting = Pill("Starting...", .neutral)

    /// Lower = more urgent.
    private static func rank(_ p: Pill) -> Int {
        switch p {
        case lost: return 0
        case recalibrating: return 1
        case tooFast: return 2
        case hold: return 3
        case light: return 4
        case hot: return 5
        case warming: return 6
        case keepGoing: return 7
        case good: return 8
        default: return 9
        }
    }

    /// Plain phrase for one core quality reason code; nil = the reason never affects the pill. Unknown codes fall back to "Keep going".
    public static func forReason(_ code: String) -> Pill? {
        switch code {
        case "TRACKING_LOST": return lost
        case "RECALIBRATING": return recalibrating
        case "MOTION_BLUR": return tooFast
        case "SOFT_FOCUS", "BLUR": return hold
        case "UNDEREXPOSED": return light
        case "NOT_NOVEL", "MIN_GAP", "NOT_BEST", "DUPLICATE": return nil
        default: return keepGoing
        }
    }

    /// Plain phrase for a tracking state name ("TRACKING", "STOPPED", "PAUSED", ...) + failure reason name (nil = no verdict).
    /// "Starting..." only until tracking has first been reached (`everTracked`); after that a pause is "Hold steady".
    public static func forTracking(_ trackState: String, _ failure: String, everTracked: Bool = false) -> Pill? {
        switch trackState {
        case "TRACKING": return nil
        case "STOPPED": return lost
        case "PAUSED":
            switch failure {
            case "EXCESSIVE_MOTION": return tooFast
            case "INSUFFICIENT_LIGHT": return light
            case "NONE": return everTracked ? hold : starting
            default: return hold
            }
        default: return everTracked ? hold : starting
        }
    }

    /// Thermal policy level (0 NOMINAL .. 5 SAFE_PAUSE) to a pill, nil when nominal.
    public static func forThermal(_ level: Int) -> Pill? {
        if level >= 4 { return hot }
        if level >= 1 { return warming }
        return nil
    }

    /// The single pill: the most urgent of tracking, quality reasons and thermal. While tracking has not started
    /// ("Starting...") nothing else is shown. No (relevant) reasons and nominal thermal = "Good".
    public static func statusPill(trackState: String, failure: String, reasons: [String], thermalLevel: Int, everTracked: Bool = false) -> Pill {
        let t = forTracking(trackState, failure, everTracked: everTracked)
        if t == starting { return starting }
        var best = t ?? good
        for r in reasons { if let p = forReason(r), rank(p) < rank(best) { best = p } }
        if let th = forThermal(thermalLevel), rank(th) < rank(best) { best = th }
        return best
    }
}
