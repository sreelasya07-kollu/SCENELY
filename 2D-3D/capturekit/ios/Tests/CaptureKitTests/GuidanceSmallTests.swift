import XCTest
@testable import CaptureKit

/// Ported 1:1 from Kotlin VolumeStepsTest, ObjectSummaryTest and StatusPillTest (+ LabelMap checks, incl. the RF-DETR category shift).
final class VolumeStepsTests: XCTestCase {
    func testDefaultIsFullAndLouderIsRefused() {
        var v = VolumeSteps()
        XCTAssertEqual(1.0, v.volume)
        XCTAssertFalse(v.louder())
        XCTAssertEqual(1.0, v.volume)
    }

    func testQuieterWalksDownAndStopsAboveSilence() {
        var v = VolumeSteps()
        var n = 0
        while v.quieter() { n += 1 }
        XCTAssertEqual(VolumeSteps.levels.count - 1, n)
        XCTAssertTrue(v.volume > 0)
        XCTAssertFalse(v.quieter())
    }

    func testLouderRestoresAndOutOfRangeStartIsClamped() {
        var v = VolumeSteps(initialIndex: -5)
        XCTAssertEqual(VolumeSteps.levels.first!, v.volume)
        XCTAssertTrue(v.louder())
        XCTAssertTrue(v.volume > VolumeSteps.levels.first!)
        XCTAssertEqual(VolumeSteps.levels.last!, VolumeSteps(initialIndex: 99).volume)
    }
}

final class ObjectSummaryTests: XCTestCase {
    private func obj(_ id: Int, _ cls: String) -> ObjectBox { ObjectBox(id, cls, 0, 0, 0.5, 0.5, 0, 0.9) }
    private func open(_ kind: String) -> Opening { Opening(kind, "W1", 0, 0, 1, 0, 0, 2) }

    func testNothingFoundIsEmpty() {
        XCTAssertEqual("", ObjectSummary.text(objects: []))
        XCTAssertEqual([ObjectSummary.Count](), ObjectSummary.counts(objects: [], openings: []))
    }

    func testCountsPerClassMostFrequentFirstWithSpokenWordsAndPlurals() {
        let objects = [obj(1, "couch"), obj(2, "chair"), obj(3, "tv"), obj(4, "chair"), obj(5, "dining_table")]
        XCTAssertEqual("2 chairs, 1 sofa, 1 TV, 1 table", ObjectSummary.text(objects: objects))
    }

    func testDoorsAndWindowsFromTheWallsAreIncludedAfterObjectsOnTies() {
        let s = ObjectSummary.text(objects: [obj(1, "bed")], openings: [open("window"), open("door"), open("window"), open("skylight")])
        XCTAssertEqual("2 windows, 1 bed, 1 door", s)
    }

    func testUnknownAndBlankClassesAreSkippedButNewClassesAreKept() {
        let s = ObjectSummary.text(objects: [obj(1, "unknown"), obj(2, ""), obj(3, "refrigerator"), obj(4, "coffee_machine")])
        XCTAssertEqual("1 fridge, 1 coffee machine", s)
    }

    func testWorksOnTheOverlayStringTheReviewScreenReceives() {
        let encoded = EventParser.encodeObjects([obj(1, "chair"), obj(2, "shelf"), obj(3, "shelf")])
        XCTAssertEqual("2 shelves, 1 chair", ObjectSummary.text(objects: EventParser.parseObjects(encoded)))
    }
}

final class StatusPillTests: XCTestCase {
    private typealias SP = StatusPill
    private func pill(_ t: String, _ f: String, _ r: [String], _ th: Int, everTracked: Bool = false) -> SP.Pill {
        SP.statusPill(trackState: t, failure: f, reasons: r, thermalLevel: th, everTracked: everTracked)
    }

    private let expected: [String: String] = [
        "TRACKING_LOST": "Tracking lost", "TRACKING_LIMITED": "Keep going", "MOTION_BLUR": "Move slower", "BLUR": "Hold steady",
        "SOFT_FOCUS": "Hold steady", "OVEREXPOSED": "Keep going", "UNDEREXPOSED": "More light", "LOW_TEXTURE": "Keep going",
        "POOR_SPREAD": "Keep going", "NO_IMAGE": "Keep going", "NOT_NOVEL": "Good", "MIN_GAP": "Good", "NOT_BEST": "Good",
        "RECALIBRATING": "Recalibrating", "DUPLICATE": "Good",
    ]

    func testRecalibratingOutranksEverythingButTrackingLost() {
        XCTAssertEqual(SP.recalibrating, pill("PAUSED", "INSUFFICIENT_FEATURES", ["MOTION_BLUR", "RECALIBRATING"], 4, everTracked: true))
        XCTAssertEqual(SP.lost, pill("STOPPED", "NONE", ["RECALIBRATING"], 0, everTracked: true))
    }

    func testEveryCoreReasonHasAPlainPhrase() {
        XCTAssertEqual(Set(expected.keys), Set(SP.reasonCodes))
        for code in SP.reasonCodes {
            let p = pill("TRACKING", "NONE", [code], 0)
            XCTAssertEqual(expected[code], p.text, code)
            XCTAssertFalse(p.text.contains("_"), code)
        }
    }

