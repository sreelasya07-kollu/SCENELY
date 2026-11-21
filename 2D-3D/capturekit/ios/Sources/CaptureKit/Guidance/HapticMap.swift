import Foundation

/// Maps the core's Instruction.haptic name ("none" | "tap" | "double" | "success") to a pulse plan. Pure (Foundation only), host-testable.
/// The app plays `tick` as a light impact and `confirm` as a success notification (UIKit feedback generators). Port of the Kotlin HapticMap.
public enum HapticMap {
    public enum Kind: Equatable { case tick, confirm }

    public struct Pulse: Equatable {
        public let kind: Kind
        public let delayMs: Int64
        public init(_ kind: Kind, _ delayMs: Int64) { self.kind = kind; self.delayMs = delayMs }
    }

    private static let doubleGapMs: Int64 = 140

    public static func pulses(_ haptic: String, priority: Int = 2) -> [Pulse] {
        switch haptic {
        case "none": return []
        case "tap": return [Pulse(.tick, 0)]
        case "double": return [Pulse(.tick, 0), Pulse(.tick, doubleGapMs)]
        case "success": return [Pulse(.confirm, 0)]
        default: return priority >= 3 ? [Pulse(.tick, 0), Pulse(.tick, doubleGapMs)] : []
        }
    }
}
