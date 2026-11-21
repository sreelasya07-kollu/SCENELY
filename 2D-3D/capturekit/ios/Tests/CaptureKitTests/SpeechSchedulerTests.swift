import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin SpeechSchedulerTest.
final class SpeechSchedulerTests: XCTestCase {
    private typealias Action = SpeechScheduler.Action

    private func s(_ edit: (inout SpeechScheduler.Config) -> Void = { _ in }) -> SpeechScheduler {
        var c = SpeechScheduler.Config()
        edit(&c)
        return SpeechScheduler(c)
    }

    private func sp(_ a: Action?, file: StaticString = #filePath, line: UInt = #line) -> (utteranceId: String, text: String, priority: Int, flush: Bool) {
        guard case .speak(let id, let text, let pr, let fl)? = a else { XCTFail("expected speak, got \(String(describing: a))", file: file, line: line); return ("", "", 0, false) }
        return (id, text, pr, fl)
    }

    private func isSpeak(_ a: Action) -> Bool { if case .speak = a { return true }; return false }

    func testSpeaksWhenIdle() {
        let a = sp(s().onInstruction(id: 1, text: "Turn slowly left.", priority: 2, nowMs: 0))
        XCTAssertEqual("Turn slowly left.", a.text); XCTAssertEqual("ck-1", a.utteranceId); XCTAssertFalse(a.flush)
    }

    func testDefaultSpeaksAtMostSixNonUrgentPerMinute() {
        let x = s { $0.minGapMs = 0; $0.repeatWindowMs = 0 }
        var spoken = 0
        for i in 1...8 {
            let t = Int64(i) * 5_000
            if isSpeak(x.onInstruction(id: i, text: "Line \(i).", priority: 2, nowMs: t)) { spoken += 1; x.onDone("ck-\(i)", nowMs: t + 100) }
        }
        XCTAssertEqual(6, spoken)
    }

    func testMutedDropsEverything() {
        let x = s(); x.enabled = false
        XCTAssertEqual(.drop(reason: "muted"), x.onInstruction(id: 1, text: "Slow down.", priority: 3, nowMs: 0))
    }

    func testSameIdIsNeverRepeated() {
        let x = s(); x.onInstruction(id: 1, text: "Move forward.", priority: 2, nowMs: 0); x.onDone("ck-1", nowMs: 1000)
        XCTAssertEqual(.drop(reason: "repeat"), x.onInstruction(id: 1, text: "Move forward.", priority: 2, nowMs: 60_000))
    }

    func testSameTextWithinWindowIsSuppressedButAllowedAfter() {
        let x = s { $0.repeatWindowMs = 10_000; $0.minGapMs = 0 }
        x.onInstruction(id: 1, text: "Slow down.", priority: 3, nowMs: 0); x.onDone("ck-1", nowMs: 500)
        XCTAssertEqual(.drop(reason: "repeat"), x.onInstruction(id: 2, text: "Slow down.", priority: 3, nowMs: 5_000))
        XCTAssertTrue(isSpeak(x.onInstruction(id: 3, text: "Slow down.", priority: 3, nowMs: 11_000)))
    }

    func testHigherPriorityPreemptsWithFlush() {
        let x = s(); x.onInstruction(id: 1, text: "Move to the left wall.", priority: 2, nowMs: 0); x.onStart("ck-1", nowMs: 100)
        let a = sp(x.onInstruction(id: 2, text: "Slow down.", priority: 3, nowMs: 600))
        XCTAssertTrue(a.flush)
    }

    func testLowerPriorityDuringSpeechIsDropped() {
        let x = s(); x.onInstruction(id: 1, text: "Slow down.", priority: 3, nowMs: 0); x.onStart("ck-1", nowMs: 100)
        XCTAssertEqual(.drop(reason: "busy"), x.onInstruction(id: 2, text: "More light please.", priority: 1, nowMs: 600))
    }

