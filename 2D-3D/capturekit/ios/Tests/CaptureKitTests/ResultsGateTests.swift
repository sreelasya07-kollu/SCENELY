import XCTest
@testable import CaptureKit

/// Ports the field ResultsGate behaviour (URL joining, 404 -> POST /jobs, error texts) and the Results screen text rules. No network:
/// JobsClient gets a stub transport.
private final class StubTransport: HTTPTransport {
    var replies: [String: [(Int, String)]] = [:]   // "METHOD url" -> queued replies (the last one repeats)
    var calls: [String] = []
    var bodies: [Data] = []
    var failAll = false

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
        calls.append(key)
        if let b = request.httpBody { bodies.append(b) }
        if failAll { throw URLError(.cannotConnectToHost) }
        guard var q = replies[key], !q.isEmpty else { return (Data(), 404) }
        let r = q.count > 1 ? q.removeFirst() : q[0]
        replies[key] = q
        return (Data(r.1.utf8), r.0)
    }
}

final class ResultsGateTests: XCTestCase {
    func testEmptyOrBlankOrUnsubstitutedUrlMeansUnavailable() {
        XCTAssertFalse(ResultsGate(jobsURL: String?.none).available)
        XCTAssertFalse(ResultsGate(jobsURL: "").available)
        XCTAssertFalse(ResultsGate(jobsURL: "   ").available)
        XCTAssertFalse(ResultsGate(jobsURL: "$(CK_JOBS_URL)").available)
        XCTAssertFalse(ResultsGate(jobsURL: URL?.none).available)
        XCTAssertTrue(ResultsGate(jobsURL: "http://10.0.0.5:8081/").available)
        XCTAssertNil(ResultsGate(jobsURL: "").absoluteUrl("/jobs/x"))
        XCTAssertNil(ResultsGate(jobsURL: "").jobUrl("x"))
    }

    func testAbsoluteUrlJoinsRelativeAndRejectsForeignHosts() {
        let g = ResultsGate(jobsURL: "http://srv:8081/")
        XCTAssertEqual("http://srv:8081/jobs/b/files/x.svg", g.absoluteUrl("/jobs/b/files/x.svg"))
        XCTAssertEqual("http://srv:8081/jobs/b", g.absoluteUrl("jobs/b"))
        XCTAssertEqual("http://srv:8081/jobs/b", g.absoluteUrl("http://srv:8081/jobs/b"))
        XCTAssertNil(g.absoluteUrl("http://evil.example/jobs/b"))
        XCTAssertNil(g.absoluteUrl("http://srv:80812/jobs/b"))
        XCTAssertNil(g.absoluteUrl("https://srv:8081/jobs/b"))
    }

    func testBundleIdIsEncodedAsOneSegment() {
        XCTAssertEqual("scan%20a%2Fb%22", ResultsGate.segment("scan a/b\""))
        XCTAssertEqual("a-b_c.d", ResultsGate.segment("a-b_c.d"))
        XCTAssertEqual("http://srv/jobs/x%20y", ResultsGate(jobsURL: "http://srv").jobUrl("x y"))
        XCTAssertEqual(#"{"bundle_id":"a\"b\\c"}"#, String(decoding: ResultsGate.startBody(#"a"b\c"#), as: UTF8.self))
    }
}

final class JobsClientTests: XCTestCase {
    private let gate = ResultsGate(jobsURL: "http://srv")
    private func job(_ state: String, plan: Bool = false) -> String {
        let files = plan ? #"[{"name":"floorplan.svg","kind":"floorplan_svg","url":"/jobs/b/files/export/floorplan.svg","size":10,"sha256":"x"}]"# : "[]"
        return #"{"schema":"roomscan.job/1","bundle_id":"b","state":"\#(state)","created":"c","updated":"u","files":\#(files)}"#
    }

    func testStatusReturnsJobTextWithoutStartingAnything() async {
        let t = StubTransport(); t.replies["GET http://srv/jobs/b"] = [(200, "{}")]
        let f = await JobsClient(gate: gate, transport: t).status("b")
        XCTAssertEqual(Fetched("{}", nil), f); XCTAssertEqual(["GET http://srv/jobs/b"], t.calls)
    }

