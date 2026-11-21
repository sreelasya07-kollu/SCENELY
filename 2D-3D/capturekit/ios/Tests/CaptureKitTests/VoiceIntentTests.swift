import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin VoiceIntentTest.
final class VoiceIntentTests: XCTestCase {
    private let p = try! VoiceIntentParser(PhraseTables.en)

    private func intentOf(_ text: String) -> VoiceIntent? {
        if case .match(let m) = p.parse(text) { return m.intent }
        return nil
    }

    private func match(_ r: VoiceParse, file: StaticString = #filePath, line: UInt = #line) -> VoiceMatch {
        guard case .match(let m) = r else { XCTFail("expected match, got \(r)", file: file, line: line); return VoiceMatch(intent: .pause, score: 0, heard: "") }
        return m
    }

    func testExactAndNormalisedPhrases() {
        let cases: [(String, VoiceIntent)] = [
            ("pause", .pause), ("Stop.", .pause), ("STOP!", .pause), ("hold on", .pause),
            ("resume", .resume), ("Continue, please", .resume), ("keep going", .resume),
            ("repeat", .repeatLast), ("Say that again?", .repeatLast),
            ("What's missing?", .missing), ("what is missing", .missing), ("How much is left?", .missing),
            ("finish", .finish), ("I'm done", .finish),
            ("louder", .louder), ("Speak up!", .louder), ("quieter", .quieter), ("too loud", .quieter),
        ]
        for (text, want) in cases { XCTAssertEqual(want, intentOf(text), text) }
    }

    func testExactMatchHasFullScore() {
        let m = match(p.parse("pause"))
        XCTAssertEqual(1, m.score, accuracy: 1e-6)
        XCTAssertEqual("pause", m.heard)
    }

    func testFillersAreIgnored() {
        let cases: [(String, VoiceIntent)] = [
            ("um pause", .pause), ("uh, okay, resume please", .resume), ("hey could you repeat that", .repeatLast),
            ("erm so what's left", .missing), ("can you speak up please", .louder),
        ]
        for (text, want) in cases {
            let m = match(p.parse(text))
            XCTAssertEqual(want, m.intent, text)
            XCTAssertEqual(1, m.score, accuracy: 1e-6, text)   // fillers stripped -> exact
        }
    }

    func testPartialPhrasesInsideShortUtterances() {
        let cases: [(String, VoiceIntent)] = [
            ("pause for a second", .pause), ("stop scanning for now", .pause), ("ok let's continue", .resume),
            ("how much is left here", .missing), ("say that again for me", .repeatLast), ("a bit louder", .louder),
        ]
        for (text, want) in cases {
            let m = match(p.parse(text))
            XCTAssertEqual(want, m.intent, text)
            XCTAssertTrue(m.score < 1, text)
        }
    }

    func testNoiseAndOutOfVocabularyAreNoMatch() {
        let cases: [(String, String)] = [
            ("", "empty"), ("   ", "empty"), ("?!.", "empty"), ("um uh please", "filler_only"),
            ("asdf qwerty", "no_phrase"), ("the paws are muddy", "no_phrase"), ("what time is it", "no_phrase"), ("pass", "no_phrase"),
        ]
        for (text, reason) in cases { XCTAssertEqual(.noMatch(reason), p.parse(text), text) }
    }

    func testBackgroundTalkWithManyExtraWordsIsIgnored() {
        XCTAssertEqual(.noMatch("no_phrase"), p.parse("I told him to pause the music yesterday after dinner"))
    }

    func testNegatedCommandsNeverAct() {
        for text in ["don't stop", "do not pause", "not done", "never finish", "no stop"] {
            XCTAssertEqual(.noMatch("negated"), p.parse(text), text)
        }
    }

    func testTwoCommandsInOneUtteranceAreAmbiguous() {
        XCTAssertEqual(.noMatch("ambiguous"), p.parse("pause and continue"))
        XCTAssertEqual(.noMatch("ambiguous"), p.parse("louder quieter"))
    }