    func testUnknownReasonIsKeepGoing() { XCTAssertEqual(SP.keepGoing, SP.forReason("SOMETHING_NEW")) }

    func testAllClearIsGood() { XCTAssertEqual(SP.good, pill("TRACKING", "NONE", [], 0)) }

    func testPriorityOrder() {
        let all = ["UNDEREXPOSED", "SOFT_FOCUS", "MOTION_BLUR"]
        XCTAssertEqual(SP.lost, pill("STOPPED", "NONE", all, 3))
        XCTAssertEqual(SP.tooFast, pill("TRACKING", "NONE", all, 3))
        XCTAssertEqual(SP.hold, pill("TRACKING", "NONE", ["UNDEREXPOSED", "SOFT_FOCUS"], 3))
        XCTAssertEqual(SP.light, pill("TRACKING", "NONE", ["UNDEREXPOSED", "NOT_NOVEL"], 3))
        XCTAssertEqual(SP.warming, pill("TRACKING", "NONE", ["NOT_NOVEL"], 1))
        XCTAssertEqual(SP.hot, pill("TRACKING", "NONE", [], 4))
        XCTAssertEqual(SP.keepGoing, pill("TRACKING", "NONE", ["MIN_GAP", "LOW_TEXTURE"], 0))
    }

    func testTrackingFailuresMapToPlainPhrases() {
        XCTAssertEqual(SP.tooFast, pill("PAUSED", "EXCESSIVE_MOTION", [], 0))
        XCTAssertEqual(SP.light, pill("PAUSED", "INSUFFICIENT_LIGHT", [], 0))
        XCTAssertEqual(SP.hold, pill("PAUSED", "INSUFFICIENT_FEATURES", [], 0))
        XCTAssertEqual(SP.starting, pill("?", "NONE", ["MOTION_BLUR"], 5))
        XCTAssertEqual(SP.starting, pill("PAUSED", "NONE", [], 0))
    }

    func testSelectorReasonsNeverAffectThePill() {
        for code in ["NOT_NOVEL", "MIN_GAP", "NOT_BEST", "DUPLICATE"] { XCTAssertNil(SP.forReason(code), code) }
        XCTAssertEqual(SP.good, pill("TRACKING", "NONE", ["NOT_NOVEL", "MIN_GAP", "NOT_BEST"], 0))
        XCTAssertEqual(SP.warming, pill("TRACKING", "NONE", ["NOT_BEST"], 2))
    }

    func testStartingOnlyBeforeFirstTracking() {
        XCTAssertEqual(SP.starting, pill("PAUSED", "NONE", [], 0, everTracked: false))
        XCTAssertEqual(SP.hold, pill("PAUSED", "NONE", [], 0, everTracked: true))
        XCTAssertEqual(SP.hold, pill("?", "NONE", ["NOT_NOVEL"], 0, everTracked: true))
        XCTAssertEqual(SP.tooFast, pill("PAUSED", "NONE", ["MOTION_BLUR"], 0, everTracked: true))
    }

    func testTonesMatchSeverity() {
        XCTAssertEqual(SP.Tone.bad, SP.lost.tone)
        XCTAssertEqual(SP.Tone.good, SP.good.tone)
        XCTAssertTrue([SP.tooFast, SP.hold, SP.light, SP.warming].allSatisfy { $0.tone == .warn })
    }
}

final class LabelMapTests: XCTestCase {
    /// ADR 0035: RF-DETR class index = COCO category id = EfficientDet index + 1. A unit test pins chair, couch and tv (UNVERIFIED on device).
    func testFromCocoCategoryPinsChairCouchAndTv() {
        XCTAssertEqual(LabelMap.chair, LabelMap.fromCocoCategory(62))
        XCTAssertEqual(LabelMap.couch, LabelMap.fromCocoCategory(63))
        XCTAssertEqual(LabelMap.tv, LabelMap.fromCocoCategory(72))
        XCTAssertEqual(LabelMap.unknown, LabelMap.fromCocoCategory(1))   // person
        XCTAssertEqual(LabelMap.unknown, LabelMap.fromCocoCategory(0))
        XCTAssertEqual(LabelMap.chair, LabelMap.coreClass(61))
    }

    func testNamesAndDisplayWords() {
        XCTAssertEqual("chair", LabelMap.coreName(LabelMap.chair))
        XCTAssertEqual("unknown", LabelMap.coreName(99))
        XCTAssertEqual("sofa", LabelMap.displayName("couch"))
        XCTAssertEqual("sofas", LabelMap.displayName("couch", plural: true))
        XCTAssertEqual("coffee machines", LabelMap.displayName("coffee_machine", plural: true))
        XCTAssertEqual("chair 82%", LabelMap.boxLabel(coreClass: LabelMap.chair, score: 0.82))
        XCTAssertEqual("chair 100%", LabelMap.boxLabel(coreClass: LabelMap.chair, score: 7))
        XCTAssertEqual("chair 0%", LabelMap.boxLabel(coreClass: LabelMap.chair, score: .nan))
    }
}