    func testStatusStartsTheJobOn404ThenReadsAgain() async {
        let t = StubTransport()
        t.replies["GET http://srv/jobs/b"] = [(404, ""), (200, "{}")]
        t.replies["POST http://srv/jobs"] = [(202, "{}")]
        let f = await JobsClient(gate: gate, transport: t).status("b")
        XCTAssertEqual(Fetched("{}", nil), f)
        XCTAssertEqual(["GET http://srv/jobs/b", "POST http://srv/jobs", "GET http://srv/jobs/b"], t.calls)
        XCTAssertEqual(#"{"bundle_id":"b"}"#, String(decoding: t.bodies[0], as: UTF8.self))
    }

    func testUnknownScanAndUnreachableAndUnavailableTexts() async {
        let none = StubTransport()   // everything 404
        let e1 = await JobsClient(gate: gate, transport: none).status("b").error
        XCTAssertEqual(ResultsGate.unknownScan, e1)
        let down = StubTransport(); down.failAll = true
        let e2 = await JobsClient(gate: gate, transport: down).status("b").error
        XCTAssertEqual(ResultsGate.unreachable, e2)
        let server500 = StubTransport(); server500.replies["GET http://srv/jobs/b"] = [(500, "")]
        let e3 = await JobsClient(gate: gate, transport: server500).status("b").error
        XCTAssertEqual(ResultsGate.unreachable, e3)
        let off = StubTransport()
        let e4 = await JobsClient(gate: ResultsGate(jobsURL: ""), transport: off).status("b").error
        XCTAssertEqual(ResultsGate.notSetUp, e4)
        XCTAssertTrue(off.calls.isEmpty)   // an unavailable gate never touches the network
    }

    func testFetchTextRefusesForeignUrls() async {
        let t = StubTransport(); t.replies["GET http://srv/f.svg"] = [(200, "<svg/>")]
        let c = JobsClient(gate: gate, transport: t)
        let ok = await c.fetchText("/f.svg")
        XCTAssertEqual(Fetched("<svg/>", nil), ok)
        let foreign = await c.fetchText("http://evil.example/f.svg").error
        XCTAssertEqual(ResultsGate.notOnServer, foreign)
        XCTAssertEqual(1, t.calls.count)
    }

    func testPollStopsAtTerminalStateAndFetchesThePlanOnce() async {
        let t = StubTransport()
        t.replies["GET http://srv/jobs/b"] = [(200, job("queued")), (200, job("running", plan: true)), (200, job("done", plan: true))]
        t.replies["GET http://srv/jobs/b/files/export/floorplan.svg"] = [(200, "<svg/>")]
        var states: [String] = []; var plans = 0; var sleeps = 0
        await JobsClient(gate: gate, transport: t).poll(bundleId: "b", sleep: { _ in sleeps += 1 }) { u in
            states.append(u.job?.state ?? "-"); if u.plan != nil { plans += 1 }
        }
        XCTAssertEqual(["queued", "running", "done"], states)
        XCTAssertEqual(1, plans); XCTAssertEqual(2, sleeps)
    }

    func testPollGivesUpAfterFirstErrorButSurvivesAGlitchWhileRunning() async {
        let first = StubTransport(); first.failAll = true
        var errors: [String?] = []
        await JobsClient(gate: gate, transport: first).poll(bundleId: "b", sleep: { _ in }) { errors.append($0.error) }
        XCTAssertEqual([ResultsGate.unreachable], errors)   // never a good answer: one error, loop ends

        let t = StubTransport()
        t.replies["GET http://srv/jobs/b"] = [(200, job("running")), (500, ""), (200, job("done"))]
        var seen: [String] = []
        await JobsClient(gate: gate, transport: t).poll(bundleId: "b", sleep: { _ in }) { seen.append($0.job?.state ?? "glitch") }
        XCTAssertEqual(["running", "glitch", "done"], seen)
    }

    func testPollStopsWhenTheTaskIsCancelled() async {
        let t = StubTransport(); t.replies["GET http://srv/jobs/b"] = [(200, job("running"))]
        var rounds = 0
        let task = Task {
            await JobsClient(gate: gate, transport: t).poll(bundleId: "b", sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }) { _ in rounds += 1 }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await task.value   // returns promptly: no leaked timer
        XCTAssertEqual(1, rounds)
    }
}

final class ResultsTextTests: XCTestCase {
    private func example() throws -> JobStatus {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "example_job", withExtension: "json"))
        return try XCTUnwrap(JobStatus.parse(try Data(contentsOf: url)))
    }

    func testExampleJobHeadlineStagesMeasurementsAndRescanOrder() throws {
        let j = try example()
        XCTAssertEqual("Part of the room needs another scan.", ResultsText.headline(j).text)
        XCTAssertEqual("Scan check", ResultsText.stageTitle("validate")); XCTAssertEqual("weird", ResultsText.stageTitle("weird"))
        XCTAssertEqual("Failed", ResultsText.stageLabel("failed").text); XCTAssertEqual("Waiting", ResultsText.stageLabel("pending").text)
        XCTAssertEqual("waiting for a GPU run (no CUDA device: splat training runs on the GPU machine) · Runs on the GPU computer", ResultsText.stageSubtitle(j.stages[5]))
        XCTAssertNil(ResultsText.stageSubtitle(j.stages[4]))
        let rows = ResultsText.measurementRows(j)
        XCTAssertEqual("Floor area", rows.first?.label); XCTAssertEqual("12.50 m²", rows.first?.value)
        XCTAssertTrue(rows.contains { $0.label == "Ceiling height" && $0.value == "2.55 m" })
        XCTAssertEqual(j.rescan.map { $0.priority }.sorted(by: >), j.rescanByPriority.map { $0.priority })
        XCTAssertTrue(try XCTUnwrap(ResultsText.validationNotes(j)).hasPrefix("Server check notes: "))
    }

