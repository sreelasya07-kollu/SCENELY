import Foundation

/// Discrete spoken-guidance volume for "louder" / "quieter" (AVSpeechUtterance.volume, 0..1). Steps never reach silence:
/// muting is the separate Voice toggle. Port of the Kotlin VolumeSteps.
public struct VolumeSteps {
    public static let levels: [Float] = [0.3, 0.5, 0.7, 0.85, 1.0]
    public static let defaultIndex = 4   // full: unchanged until the user asks for quieter

    public private(set) var index: Int

    public init(initialIndex: Int = VolumeSteps.defaultIndex) {
        index = min(max(initialIndex, 0), VolumeSteps.levels.count - 1)
    }

    public var volume: Float { VolumeSteps.levels[index] }

    /// Moves one step up; false = already at maximum.
    @discardableResult
    public mutating func louder() -> Bool {
        if index >= VolumeSteps.levels.count - 1 { return false }
        index += 1
        return true
    }

    /// Moves one step down; false = already at minimum.
    @discardableResult
    public mutating func quieter() -> Bool {
        if index <= 0 { return false }
        index -= 1
        return true
    }
}
