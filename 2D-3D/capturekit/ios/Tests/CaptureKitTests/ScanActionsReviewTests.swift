import XCTest
@testable import CaptureKit

/// Tests of the P3 pure helpers: ScanActions (the one path of buttons and voice commands, Kotlin ScanActions) and ReviewRules
/// (Kotlin ReviewSheet / ReviewActivity helpers). The Kotlin side has no unit tests for these; the cases follow its documented rules.
private final class FakeSpeech: ScanSpeech {
    var enabled = true
    var canRepeat = true
    var atLimit = false
    var said: [(String, Bool)] = []
    func repeatLast() -> Bool { canRepeat }
    func say(_ text: String, remember: Bool) -> Bool { said.append((text, remember)); return true }
    func louder() -> Bool { !atLimit }
    func quieter() -> Bool { !atLimit }
}

private final class FakeHost: ScanActionsHost {
    var paused = false
    var pauses = 0, resumes = 0
    var snap: ScanStateSnapshot?
    func isPaused() -> Bool { paused }
    func pauseScan() { pauses += 1; paused = true }
    func resumeScan() { resumes += 1; paused = false }
    func snapshot() -> ScanStateSnapshot? { snap }
}

final class ScanActionsTests: XCTestCase {
    private func make() -> (ScanActions, FakeSpeech, FakeHost) {
        let s = FakeSpeech(), h = FakeHost()
        return (ScanActions(speech: s, host: h), s, h)
    }

    func testPauseAndResumeAreIdempotent() {
        let (a, _, h) = make()
        XCTAssertEqual(ScanActions.Outcome("Paused.", 3_000), a.run(.pause))
        XCTAssertEqual(ScanActions.Outcome("Already paused.", 3_000), a.run(.pause))
        XCTAssertEqual(1, h.pauses)
        XCTAssertEqual(ScanActions.Outcome("Resuming.", 3_000), a.run(.resume))
        XCTAssertEqual(ScanActions.Outcome("Already scanning.", 3_000), a.run(.resume))
        XCTAssertEqual(1, h.resumes)
    }

    func testRepeatShowsNothingWhenSpokenAndExplainsOtherwise() {
        let (a, s, _) = make()
        XCTAssertEqual(ScanActions.Outcome(nil, 0), a.run(.repeatLast))
        s.canRepeat = false
        XCTAssertEqual("Nothing to repeat yet.", a.run(.repeatLast).text)
        s.enabled = false
        XCTAssertEqual("Voice guidance is off. Turn it on to hear it again.", a.run(.repeatLast).text)
    }

    func testMissingAbstainsWithoutSnapshotAndIsAlwaysShown() {
        let (a, s, _) = make()
        let o = a.run(.missing)
        XCTAssertEqual(StateAnswers.abstain, o.text)
        XCTAssertEqual(9_000, o.ms)
        XCTAssertEqual(StateAnswers.abstain, s.said.last?.0)
    }

    func testMissingUsesTheSnapshot() {
        let (a, _, h) = make()
        h.snap = ScanStateSnapshot(completeness: 0.95, tracking: 1, wallFound: true, floorFound: true, ceilingFound: true,
                                   walls: [WallState(id: 1, pct: 100)], headingSectors: 12)
        XCTAssertEqual("Nothing is missing. You can finish.", a.run(.missing).text)
    }

    func testVolumeSpeaksWithoutRememberingAndReportsTheLimit() {
        let (a, s, _) = make()
        XCTAssertEqual("Louder.", a.run(.louder).text)
        XCTAssertEqual(false, s.said.last?.1)
        s.atLimit = true
        XCTAssertEqual("Already at the loudest.", a.run(.louder).text)
        XCTAssertEqual("Already at the quietest.", a.run(.quieter).text)
    }

    func testEveryIntentMapsAndFinishNeedsConfirmation() {
        XCTAssertNil(ScanActions.kind(of: .finish))
        for i in VoiceIntent.allCases where i != .finish { XCTAssertNotNil(ScanActions.kind(of: i)) }
        XCTAssertEqual(.repeatLast, ScanActions.kind(of: .repeatLast))
    }
}

