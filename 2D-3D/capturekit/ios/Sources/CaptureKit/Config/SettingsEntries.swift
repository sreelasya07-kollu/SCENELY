import Foundation

/// The rows of the Settings screen (ADR 0036): one switch per `FeatureFlags.prefKeys` entry, in the Android SettingsActivity order.
/// Pure data so a test can prove every key has a switch; the SampleApp only renders it.
public enum SettingsEntries {
    public struct Entry: Equatable {
        public let key: String
        public let title: String
        public let subtitle: String
        public let defaultOn: Bool
        public init(key: String, title: String, subtitle: String, defaultOn: Bool) {
            self.key = key; self.title = title; self.subtitle = subtitle; self.defaultOn = defaultOn
        }
    }

    public static var all: [Entry] {
        let d = FeatureFlags.Flags.defaults
        return [
            Entry(key: FeatureFlags.prefObjectBoxes, title: "Object boxes",
                  subtitle: "Green boxes with a label and number on the camera view; objects are remembered for the scan", defaultOn: d.segmentation),
            Entry(key: FeatureFlags.prefRecordImu, title: "Record motion sensors",
                  subtitle: "Keep the gyroscope and accelerometer in the scan", defaultOn: d.recordImu),
            Entry(key: FeatureFlags.prefGuidance, title: "Navigation prompts",
                  subtitle: "Spoken and written directions while you scan", defaultOn: d.guidance),
            Entry(key: FeatureFlags.prefVoiceCommands, title: "Voice commands",
                  subtitle: "Push-to-talk microphone button (asks for the microphone)", defaultOn: d.voiceCommands),
            Entry(key: FeatureFlags.prefRecalibrateCard, title: "Tracking recovery card",
                  subtitle: "Shows what to do when camera tracking is lost", defaultOn: d.recalibrateCard),
        ]
    }
}
