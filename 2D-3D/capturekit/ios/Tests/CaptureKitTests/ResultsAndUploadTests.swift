import XCTest
@testable import CaptureKit

/// Ported from Kotlin UploadPolicyTest, ScanInfoTest and VerdictTextTest; JobStatus.parse is checked against the backend's example_job.json.
final class UploadPolicyTests: XCTestCase {
    func testRunsOnlyWithConsentNowAndNonFailVerdict() {
        XCTAssertEqual(.run, UploadPolicy.decide(consentNow: true, verdict: "PASS"))
        XCTAssertEqual(.run, UploadPolicy.decide(consentNow: true, verdict: "WARN"))
        XCTAssertEqual(.noVerdict, UploadPolicy.decide(consentNow: true, verdict: nil))
        XCTAssertEqual(.noVerdict, UploadPolicy.decide(consentNow: true, verdict: "MAYBE"))
        XCTAssertFalse(UploadPolicy.eligible(consentNow: true, verdict: nil)); XCTAssertFalse(UploadPolicy.eligible(consentNow: true, verdict: "FAIL"))
        XCTAssertTrue(UploadPolicy.eligible(consentNow: true, verdict: "WARN"))
        XCTAssertEqual(.verdictFail, UploadPolicy.decide(consentNow: true, verdict: "FAIL"))
    }

    func testRevokedConsentStopsQueuedWorkWhateverTheVerdict() {
        for v in ["PASS", "WARN", "FAIL", nil] as [String?] {
            XCTAssertEqual(.noConsent, UploadPolicy.decide(consentNow: false, verdict: v))
            XCTAssertFalse(UploadPolicy.eligible(consentNow: false, verdict: v))
        }
        XCTAssertTrue(UploadPolicy.eligible(consentNow: true, verdict: "PASS"))
    }