    func testHeadlineForEveryState() {
        func j(_ state: String, verdict: String? = nil, error: String? = nil) -> JobStatus {
            let v = verdict.map { #","verdict":"\#($0)""# } ?? ""; let e = error.map { #","error":"\#($0)""# } ?? ""
            return JobStatus.parse(#"{"schema":"roomscan.job/1","bundle_id":"b","state":"\#(state)"\#(v)\#(e)}"#)!
        }
        XCTAssertEqual("Processing failed: boom", ResultsText.headline(j("failed", error: "boom")).text)
        XCTAssertEqual("The server could not use this scan.", ResultsText.headline(j("rejected")).text)
        XCTAssertEqual("The scan looks good.", ResultsText.headline(j("done", verdict: "pass")).text)
        XCTAssertEqual("Waiting for the server to start.", ResultsText.headline(j("queued")).text)
        XCTAssertEqual("Processing your scan...", ResultsText.headline(j("running")).text)
        XCTAssertEqual("No verdict yet.", ResultsText.headline(j("done")).text)
    }

    func testFloorPlanHtmlDropsPrologAndKeepsTheSvgInline() {
        let h = ResultsText.floorPlanHTML(svg: "<?xml version=\"1.0\"?>\n<!DOCTYPE svg>\n<svg viewBox=\"0 0 1 1\"><rect/></svg>")
        XCTAssertTrue(h.contains("<body><svg viewBox=\"0 0 1 1\"><rect/></svg></body>"))
        XCTAssertFalse(h.contains("<?xml"))
    }
}

final class UploadPlanTests: XCTestCase {
    func testOrderPutsManifestLastAndSkipsTempFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("keyframes"), withIntermediateDirectories: true)
        for f in ["manifest.json", "a.mcap", "keyframes/1.jpg", "b.tmp", ".ckit_upload_x"] { try Data("x".utf8).write(to: root.appendingPathComponent(f)) }
        XCTAssertEqual(["a.mcap", "keyframes/1.jpg", "manifest.json"], UploadPlan.order(root))
    }

    func testBundleIdIsReadFromTheManifest() {
        XCTAssertEqual("scan-1", UploadPlan.bundleId(#"{"schema":"x", "bundle_id" : "scan-1"}"#))
        XCTAssertNil(UploadPlan.bundleId("{}"))
    }

    func testServerStatusParsesVerifierAnswersIncludingServerValidation() throws {
        let done = try XCTUnwrap(ServerStatus.parse(#"{"status":"COMPLETE","missing":[],"corrupt":[],"server_validation":{"verdict":"WARN","issues":[]},"server_validation_state":"done"}"#))
        XCTAssertTrue(done.isFinal); XCTAssertEqual("WARN", done.serverValidationVerdict); XCTAssertEqual("Server check: usable, with notes", done.checkText)
        XCTAssertFalse(done.checkPending)
        let pending = try XCTUnwrap(ServerStatus.parse(#"{"status":"COMPLETE","server_validation":null,"server_validation_state":"pending"}"#))
        XCTAssertTrue(pending.checkPending); XCTAssertEqual("Server check running...", pending.checkText)
        let bad = try XCTUnwrap(ServerStatus.parse(#"{"status":"CORRUPT","reason":"sha mismatch","corrupt":[{"path":"a.mcap","expected":"1"},{"path":"manifest.json"}],"missing":["k/2.jpg"]}"#))
        XCTAssertTrue(bad.isFinal); XCTAssertEqual("sha mismatch", bad.reason)
        XCTAssertEqual(["a.mcap", "manifest.json"], bad.corruptPaths); XCTAssertEqual(["k/2.jpg"], bad.missing)
        XCTAssertNil(bad.checkText)   // older verifier without server_validation: no line
        XCTAssertNil(ServerStatus.parse("nope")); XCTAssertFalse(try XCTUnwrap(ServerStatus.parse(#"{"status":"PARTIAL"}"#)).isFinal)
    }

    func testUploadTextCoversEveryState() {
        XCTAssertEqual("Uploading 40%", UploadText.text(UploadStatus(state: .uploading, percent: 40)))
        XCTAssertEqual("Uploading", UploadText.text(UploadStatus(state: .uploading)))
        XCTAssertEqual("Uploaded and verified", UploadText.text(UploadStatus(state: .verified)))
        XCTAssertEqual("Upload failed: offline", UploadText.text(UploadStatus(state: .failed, error: "offline")))
        XCTAssertEqual("Upload failed", UploadText.text(UploadStatus(state: .failed, error: " ")))
        XCTAssertEqual("Not uploaded", UploadText.text(UploadStatus(state: .none)))
    }
}