    func testEqualPriorityQueuesNewestAndReleasesAfterDone() {
        let x = s { $0.minGapMs = 0 }
        x.onInstruction(id: 1, text: "Tilt up.", priority: 2, nowMs: 0); x.onStart("ck-1", nowMs: 100)
        XCTAssertEqual(.queued, x.onInstruction(id: 2, text: "Step back.", priority: 2, nowMs: 500))
        XCTAssertEqual(.queued, x.onInstruction(id: 3, text: "Turn left.", priority: 2, nowMs: 900))
        x.onDone("ck-1", nowMs: 1200)
        let n = sp(x.nextPending(nowMs: 1300))
        XCTAssertEqual("Turn left.", n.text)
        XCTAssertNil(x.nextPending(nowMs: 1400))
    }

    func testPendingExpires() {
        let x = s { $0.minGapMs = 0; $0.pendingTtlMs = 3_000 }
        x.onInstruction(id: 1, text: "Tilt up.", priority: 2, nowMs: 0); x.onStart("ck-1", nowMs: 100)
        x.onInstruction(id: 2, text: "Step back.", priority: 2, nowMs: 500); x.onDone("ck-1", nowMs: 1000)
        XCTAssertNil(x.nextPending(nowMs: 4_000))
    }

    func testLateDoneOfFlushedUtteranceDoesNotClearSuccessor() {
        let x = s(); x.onInstruction(id: 1, text: "Tilt up.", priority: 2, nowMs: 0); x.onStart("ck-1", nowMs: 100)
        x.onInstruction(id: 2, text: "Slow down.", priority: 3, nowMs: 600)
        x.onDone("ck-1", nowMs: 700)
        XCTAssertTrue(x.isSpeaking())
    }

    func testBudgetLimitsNonUrgentButNotUrgent() {
        let x = s { $0.minGapMs = 0; $0.maxPerMinute = 2 }
        for i in 1...2 {
            XCTAssertTrue(isSpeak(x.onInstruction(id: i, text: "Hint \(i).", priority: 2, nowMs: Int64(i) * 1000)))
            x.onDone("ck-\(i)", nowMs: Int64(i) * 1000 + 100)
        }
        XCTAssertEqual(.drop(reason: "budget"), x.onInstruction(id: 3, text: "Hint 3.", priority: 2, nowMs: 4_000))
        XCTAssertTrue(isSpeak(x.onInstruction(id: 4, text: "Slow down.", priority: 3, nowMs: 4_500)))
        x.onDone("ck-4", nowMs: 5_000)
        XCTAssertTrue(isSpeak(x.onInstruction(id: 5, text: "Hint 5.", priority: 2, nowMs: 70_000)))
    }

    func testMinGapAppliesToNonUrgentOnly() {
        let x = s { $0.minGapMs = 2_000 }
        x.onInstruction(id: 1, text: "Hint one.", priority: 2, nowMs: 0); x.onDone("ck-1", nowMs: 500)
        XCTAssertEqual(.drop(reason: "gap"), x.onInstruction(id: 2, text: "Hint two.", priority: 2, nowMs: 1_000))
        XCTAssertTrue(isSpeak(x.onInstruction(id: 3, text: "Slow down.", priority: 3, nowMs: 1_000)))
    }

    func testEngineThatNeverCallsBackDoesNotStickSpeakingForever() {
        let x = s { $0.minGapMs = 0; $0.speakTimeoutMs = 5_000 }
        x.onInstruction(id: 1, text: "Tilt up.", priority: 2, nowMs: 0)   // engine never calls onStart/onDone/onError
        XCTAssertTrue(x.isSpeaking())
        XCTAssertEqual(.drop(reason: "busy"), x.onInstruction(id: 2, text: "More light please.", priority: 1, nowMs: 4_000))
        XCTAssertFalse(x.expireStuck(4_999))
        XCTAssertTrue(x.expireStuck(5_000))
        XCTAssertFalse(x.isSpeaking())
        XCTAssertTrue(isSpeak(x.onInstruction(id: 3, text: "Step back.", priority: 2, nowMs: 5_100)))
    }

