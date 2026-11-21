import Foundation

/// Feature switches (Swift port of the Kotlin FeatureFlags, ADR 0032/0035/0036/0037).
///
/// Precedence: debug property > user setting (UserDefaults suite "capturekit", keys `ck.*`, contract C4) > `Flags.defaults`.
/// On iOS the "debug property" is a process environment variable `CAPTUREKIT_<NAME>` (see `environmentProp`),
/// read only by debug builds; the property names keep the Android spelling so docs and tests stay 1:1.
public enum FeatureFlags {
    public static let propUnderstanding = "debug.capturekit.understanding"
    public static let propDetector = "debug.capturekit.detector"
    public static let propGuidance = "debug.capturekit.guidance"
    public static let propVoiceCommands = "debug.capturekit.voice_commands"
    public static let propRecalibrateCard = "debug.capturekit.recalibrate_card"
    public static let propSegmentation = "debug.capturekit.segmentation"
    public static let propRecordImu = "debug.capturekit.record_imu"

    /// Understanding level of a guided scan when no property overrides it (ADR 0036).
    public static let defaultUnderstanding = 2

    /// User settings keys (UserDefaults suite `userDefaultsSuite`, Bool; contract C4).
    public static let prefGuidance = "ck.guidance"
    public static let prefVoiceCommands = "ck.voice_commands"
    public static let prefRecalibrateCard = "ck.recalibrate_card"
    public static let prefRecordImu = "ck.record_imu"
    public static let prefObjectBoxes = "ck.object_boxes"
    public static let prefKeys: [String] = [prefGuidance, prefVoiceCommands, prefRecalibrateCard, prefRecordImu, prefObjectBoxes]
    public static let userDefaultsSuite = "capturekit"

    /// Property prefix of every switch.
    public static let propPrefix = "debug.capturekit."

    /// Instruction types shown/spoken with guidance OFF: the safety and tracking prompts (core InstrType names).
    public static let safetyInstructions: Set<String> =
        ["SLOW_DOWN", "HOLD_STILL", "RELOCALIZE", "MORE_LIGHT", "AIM_TEXTURED", "RECALIBRATE"]

    /// Resolved switches for one process.
    public struct Flags: Equatable {
        public var understanding: Int?
        public var detector: Bool
        public var guidance: Bool
        public var voiceCommands: Bool
        public var recalibrateCard: Bool
        /// Live object boxes + memory (ADR 0035). Needs the fetched model files, otherwise it stays off by itself.
        public var segmentation: Bool
        /// Keep /imu/gyro and /imu/accel in the bundle (ADR 0034; app default ON since ADR 0036).
        public var recordImu: Bool

        public init(understanding: Int? = nil, detector: Bool = false, guidance: Bool = false, voiceCommands: Bool = false,
                    recalibrateCard: Bool = false, segmentation: Bool = true, recordImu: Bool = true) {
            self.understanding = understanding
            self.detector = detector
            self.guidance = guidance
            self.voiceCommands = voiceCommands
            self.recalibrateCard = recalibrateCard
            self.segmentation = segmentation
            self.recordImu = recordImu
        }

        public static let defaults = Flags()
    }

