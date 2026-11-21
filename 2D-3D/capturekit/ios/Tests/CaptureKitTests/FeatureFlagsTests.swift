import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin FeatureFlagsTest (the getprop-parsing case has no iOS counterpart; environment mapping is added).
final class FeatureFlagsTests: XCTestCase {
    private typealias FF = FeatureFlags

    private func with(_ f: FF.Flags, _ edit: (inout FF.Flags) -> Void) -> FF.Flags {
        var c = f
        edit(&c)
        return c
    }

    func testUnderstandingLevelParsing() {
        XCTAssertNil(FF.understandingLevel(nil))
        XCTAssertNil(FF.understandingLevel(""))
        XCTAssertEqual(0, FF.understandingLevel("0"))
        XCTAssertEqual(1, FF.understandingLevel("1"))
        XCTAssertEqual(2, FF.understandingLevel(" 2\n"))
        XCTAssertNil(FF.understandingLevel("3"))
        XCTAssertNil(FF.understandingLevel("on"))
        XCTAssertNil(FF.understandingLevel("-1"))
    }

    func testDetectorIsOffByDefaultAndOnlyOneTurnsItOn() {
        XCTAssertFalse(FF.detectorOn(nil)); XCTAssertFalse(FF.detectorOn("")); XCTAssertTrue(FF.detectorOn("1"))
        XCTAssertTrue(FF.detectorOn(" 1\n")); XCTAssertFalse(FF.detectorOn("true")); XCTAssertFalse(FF.detectorOn("junk"))
        XCTAssertFalse(FF.detectorOn("0")); XCTAssertFalse(FF.detectorOn(" 0\n"))
    }

    func testSwitchParsingKeepsTheDefaultForUnsetBlankOrJunk() {
        for def in [false, true] {
            for raw in [nil, "", "  ", "2", "-1", "on", "off", "true", "yes", "01", "1.0"] as [String?] {
                XCTAssertEqual(def, FF.switchOn(raw, default: def), "raw=\(String(describing: raw)) default=\(def)")
            }
            XCTAssertTrue(FF.switchOn("1", default: def)); XCTAssertTrue(FF.switchOn(" 1\n", default: def))
            XCTAssertFalse(FF.switchOn("0", default: def)); XCTAssertFalse(FF.switchOn("\t0 ", default: def))
        }
    }

    func testDefaultsWithoutAnyProperty() {
        let d = FF.Flags.defaults
        XCTAssertFalse(d.guidance); XCTAssertFalse(d.detector); XCTAssertFalse(d.voiceCommands); XCTAssertFalse(d.recalibrateCard)
        XCTAssertTrue(d.segmentation)   // live object boxes (ADR 0035)
        XCTAssertTrue(d.recordImu)      // the app records the IMU by default (ADR 0036)
        XCTAssertNil(d.understanding)
        XCTAssertEqual(d, FF.fromProps { _ in nil })
        XCTAssertEqual(d, FF.fromProps { _ in "" })
        XCTAssertEqual(d, FF.fromProps { _ in "junk" })
    }

    func testEachPropertyTurnsExactlyItsOwnFeatureOn() {
        let d = FF.Flags.defaults
        func only(_ prop: String) -> FF.Flags { FF.fromProps { $0 == prop ? "1" : nil } }
        XCTAssertEqual(with(d) { $0.guidance = true }, only(FF.propGuidance))
        XCTAssertEqual(with(d) { $0.detector = true }, only(FF.propDetector))
        XCTAssertEqual(with(d) { $0.voiceCommands = true }, only(FF.propVoiceCommands))
        XCTAssertEqual(with(d) { $0.recalibrateCard = true }, only(FF.propRecalibrateCard))
        XCTAssertEqual(with(d) { $0.understanding = 1 }, only(FF.propUnderstanding))
        XCTAssertEqual(d, only(FF.propSegmentation))   // already on by default
        XCTAssertEqual(d, only(FF.propRecordImu))
        func zero(_ prop: String) -> FF.Flags { FF.fromProps { $0 == prop ? "0" : nil } }
        XCTAssertEqual(with(d) { $0.segmentation = false }, zero(FF.propSegmentation))
        XCTAssertEqual(with(d) { $0.recordImu = false }, zero(FF.propRecordImu))
        let all = FF.fromProps { $0 == FF.propUnderstanding ? "2" : "1" }
        XCTAssertEqual(FF.Flags(understanding: 2, detector: true, guidance: true, voiceCommands: true,
                                recalibrateCard: true, segmentation: true, recordImu: true), all)
        let names = [FF.propGuidance, FF.propDetector, FF.propVoiceCommands, FF.propRecalibrateCard,
                     FF.propUnderstanding, FF.propSegmentation, FF.propRecordImu]
        XCTAssertEqual(names.count, Set(names).count)
        for n in names { XCTAssertTrue(n.hasPrefix("debug.capturekit."), n) }
    }

