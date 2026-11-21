import XCTest
@testable import CaptureKit

/// SettingsEntries covers every C4 key (Kotlin SettingsActivity.entries); HomeText mirrors MainActivity.paintConsent and ScansActivity.friendlyDate.
final class HomeSettingsTests: XCTestCase {
    func testEveryPrefKeyHasExactlyOneSwitch() {
        let keys = SettingsEntries.all.map { $0.key }
        XCTAssertEqual(Set(keys), Set(FeatureFlags.prefKeys))
        XCTAssertEqual(keys.count, FeatureFlags.prefKeys.count)
    }

    func testSwitchDefaultsMatchTheFlagDefaults() {
        let d = FeatureFlags.Flags.defaults
        let byKey = Dictionary(uniqueKeysWithValues: SettingsEntries.all.map { ($0.key, $0.defaultOn) })
        XCTAssertEqual(byKey[FeatureFlags.prefObjectBoxes], d.segmentation)
        XCTAssertEqual(byKey[FeatureFlags.prefRecordImu], d.recordImu)
        XCTAssertEqual(byKey[FeatureFlags.prefGuidance], d.guidance)
        XCTAssertEqual(byKey[FeatureFlags.prefVoiceCommands], d.voiceCommands)
        XCTAssertEqual(byKey[FeatureFlags.prefRecalibrateCard], d.recalibrateCard)
    }

    func testConsentSummary() {
        XCTAssertEqual(HomeText.consentSummary(nil), "Consent not given yet. It is needed before scanning.")
        XCTAssertEqual(HomeText.consentSummary(Consent(version: "1", at: "t", upload: true, telemetry: false)),
                       "Upload on  ·  Anonymous telemetry off")
        XCTAssertEqual(HomeText.consentSummary(Consent(version: "1", at: "t", upload: false, telemetry: true)),
                       "Upload off  ·  Anonymous telemetry on")
    }

    func testDayBuckets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func ms(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Int64 {
            let c = DateComponents(calendar: cal, timeZone: cal.timeZone, year: y, month: m, day: d, hour: h)
            return Int64(c.date!.timeIntervalSince1970 * 1000)
        }
        let now = ms(2026, 6, 15, 12)
        XCTAssertEqual(HomeText.day(ms: ms(2026, 6, 15, 0), nowMs: now, calendar: cal), .today)
        XCTAssertEqual(HomeText.day(ms: ms(2026, 6, 14, 23), nowMs: now, calendar: cal), .yesterday)
        XCTAssertEqual(HomeText.day(ms: ms(2026, 2, 1, 9), nowMs: now, calendar: cal), .thisYear)
        XCTAssertEqual(HomeText.day(ms: ms(2025, 12, 31, 9), nowMs: now, calendar: cal), .older)
    }
}