    /// "1" = on, "0" = off (surrounding whitespace ignored); anything else (unset, blank, junk) keeps `defaultValue`.
    public static func switchOn(_ raw: String?, default defaultValue: Bool) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1"?: return true
        case "0"?: return false
        default: return defaultValue
        }
    }

    /// Flags from property values (`get` returns the raw value or nil).
    public static func fromProps(_ get: (String) -> String?) -> Flags {
        let d = Flags.defaults
        return Flags(
            understanding: understandingLevel(get(propUnderstanding)),
            detector: detectorOn(get(propDetector)),
            guidance: switchOn(get(propGuidance), default: d.guidance),
            voiceCommands: switchOn(get(propVoiceCommands), default: d.voiceCommands),
            recalibrateCard: switchOn(get(propRecalibrateCard), default: d.recalibrateCard),
            segmentation: switchOn(get(propSegmentation), default: d.segmentation),
            recordImu: switchOn(get(propRecordImu), default: d.recordImu))
    }

    /// Flags with the full precedence: property (exact "1"/"0") > user setting (nil = never set) > defaults.
    /// `detector` and `understanding` have no user setting (property only).
    public static func resolve(props: (String) -> String?, prefs: (String) -> Bool?) -> Flags {
        let d = Flags.defaults
        func sw(_ prop: String, _ pref: String, _ def: Bool) -> Bool {
            switchOn(props(prop), default: prefs(pref) ?? def)
        }
        return Flags(
            understanding: understandingLevel(props(propUnderstanding)),
            detector: detectorOn(props(propDetector)),
            guidance: sw(propGuidance, prefGuidance, d.guidance),
            voiceCommands: sw(propVoiceCommands, prefVoiceCommands, d.voiceCommands),
            recalibrateCard: sw(propRecalibrateCard, prefRecalibrateCard, d.recalibrateCard),
            segmentation: sw(propSegmentation, prefObjectBoxes, d.segmentation),
            recordImu: sw(propRecordImu, prefRecordImu, d.recordImu))
    }

    /// `debug.capturekit.record_imu` -> environment variable `CAPTUREKIT_RECORD_IMU`.
    public static func environmentName(_ prop: String) -> String {
        let tail = prop.hasPrefix(propPrefix) ? String(prop.dropFirst(propPrefix.count)) : prop
        return "CAPTUREKIT_" + tail.uppercased()
    }

    /// Property reader over a process environment (debug builds only; a release build passes `{ _ in nil }`).
    public static func environmentProp(_ env: [String: String]) -> (String) -> String? {
        { prop in env[environmentName(prop)] }
    }

    /// User settings reader: nil when the key was never written, so the default applies.
    public static func userPrefs(_ defaults: UserDefaults) -> (String) -> Bool? {
        { key in defaults.object(forKey: key) as? Bool }
    }

    /// Coaching-line rule for the latest shown instruction (ADR 0032): with guidance on it stays until the next one;
    /// with guidance off a prompt shows for `holdMs`, a RECALIBRATE prompt stays while recalibrating.
    public static func instructionStillShown(text: String, arrivedMs: Int64, nowMs: Int64, guidance: Bool,
                                             recalibrating: Bool, holdMs: Int64 = promptHoldMs) -> Bool {
        !text.isEmpty && (guidance || recalibrating || nowMs - arrivedMs < holdMs)
    }

    /// How long a safety prompt stays on the coaching line with guidance off (guess; tune on device).
    public static let promptHoldMs: Int64 = 4_000

    /// 0 = off, 1 = objects, 2 = objects + gap steering; nil = unset / blank / junk / out of range.
    public static func understandingLevel(_ raw: String?) -> Int? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), let v = Int(t), (0...2).contains(v) else { return nil }
        return v
    }

    /// The detector is off unless the property is exactly "1".
    public static func detectorOn(_ raw: String?) -> Bool { switchOn(raw, default: Flags.defaults.detector) }

    /// Show / speak an instruction of core `type`: always with guidance, else only the safety instructions.
    public static func showInstruction(type: String, guidance: Bool) -> Bool { guidance || safetyInstructions.contains(type) }

    /// Understanding level to pass: the override when set (including 0), else 2 for a guided scan, else nil.
    public static func understandingFor(override: Int?, guidedScan: Bool) -> Int? {
        override ?? (guidedScan ? defaultUnderstanding : nil)
    }

    /// Extra session config: `guide.understanding` whenever a level is given (including 0), `record_imu` = 1 only when on.
    public static func extraConfig(understanding: Int?, recordImu: Bool = false) -> SessionConfig {
        var m = SessionConfig()
        if let u = understanding, (0...2).contains(u) { m["guide.understanding"] = .int(u) }
        if recordImu { m["record_imu"] = .int(1) }
        return m
    }
}