    func testVerdictOfReadsManifest() {
        XCTAssertEqual("FAIL", UploadPolicy.verdictOf(#"{"validation":{"verdict": "FAIL","issues":[]}}"#))
        XCTAssertNil(UploadPolicy.verdictOf(#"{"validation":{"verdict":"MAYBE"}}"#))
        XCTAssertNil(UploadPolicy.verdictOf("garbage"))
    }

    func testPercentIsClamped() {
        XCTAssertEqual(0, UploadPolicy.percent(done: 5, total: 0)); XCTAssertEqual(50, UploadPolicy.percent(done: 50, total: 100))
        XCTAssertEqual(100, UploadPolicy.percent(done: 300, total: 100))
    }

    func testMarkerSitsBesideTheBundleAndIsRecognised() {
        let m = UploadPolicy.verifiedMarker(URL(fileURLWithPath: "/x/bundles/scan_1"))
        XCTAssertEqual("scan_1.upload_verified", m.lastPathComponent); XCTAssertEqual("bundles", m.deletingLastPathComponent().lastPathComponent)
        XCTAssertTrue(UploadPolicy.isMarker(m.lastPathComponent)); XCTAssertFalse(UploadPolicy.isMarker("scan_1"))
    }
}

final class ScanInfoTests: XCTestCase {
    func testTimeComesFromFolderStampElseModifiedTime() {
        let t = ScanInfo.timeMs(dirName: "scan_20260102_030405", lastModified: 7)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd_HHmmss"
        XCTAssertEqual(Int64((f.date(from: "20260102_030405")!.timeIntervalSince1970 * 1000).rounded()), t)
        XCTAssertEqual(7, ScanInfo.timeMs(dirName: "scan_x", lastModified: 7))
        XCTAssertEqual(7, ScanInfo.timeMs(dirName: "scan_20261399_999999", lastModified: 7))
        XCTAssertNotEqual(7, t)
    }

    func testRoomLabelIsReadAndUnescaped() {
        XCTAssertEqual("Kitchen", ScanInfo.roomLabel(#"{"arm":"guided","room":"Kitchen","device":"x"}"#))
        XCTAssertEqual("The \"big\" room", ScanInfo.roomLabel(#"{"room":"The \"big\" room"}"#))
        XCTAssertNil(ScanInfo.roomLabel(#"{"room":"  "}"#)); XCTAssertNil(ScanInfo.roomLabel("{}")); XCTAssertNil(ScanInfo.roomLabel(nil))
    }

    func testBadgeTextAlwaysHasWords() {
        XCTAssertEqual("Passed", ScanInfo.badgeText("PASS")); XCTAssertEqual("Usable, with notes", ScanInfo.badgeText("WARN"))
        XCTAssertEqual("Failed", ScanInfo.badgeText("FAIL")); XCTAssertEqual("Not checked", ScanInfo.badgeText(nil))
    }
}

final class VerdictTextTests: XCTestCase {
    private let json = #"""
        {"headlines":{"FAIL":"Fail head","WARN":"Warn head","PASS":"Pass head"},
         "codes":{
          "POSE_GAP":{"severity":"WARN","level":"semantic","title":"Gap","text":"Tracking gap \"x\" é","action":"Rescan part","next":"proceed_with_note"},
          "MISSING_FILE":{"severity":"ERROR","level":"integrity","title":"Missing","text":"File gone","action":"Scan again","next":"rescan"}}}
        """#

    private func manifest(_ issues: [String]) -> String {
        #"{"bundle_id":"b","validation":{"verdict":"WARN","level":"semantic","issues":[\#(issues.joined(separator: ","))]},"counts":{"keyframes":3}}"#
    }

    func testParsesHeadlinesAndCodesWithEscapes() {
        let v = VerdictText.parse(json)
        XCTAssertEqual("Fail head", v.headline("FAIL")); XCTAssertEqual("Pass head", v.headline("PASS"))
        let e = v.entry(VerdictText.Issue("POSE_GAP", "WARN", "m"))
        XCTAssertEqual("Gap", e.title); XCTAssertEqual("Tracking gap \"x\" é", e.text); XCTAssertEqual("proceed_with_note", e.next)
    }

    func testUnknownCodeGetsGenericEntryFromSeverity() {
        let v = VerdictText.parse(json)
        let w = v.entry(VerdictText.Issue("NEW_CODE", "WARN", "raw message"))
        XCTAssertEqual("raw message", w.text); XCTAssertEqual("proceed_with_note", w.next)
        XCTAssertEqual("rescan", v.entry(VerdictText.Issue("NEW_CODE", "ERROR", "")).next)
    }

    func testDamagedAssetFallsBackToBuiltInHeadlines() {
        for bad in ["", "{", "[1,2]", "{\"headlines\":", "nonsense"] {
            let v = VerdictText.parse(bad)
            XCTAssertEqual("Scan looks good.", v.headline("PASS"))
            XCTAssertTrue(v.headline("FAIL").lowercased().contains("scan the room again"))
        }
        XCTAssertEqual("Scan saved with notes.", VerdictText.fallback.headline(nil))
    }

    func testIssuesOfReadsCodesAndDescribeDedupesAndOrdersErrorsFirst() {
        let m = manifest([
            #"{"code":"POSE_GAP","severity":"WARN","level":"semantic","message":"a"}"#,
            #"{"code":"POSE_GAP","severity":"WARN","level":"semantic","message":"b"}"#,
            #"{"code":"INFO_ONLY","severity":"INFO","level":"semantic","message":"i"}"#,
            #"{"code":"MISSING_FILE","severity":"ERROR","level":"integrity","message":"c"}"#,
        ])
        let issues = VerdictText.issuesOf(m)
        XCTAssertEqual(4, issues.count)
        let v = VerdictText.parse(json)
        XCTAssertEqual(["Missing", "Gap"], v.describe(issues).map { $0.title })
        XCTAssertEqual("rescan", v.nextStep("WARN", issues))
    }

    func testNextStepFollowsVerdictAndEntries() {
        let v = VerdictText.parse(json)
        XCTAssertEqual("none", v.nextStep("PASS", []))
        XCTAssertEqual("proceed_with_note", v.nextStep("WARN", [VerdictText.Issue("POSE_GAP", "WARN", "")]))
        XCTAssertEqual("rescan", v.nextStep("FAIL", []))
        XCTAssertEqual([VerdictText.Issue](), VerdictText.issuesOf("not json"))
    }

    /// The Android asset, when this repo layout is available (skipped otherwise).
    func testShippedAssetParsesWithEveryCodeComplete() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("android/sample-app/src/main/assets/verdict_messages.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("verdict_messages.json not found") }
        let v = VerdictText.parse(text)
        XCTAssertFalse(v.headline("FAIL").isEmpty)
        for code in ["MISSING_FILE", "POSE_GAP", "FEW_KEYFRAMES", "PARTIAL_BUNDLE"] {
            let e = v.entry(VerdictText.Issue(code, "WARN", ""))
            XCTAssertFalse(e.title.isEmpty, "\(code) title"); XCTAssertFalse(e.text.isEmpty, "\(code) text"); XCTAssertFalse(e.action.isEmpty, "\(code) action")
            XCTAssertTrue(["rescan", "proceed_with_note", "none"].contains(e.next), "\(code) next")
        }
    }
}

final class JobStatusTests: XCTestCase {
    private func example() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "example_job", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testParsesTheBackendExampleJob() throws {
        let j = try XCTUnwrap(JobStatus.parse(try example()))
        XCTAssertEqual("roomscan.job/1", j.schema); XCTAssertEqual("example-bundle-0001", j.bundleId)
        XCTAssertEqual("done", j.state); XCTAssertTrue(j.isTerminal); XCTAssertFalse(j.isActive)
        XCTAssertNil(j.error)
        XCTAssertEqual("WARN", j.validation?.verdict)
        XCTAssertEqual(JobStatus.Issue(code: "POSE_GAP", severity: "WARN", message: "illustrative example: pose gap of 0.6 s"), j.validation?.issues.first)
        XCTAssertEqual(["validate", "spatial", "recon", "export", "qa", "splat", "splat_eval"], j.stages.map { $0.name })
        XCTAssertEqual("failed", j.stages[2].status)
        XCTAssertEqual("gpu_worker", j.stages[5].where_); XCTAssertEqual("pending", j.stages[5].status)
        XCTAssertEqual("needs_rescan", j.verdict)
        XCTAssertEqual(2, j.rescan.count)
        XCTAssertEqual("wall", j.rescan[0].surface); XCTAssertEqual(0.9, j.rescan[0].priority, accuracy: 1e-9); XCTAssertEqual(3.2, j.rescan[0].areaM2, accuracy: 1e-9)
        XCTAssertEqual(12.5, j.measurements?.floorAreaM2); XCTAssertEqual([4.0, 3.1, 4.0, 3.1], j.measurements?.wallLengthsM)
        XCTAssertEqual(2.55, j.measurements?.ceilingHeightM); XCTAssertEqual("metric_priors", j.measurements?.scaleSource)
        XCTAssertEqual(7, j.files.count)
        XCTAssertEqual("/jobs/example-bundle-0001/files/export/floorplan.svg", j.file(kind: "floorplan_svg")?.url)
        XCTAssertEqual(150_000_000, j.file(kind: "spatial_map_zip")?.size)
        XCTAssertNil(j.file(kind: "splat_ply"))
    }

    func testRejectsOtherSchemasAndGarbage() {
        XCTAssertNil(JobStatus.parse("not json"))
        XCTAssertNil(JobStatus.parse(#"{"schema":"other/1","bundle_id":"b","state":"done"}"#))
        XCTAssertNil(JobStatus.parse(#"{"schema":"roomscan.job/1","state":"done"}"#))
    }

    func testQueuedJobIsActiveWithNullsAndUnknownKeysIgnored() throws {
        let j = try XCTUnwrap(JobStatus.parse(#"{"schema":"roomscan.job/1","bundle_id":"b","state":"queued","created":"c","updated":"u","error":null,"validation":null,"stages":[],"verdict":null,"rescan":[],"measurements":null,"files":[],"future_key":1}"#))
        XCTAssertTrue(j.isActive); XCTAssertFalse(j.isTerminal)
        XCTAssertNil(j.validation); XCTAssertNil(j.verdict); XCTAssertNil(j.measurements); XCTAssertTrue(j.files.isEmpty)
        let r = try XCTUnwrap(JobStatus.parse(#"{"schema":"roomscan.job/1","bundle_id":"b","state":"rejected","error":"validate: FAIL"}"#))
        XCTAssertTrue(r.isTerminal); XCTAssertEqual("validate: FAIL", r.error)
    }
}