    func testOnInstructionSelfHealsAfterTimeoutWithoutExplicitTick() {
        let x = s { $0.minGapMs = 0; $0.speakTimeoutMs = 5_000 }
        x.onInstruction(id: 1, text: "Tilt up.", priority: 2, nowMs: 0)
        XCTAssertTrue(isSpeak(x.onInstruction(id: 2, text: "Step back.", priority: 2, nowMs: 6_000)))
    }

    func testStartCallbackRestartsTheTimeout() {
        let x = s { $0.speakTimeoutMs = 5_000 }
        x.onInstruction(id: 1, text: "Tilt up.", priority: 2, nowMs: 0); x.onStart("ck-1", nowMs: 3_000)
        XCTAssertFalse(x.expireStuck(7_000))
        XCTAssertTrue(x.expireStuck(8_000))
    }

    func testBlankTextIsDropped() {
        XCTAssertEqual(.drop(reason: "empty"), s().onInstruction(id: 1, text: "  ", priority: 2, nowMs: 0))
    }

    func testRepeatLastWithNothingSaidDrops() {
        XCTAssertEqual(.drop(reason: "nothing"), s().repeatLast(nowMs: 0))
    }

    func testRepeatLastBypassesRepeatWindowGapAndBudget() {
        let x = s { $0.maxPerMinute = 1; $0.minGapMs = 60_000 }
        x.onInstruction(id: 1, text: "Turn slowly left.", priority: 2, nowMs: 0); x.onDone("ck-1", nowMs: 500)
        // Same text 1 s later: the guidance path suppresses it, the user's "repeat" does not.
        XCTAssertEqual(.drop(reason: "repeat"), x.onInstruction(id: 2, text: "Turn slowly left.", priority: 2, nowMs: 1_000))
        let a = sp(x.repeatLast(nowMs: 1_000))
        XCTAssertEqual("Turn slowly left.", a.text)
        XCTAssertTrue(a.utteranceId != "ck-1")
        XCTAssertFalse(a.flush)
    }

    func testRepeatLastCutsCurrentSpeechAndSurvivesReset() {
        let x = s()
        x.onInstruction(id: 1, text: "Step back.", priority: 2, nowMs: 0); x.onStart("ck-1", nowMs: 100)
        x.reset()   // pause: stopNow() resets the scheduler
        XCTAssertEqual("Step back.", sp(x.repeatLast(nowMs: 2_000)).text)
        let b = sp(x.repeatLast(nowMs: 2_500))   // still speaking the first repeat: flush it
        XCTAssertTrue(b.flush)
        XCTAssertEqual("Step back.", b.text)
    }

    func testRepeatLastWhenMutedDrops() {
        let x = s(); x.onInstruction(id: 1, text: "Step back.", priority: 2, nowMs: 0); x.onDone("ck-1", nowMs: 300)
        x.enabled = false
        XCTAssertEqual(.drop(reason: "muted"), x.repeatLast(nowMs: 1_000))
    }

    func testSpeakNowFeedbackIsNotRemembered() {
        let x = s(); x.onInstruction(id: 1, text: "Step back.", priority: 2, nowMs: 0); x.onDone("ck-1", nowMs: 300)
        _ = sp(x.speakNow("Louder", nowMs: 1_000, remember: false))
        XCTAssertEqual("Step back.", x.lastText)
        XCTAssertEqual("Step back.", sp(x.repeatLast(nowMs: 1_100)).text)
    }

    func testSpeakNowDoesNotConsumeTheBudget() {
        let x = s { $0.maxPerMinute = 1; $0.minGapMs = 0 }
        _ = sp(x.speakNow("Missing: Wall 2, 40 percent.", nowMs: 0)); x.onDone("ck--1", nowMs: 100)
        XCTAssertTrue(isSpeak(x.onInstruction(id: 5, text: "Turn left.", priority: 2, nowMs: 200)))
    }
}