    func testUnderstandingDefaultsToTwoForAGuidedScan() {
        XCTAssertEqual(2, FF.defaultUnderstanding)
        XCTAssertEqual(2, FF.understandingFor(override: nil, guidedScan: true))
        XCTAssertNil(FF.understandingFor(override: nil, guidedScan: false))
        XCTAssertEqual(0, FF.understandingFor(override: 0, guidedScan: true))
        XCTAssertEqual(1, FF.understandingFor(override: 1, guidedScan: true))
        XCTAssertEqual(2, FF.understandingFor(override: 2, guidedScan: false))
        XCTAssertEqual(["guide.understanding": 2] as SessionConfig,
                       FF.extraConfig(understanding: FF.understandingFor(override: nil, guidedScan: true)))
        XCTAssertEqual(SessionConfig(), FF.extraConfig(understanding: FF.understandingFor(override: nil, guidedScan: false)))
    }

    /// Debug property > user setting > default, per switch.
    func testResolvePrecedencePropertyThenSettingThenDefault() {
        let d = FF.Flags.defaults
        let none: (String) -> String? = { _ in nil }
        let noPrefs: (String) -> Bool? = { _ in nil }
        XCTAssertEqual(d, FF.resolve(props: none, prefs: noPrefs))
        // Setting overrides the default, both directions.
        let r1 = FF.resolve(props: none) { key in
            (key == FF.prefGuidance || key == FF.prefRecordImu) ? key == FF.prefGuidance : nil
        }
        XCTAssertTrue(r1.guidance); XCTAssertFalse(r1.recordImu)
        XCTAssertTrue(r1.segmentation)   // untouched switch keeps its default
        // Property beats the setting, both directions; a junk property falls through to the setting.
        let r2 = FF.resolve(props: { prop in
            switch prop {
            case FF.propGuidance: return "0"
            case FF.propRecordImu: return "1"
            case FF.propSegmentation: return "junk"
            default: return nil
            }
        }, prefs: { key in
            switch key {
            case FF.prefGuidance: return true
            case FF.prefRecordImu: return false
            case FF.prefObjectBoxes: return false
            default: return nil
            }
        })
        XCTAssertFalse(r2.guidance); XCTAssertTrue(r2.recordImu); XCTAssertFalse(r2.segmentation)
        // Each setting key maps to exactly its own switch.
        func only(_ key: String, _ value: Bool) -> FF.Flags { FF.resolve(props: none) { $0 == key ? value : nil } }
        XCTAssertEqual(with(d) { $0.guidance = true }, only(FF.prefGuidance, true))
        XCTAssertEqual(with(d) { $0.voiceCommands = true }, only(FF.prefVoiceCommands, true))
        XCTAssertEqual(with(d) { $0.recalibrateCard = true }, only(FF.prefRecalibrateCard, true))
        XCTAssertEqual(with(d) { $0.recordImu = false }, only(FF.prefRecordImu, false))
        XCTAssertEqual(with(d) { $0.segmentation = false }, only(FF.prefObjectBoxes, false))
        XCTAssertEqual(Set(["ck.guidance", "ck.voice_commands", "ck.recalibrate_card", "ck.record_imu", "ck.object_boxes"]), Set(FF.prefKeys))
    }

    func testExtraConfigIsPassedExplicitlyWhenSetAndEmptyWhenUnset() {
        XCTAssertEqual(SessionConfig(), FF.extraConfig(understanding: nil))
        XCTAssertEqual(["guide.understanding": 0] as SessionConfig, FF.extraConfig(understanding: 0))
        XCTAssertEqual(["guide.understanding": 1] as SessionConfig, FF.extraConfig(understanding: 1))
        XCTAssertEqual(["guide.understanding": 2] as SessionConfig, FF.extraConfig(understanding: 2))
    }

    /// The lean bundle is the core default, so `record_imu` is sent only when the flag is on (the app default).
    func testRecordImuIsSentOnlyWhenSwitchedOn() {
        XCTAssertNil(FF.extraConfig(understanding: nil)["record_imu"])
        XCTAssertNil(FF.extraConfig(understanding: 1, recordImu: false)["record_imu"])
        XCTAssertEqual(["record_imu": 1] as SessionConfig, FF.extraConfig(understanding: nil, recordImu: true))
        XCTAssertEqual(["guide.understanding": 1, "record_imu": 1] as SessionConfig, FF.extraConfig(understanding: 1, recordImu: true))
        let f = FF.fromProps { _ in nil }
        XCTAssertTrue(f.recordImu)
        XCTAssertEqual(["record_imu": 1] as SessionConfig, FF.extraConfig(understanding: f.understanding, recordImu: f.recordImu))
        let off = FF.fromProps { $0 == FF.propRecordImu ? "0" : nil }
        XCTAssertNil(FF.extraConfig(understanding: nil, recordImu: off.recordImu)["record_imu"])
    }

