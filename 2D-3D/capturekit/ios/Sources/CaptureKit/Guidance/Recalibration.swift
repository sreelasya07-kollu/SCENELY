import Foundation

/// Recalibration prompt state (issue #1, ADR 0031). The core owns the decision (one C++ implementation for every platform): it emits
/// `trackingLost` when tracking has been degraded for 2 s and `trackingReset` when it is back and steady. This only mirrors those events
/// for the HUD. Immutable and pure (Foundation only), so it is host-testable; the capture screen keeps the latest value and applies each
/// core event with `on`. Port of the Kotlin Recalibration (S-lib guidance/Recalibration.kt).
public struct Recalibration: Equatable {
    /// The facts of one completed recovery (the payload of `CoreEvent.trackingReset`).
    public struct Reset: Equatable {
        public let tNs: Int64
        public let lostS: Double
        public let driftM: Double
        public let driftDeg: Double
        public init(tNs: Int64, lostS: Double, driftM: Double, driftDeg: Double) {
            self.tNs = tNs; self.lostS = lostS; self.driftM = driftM; self.driftDeg = driftDeg
        }
    }

    /// The prompt is on screen: between trackingLost and trackingReset of the current session.
    public let active: Bool
    /// long_text of the latest RECALIBRATE instruction (the core's sentence); empty until one arrives.
    public let text: String
    /// Completed recoveries in this session and the most recent one (drift delta for a debug line or log).
    public let resets: Int
    public let lastReset: Reset?

    public init(active: Bool = false, text: String = "", resets: Int = 0, lastReset: Reset? = nil) {
        self.active = active; self.text = text; self.resets = resets; self.lastReset = lastReset
    }

    /// Core instruction type name (guide::type_name).
    public static let recalibrate = "RECALIBRATE"
    public static let title = "Recalibrating"
    public static let fallback = "Slowly turn your phone in a small circle."
    private static let ended: Set<String> = ["FINALIZING", "COMPLETE", "FAILED"]

    /// The next state after one core event. Events that do not concern recalibration return an equal value.
    public func on(_ e: CoreEvent) -> Recalibration {
        switch e {
        case .trackingLost:
            return active ? self : Recalibration(active: true, text: text, resets: resets, lastReset: lastReset)
        case .trackingReset(let tNs, let lostS, let driftM, let driftDeg):
            return Recalibration(active: false, text: text, resets: resets + 1,
                                 lastReset: Reset(tNs: tNs, lostS: lostS, driftM: driftM, driftDeg: driftDeg))
        case .instruction(_, let type, _, let longText, _, _, _):
            // Text only: visibility follows trackingLost / trackingReset, so a late instruction can never re-open the prompt.
            if type == Recalibration.recalibrate && !longText.isEmpty && longText != text {
                return Recalibration(active: active, text: longText, resets: resets, lastReset: lastReset)
            }
            return self
        case .stateChange(_, let to, _):
            return Recalibration.ended.contains(to) ? Recalibration() : self
        default:
            return self
        }
    }

    /// Body text for the overlay: the core's sentence, or a minimal fallback until the first RECALIBRATE arrives.
    public var prompt: String { text.isEmpty ? Recalibration.fallback : text }
}