final class ReviewRulesTests: XCTestCase {
    private func overlay(v3: Bool, surfaces: [WallSeg], floor: Bool = true, walls: Int = 0) -> OverlayEvent {
        var o = OverlayEvent()
        o.layoutV3 = v3; o.surfaces = surfaces; o.floorFound = floor; o.walls = walls
        return o
    }

    func testWeakWallsOldCoreUsesPositions() {
        let o = overlay(v3: false, surfaces: [WallSeg(0, 0, 1, 0, 80), WallSeg(1, 0, 2, 0, 20)])
        XCTAssertEqual([2], ReviewRules.weakWalls(o))
        XCTAssertEqual([], ReviewRules.weakWalls(nil))
    }

    func testWeakWallsV3UsesCoreIdsAndSkipsUnevidencedOnes() {
        var o = overlay(v3: true, surfaces: [WallSeg(0, 0, 1, 0, 10, 3), WallSeg(1, 0, 2, 0, 10, 0)], walls: 2)
        o.spans = [SpanSeg(3, 0, 0, 1, 0, "m")]
        XCTAssertEqual([3], ReviewRules.weakWalls(o))
        o.spans = [SpanSeg(3, 0, 0, 1, 0, "b")]   // entirely hidden behind furniture: never called weak
        XCTAssertEqual([], ReviewRules.weakWalls(o))
    }

    func testNothingFoundAndNeeded() {
        XCTAssertTrue(ReviewRules.nothingFound(nil))
        XCTAssertTrue(ReviewRules.nothingFound(overlay(v3: false, surfaces: [], floor: false)))
        let weak = overlay(v3: false, surfaces: [WallSeg(0, 0, 1, 0, 10)])
        XCTAssertTrue(ReviewRules.needed(weak, guidance: true))
        XCTAssertFalse(ReviewRules.needed(weak, guidance: false))   // guidance off: only the empty-scan notice remains
        XCTAssertTrue(ReviewRules.needed(nil, guidance: false))
        XCTAssertEqual("Needs more scanning: Wall 1.", ReviewRules.gapsText(weak, guidance: true))
        XCTAssertEqual("Nothing of the room was captured yet.", ReviewRules.gapsText(nil, guidance: true))
    }

    func testParseManifest() {
        let text = #"{"validation":{"verdict":"WARN"},"counts":{"keyframes":42},"clock":{"t_start_ns":1000000000,"t_end_ns":4000000000}}"#
        XCTAssertEqual(ReviewRules.Manifest(verdict: "WARN", keyframes: 42, durationMs: 3_000), ReviewRules.parseManifest(text))
        XCTAssertEqual(ReviewRules.Manifest(verdict: nil, keyframes: nil, durationMs: nil), ReviewRules.parseManifest("not json"))
        XCTAssertNil(ReviewRules.parseManifest(#"{"validation":{"verdict":"MAYBE"}}"#).verdict)
    }

    func testParseSummaryKeepsFiveZones() {
        let zones = (1...7).map { #"{"kind":"gap","text":"zone \#($0)"}"# }.joined(separator: ",")
        let s = ReviewRules.parseSummary(#"{"completeness_pct":63,"weak_zones":[\#(zones)]}"#)
        XCTAssertEqual(63, s?.completenessPct)
        XCTAssertEqual(["zone 1", "zone 2", "zone 3", "zone 4", "zone 5"], s?.zones)
        XCTAssertNil(ReviewRules.parseSummary(nil))
        XCTAssertNil(ReviewRules.parseSummary("{}"))
    }

    func testFormatting() {
        XCTAssertEqual("1:05", ReviewRules.mmss(65_000))
        XCTAssertEqual("12 B", ReviewRules.humanSize(12))
        XCTAssertEqual("1.5 MB", ReviewRules.humanSize(1_572_864))
    }
}