    func testStopMapsToPauseNeverFinish() {
        for text in ["stop", "stop scanning", "stop the scan"] {
            let m = match(p.parse(text))
            XCTAssertEqual(.pause, m.intent, text)
            XCTAssertFalse(m.needsConfirmation, text)
        }
    }

    func testFinishAlwaysNeedsConfirmationAndNothingElseDoes() {
        for i in VoiceIntent.allCases { XCTAssertEqual(i == .finish, i.requiresConfirmation, i.name) }
        for text in ["finish", "finish the scan", "I am done", "all done"] {
            let m = match(p.parse(text))
            XCTAssertEqual(.finish, m.intent)
            XCTAssertTrue(m.needsConfirmation, text)
        }
    }

    func testConfirmationAnswers() {
        let cases: [(String, Confirmation)] = [
            ("yes", .yes), ("Yeah, go ahead", .unknown), ("yeah", .yes), ("go ahead", .yes), ("yes finish", .yes),
            ("no", .no), ("not yet", .no), ("cancel", .no), ("keep scanning", .no),
            ("", .unknown), ("maybe", .unknown), ("pause", .unknown),
        ]
        for (text, want) in cases { XCTAssertEqual(want, p.parseConfirmation(text), text) }
    }

    func testConfirmationWithYesAndNoInNBestIsUnknown() {
        XCTAssertEqual(.unknown, p.parseConfirmation([Hypothesis("yet"), Hypothesis("yes"), Hypothesis("no")]))
        XCTAssertEqual(.unknown, p.parseConfirmation([Hypothesis("yes", 0.9), Hypothesis("no", 0.1)]))
    }

    func testConfirmationUsesSamePriorAndMinScoreAsParse() {
        XCTAssertEqual(.unknown, p.parseConfirmation([Hypothesis("yes", 0.3)]))
        XCTAssertEqual(.unknown, p.parseConfirmation([Hypothesis("no", 0.3)]))
        XCTAssertEqual(.yes, p.parseConfirmation([Hypothesis("yet"), Hypothesis("yes")]))
        // Unreported yes below a reported 0.5 miss: capped at 0.5 x 0.8 = 0.4 < minScore.
        XCTAssertEqual(.unknown, p.parseConfirmation([Hypothesis("yet", 0.5), Hypothesis("yes")]))
    }

    func testMixedConfidencesCapUnreportedBelowReportedAbove() {
        let m = match(p.parse([Hypothesis("louder", 0.6), Hypothesis("quieter", 0)]))
        XCTAssertEqual(.louder, m.intent)
        XCTAssertEqual(0.6, m.score, accuracy: 1e-6)
        let n = match(p.parse([Hypothesis("louder", 0.6), Hypothesis("quieter")]))
        XCTAssertEqual(.louder, n.intent)
    }

    func testApostrophesNormaliseAway() {
        XCTAssertEqual(["whats", "next"], VoiceIntentParser.tokens("What's next?"))
        XCTAssertEqual(["whats", "next"], VoiceIntentParser.tokens("What\u{2019}s next?"))
        XCTAssertEqual(["whats", "left", "to", "scan"], VoiceIntentParser.tokens("what's left to scan"))
        let cases: [(String, Float)] = [
            ("What's next?", 1), ("What\u{2019}s next?", 1), ("whats next", 1), ("What's left to scan?", 1),
            ("What\u{2019}s left to scan", 1), ("so what's next then", 0.8),
        ]
        for (text, score) in cases {
            let m = match(p.parse(text))
            XCTAssertEqual(.missing, m.intent, text)
            XCTAssertEqual(score, m.score, accuracy: 1e-6, text)
        }
    }

