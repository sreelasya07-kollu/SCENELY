import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin ConsentStoreTest (the res/raw text-file case belongs to the SampleApp bundle, phase P3).
final class ConsentStoreTests: XCTestCase {
    private final class Mem: ConsentStorage {
        var s: [String: String] = [:]
        var b: [String: Bool] = [:]
        func getString(_ key: String) -> String? { s[key] }
        func getBoolean(_ key: String) -> Bool { b[key] ?? false }
        func put(strings: [String: String], booleans: [String: Bool]) {
            s.merge(strings) { _, new in new }
            b.merge(booleans) { _, new in new }
        }
        func clear() { s.removeAll(); b.removeAll() }
    }

    func testFreshStoreHasNoConsentAndNoFlags() {
        let c = ConsentStore(Mem())
        XCTAssertFalse(c.hasConsent()); XCTAssertFalse(c.uploadAllowed()); XCTAssertFalse(c.telemetryAllowed())
        XCTAssertNil(c.current()); XCTAssertNil(c.sessionConfig())
    }

    func testAcceptRecordsVersionTimeAndFlagsSeparately() {
        let c = ConsentStore(Mem())
        c.accept(nowMs: 1_700_000_000_000, upload: true, telemetry: false)
        let cur = c.current()!
        XCTAssertEqual(ConsentStore.currentVersion, cur.version)
        XCTAssertEqual("2023-11-14T22:13:20Z", cur.at)
        XCTAssertTrue(c.uploadAllowed()); XCTAssertFalse(c.telemetryAllowed())
    }

    func testDefaultsOffWhenBothTogglesUntouched() {
        let c = ConsentStore(Mem())
        c.accept(nowMs: 0, upload: false, telemetry: false)
        XCTAssertTrue(c.hasConsent()); XCTAssertFalse(c.uploadAllowed()); XCTAssertFalse(c.telemetryAllowed())
    }

    func testSessionConfigAlwaysCarriesAllThreeKeys() {
        let c = ConsentStore(Mem())
        c.accept(nowMs: 1_700_000_000_000, upload: false, telemetry: true)
        XCTAssertEqual(
            ["consent_version": "1", "consent_at": "2023-11-14T22:13:20Z", "redaction_mode": "faces"] as SessionConfig,
            c.sessionConfig())
    }

    func testRevokeClearsConsentAndBothFlags() {
        let c = ConsentStore(Mem())
        c.accept(nowMs: 5, upload: true, telemetry: true)
        c.revoke()
        XCTAssertFalse(c.hasConsent()); XCTAssertFalse(c.uploadAllowed()); XCTAssertFalse(c.telemetryAllowed()); XCTAssertNil(c.sessionConfig())
    }

    func testOlderTextVersionCountsAsNoConsent() {
        let m = Mem()
        m.put(strings: ["version": "0", "at": "2020-01-01T00:00:00Z"], booleans: ["upload": true, "telemetry": true])
        let c = ConsentStore(m)
        XCTAssertFalse(c.hasConsent()); XCTAssertFalse(c.uploadAllowed()); XCTAssertFalse(c.telemetryAllowed())
    }

    func testFlagsWithoutRecordedTimeAreIgnored() {
        let m = Mem()
        m.put(strings: ["version": ConsentStore.currentVersion], booleans: ["upload": true])
        XCTAssertFalse(ConsentStore(m).uploadAllowed())
    }

    func testIsoIsUtcWithZ() {
        XCTAssertEqual("1970-01-01T00:00:00Z", ConsentStore.iso(0))
    }

    func testUserDefaultsStorageRoundTripAndClear() {
        let suite = "ck_consent.test.\(UUID().uuidString)"
        let c = ConsentStore(UserDefaultsConsentStorage(suite: suite))
        defer { c.revoke() }
        XCTAssertFalse(c.hasConsent())
        c.accept(nowMs: 1_700_000_000_000, upload: true, telemetry: false)
        XCTAssertTrue(c.uploadAllowed()); XCTAssertFalse(c.telemetryAllowed())
        c.revoke()
        XCTAssertFalse(c.hasConsent())
    }
}