    /// The default flags give a guided scan `guide.understanding` 2 and `record_imu` 1; the unguided arm gets no understanding key.
    func testDefaultFlagsGiveASessionConfigWithUnderstandingTwoAndImu() {
        let d = FF.fromProps { _ in nil }
        XCTAssertEqual(["guide.understanding": 2, "record_imu": 1] as SessionConfig,
                       FF.extraConfig(understanding: FF.understandingFor(override: d.understanding, guidedScan: true), recordImu: d.recordImu))
        XCTAssertEqual(["record_imu": 1] as SessionConfig,
                       FF.extraConfig(understanding: FF.understandingFor(override: d.understanding, guidedScan: false), recordImu: d.recordImu))
    }

    /// iOS only: environment variable mapping and the UserDefaults suite "capturekit" reader.
    func testEnvironmentPropsAndUserDefaultsPrefs() {
        XCTAssertEqual("CAPTUREKIT_RECORD_IMU", FF.environmentName(FF.propRecordImu))
        let p = FF.environmentProp(["CAPTUREKIT_GUIDANCE": "1", "CAPTUREKIT_RECORD_IMU": "0"])
        let f = FF.resolve(props: p, prefs: { _ in nil })
        XCTAssertTrue(f.guidance); XCTAssertFalse(f.recordImu)

        let suite = "capturekit.test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let prefs = FF.userPrefs(ud)
        XCTAssertNil(prefs(FF.prefGuidance))
        ud.set(true, forKey: FF.prefGuidance)
        ud.set(false, forKey: FF.prefObjectBoxes)
        XCTAssertEqual(true, prefs(FF.prefGuidance))
        let r = FF.resolve(props: { _ in nil }, prefs: prefs)
        XCTAssertTrue(r.guidance); XCTAssertFalse(r.segmentation); XCTAssertTrue(r.recordImu)
    }

    func testSafetyPromptsTimeOutOnlyWithGuidanceOffAndNotWhileRecalibrating() {
        let hold = FF.promptHoldMs
        XCTAssertTrue(FF.instructionStillShown(text: "More light", arrivedMs: 1_000, nowMs: 1_000, guidance: false, recalibrating: false))
        XCTAssertTrue(FF.instructionStillShown(text: "More light", arrivedMs: 1_000, nowMs: 1_000 + hold - 1, guidance: false, recalibrating: false))
        XCTAssertFalse(FF.instructionStillShown(text: "More light", arrivedMs: 1_000, nowMs: 1_000 + hold, guidance: false, recalibrating: false))
        XCTAssertTrue(FF.instructionStillShown(text: "Turn slowly", arrivedMs: 0, nowMs: 60_000, guidance: false, recalibrating: true))
        XCTAssertTrue(FF.instructionStillShown(text: "Turn left", arrivedMs: 0, nowMs: 60_000, guidance: true, recalibrating: false))
        XCTAssertFalse(FF.instructionStillShown(text: "", arrivedMs: 0, nowMs: 0, guidance: true, recalibrating: true))
    }

    /// Guidance gate over all 15 core InstrType names.
    func testGuidanceGateTable() {
        let table: [(String, Bool)] = [
            ("SLOW_DOWN", true), ("HOLD_STILL", true), ("RELOCALIZE", true), ("MOVE_TO", false), ("ROTATE_TOWARD", false),
            ("TILT_UP", false), ("TILT_DOWN", false), ("STEP_BACK", false), ("SWEEP", false), ("MORE_LIGHT", true),
            ("FINISH", false), ("PROGRESS", false), ("KEEP_TURNING", false), ("AIM_TEXTURED", true), ("RECALIBRATE", true),
        ]
        XCTAssertEqual(15, table.count)
        XCTAssertEqual(15, Set(table.map { $0.0 }).count)
        for (type, kept) in table {
            XCTAssertEqual(kept, FF.showInstruction(type: type, guidance: false), "\(type) guidance off")
            XCTAssertTrue(FF.showInstruction(type: type, guidance: true), "\(type) guidance on")
        }
        XCTAssertEqual(Set(table.filter { $0.1 }.map { $0.0 }), FF.safetyInstructions)
        XCTAssertFalse(FF.showInstruction(type: "SOMETHING_NEW", guidance: false))
        XCTAssertFalse(FF.showInstruction(type: "", guidance: false))
        XCTAssertFalse(FF.showInstruction(type: "slow_down", guidance: false))
    }

    func testSessionConfigJSONIsFlatSortedAndEscaped() {
        let c: SessionConfig = ["b": 1, "a": 0.5, "s": "x\"y"]
        XCTAssertEqual("{\"a\":0.5,\"b\":1,\"s\":\"x\\\"y\"}", SessionConfigJSON.encode(c))
    }
}