    func testAgainAfterACommandIsNotAmbiguous() {
        let cases: [(String, VoiceIntent)] = [
            ("pause again", .pause), ("resume again", .resume), ("continue again", .resume),
            ("say that again", .repeatLast), ("go again", .resume),
        ]
        for (text, want) in cases { XCTAssertEqual(want, intentOf(text), text) }
        XCTAssertEqual(.noMatch("no_phrase"), p.parse("again"))
    }

    func testNBestPicksMatchingHypothesis() {
        let m = match(p.parse([Hypothesis("pours", 0.9), Hypothesis("pause", 0.8), Hypothesis("paws", 0.4)]))
        XCTAssertEqual(.pause, m.intent)
        XCTAssertEqual(0.8, m.score, accuracy: 1e-6)
        XCTAssertEqual("pause", m.heard)
    }

    func testNBestWithoutConfidenceUsesRankPrior() {
        let m = match(p.parse([Hypothesis("pours"), Hypothesis("pause")]))
        XCTAssertEqual(0.8, m.score, accuracy: 1e-6)   // rankDecay^1
        let z = match(p.parse([Hypothesis("pause", 0)]))
        XCTAssertEqual(1, z.score, accuracy: 1e-6)
    }

    func testLowConfidenceIsNoMatch() {
        XCTAssertEqual(.noMatch("low_confidence"), p.parse([Hypothesis("pause", 0.3)]))
        // Contained (0.8) x 0.5 = 0.4 < 0.45
        XCTAssertEqual(.noMatch("low_confidence"), p.parse([Hypothesis("pause for a second", 0.5)]))
    }

    func testCloseHypothesesOfDifferentIntentsAreAmbiguous() {
        XCTAssertEqual(.noMatch("ambiguous"), p.parse([Hypothesis("louder", 0.7), Hypothesis("quieter", 0.65)]))
        let m = match(p.parse([Hypothesis("louder", 0.9), Hypothesis("quieter", 0.3)]))
        XCTAssertEqual(.louder, m.intent)
    }

    func testSameIntentAcrossHypothesesIsNotAmbiguous() {
        let m = match(p.parse([Hypothesis("pause", 0.7), Hypothesis("stop", 0.69)]))
        XCTAssertEqual(.pause, m.intent)
    }

    func testEmptyNBestIsNoMatch() {
        XCTAssertEqual(.noMatch("empty"), p.parse([Hypothesis]()))
    }

    func testLocaleLookup() {
        XCTAssertNotNil(PhraseTables.forLocale("en"))
        XCTAssertEqual("en", PhraseTables.forLocale("en-US")?.locale)
        XCTAssertEqual("en", PhraseTables.forLocale("en_GB")?.locale)
        XCTAssertNil(PhraseTables.forLocale("hi-IN"))   // not shipped yet: shell hides the mic
    }

    func testEveryIntentHasEnglishPhrases() {
        for i in VoiceIntent.allCases {
            XCTAssertFalse((PhraseTables.en.phrases[i] ?? []).isEmpty, i.name)
            for ph in PhraseTables.en.phrases[i]! { XCTAssertEqual(i, intentOf(ph), ph) }
        }
    }

    func testPhraseUnderTwoIntentsIsRejectedAtConstruction() {
        var bad = PhraseTables.en
        bad.phrases[.quieter] = ["pause"]
        XCTAssertThrowsError(try VoiceIntentParser(bad))
    }

    func testNewLocaleNeedsOnlyData() throws {
        let toy = PhraseTable(locale: "xx", phrases: [.pause: ["ruk"], .resume: ["chalo"]], fillers: ["zara"],
                              negations: ["mat"], yes: ["haan"], no: ["nahin"])
        let q = try VoiceIntentParser(toy)
        if case .match(let m) = q.parse("zara ruk") { XCTAssertEqual(.pause, m.intent) } else { XCTFail("no match") }
        XCTAssertEqual(.noMatch("negated"), q.parse("ruk mat"))
        XCTAssertEqual(.yes, q.parseConfirmation("haan"))
    }
}
