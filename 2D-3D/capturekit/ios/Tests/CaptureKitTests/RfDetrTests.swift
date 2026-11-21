import XCTest
@testable import CaptureKit

/// Host math of RF-DETR-Seg Nano on synthetic tensors, ported 1:1 from Kotlin RfDetrTest (ADR 0035).
final class RfDetrTests: XCTestCase {
    private typealias R = RfDetr

    private func encClass(_ hot: [(Int, Float)]) -> [Float] {
        var a = [Float](repeating: -10, count: R.nEncClass)
        for (cell, v) in hot { a[cell * R.classes + 5] = v }
        return a
    }

    func testProposalGridAndTopHundred() {
        var delta = [Float](repeating: 0, count: R.nEncDelta)
        // Cell 27 = (gx 1, gy 1) with a delta; cell 0 and 675 are the corners.
        delta[4 * 27] = 2; delta[4 * 27 + 1] = -4; delta[4 * 27 + 2] = 0; delta[4 * 27 + 3] = Float(log(2.0))
        let p = R.proposals(encClass: encClass([(27, 9), (0, 8), (675, 7)]), encDelta: delta)
        XCTAssertEqual(R.queries, p.cell.count)
        XCTAssertEqual([27, 0, 675], Array(p.cell.prefix(3)))   // best logit first
        // cxcy = delta[:2] * 0.05 + ((gx + .5) / 26, (gy + .5) / 26); wh = exp(delta[2:]) * 0.05
        XCTAssertEqual(2 * 0.05 + 1.5 / 26, p.ts[0], accuracy: 1e-6)
        XCTAssertEqual(-4 * 0.05 + 1.5 / 26, p.ts[1], accuracy: 1e-6)
        XCTAssertEqual(0.05, p.ts[2], accuracy: 1e-6)
        XCTAssertEqual(0.10, p.ts[3], accuracy: 1e-6)
        XCTAssertEqual(0.5 / 26, p.ts[4], accuracy: 1e-6)   // cell 0 corner, zero delta
        XCTAssertEqual(25.5 / 26, p.ts[8], accuracy: 1e-6); XCTAssertEqual(25.5 / 26, p.ts[9], accuracy: 1e-6)
        // Ties resolve to the lower cell index: all other cells are equal (-10), so the rest is cells 1, 2, 3 ...
        XCTAssertEqual([1, 2, 3], Array(p.cell[3..<6]))
    }

    func testReferencePointsReparametrisation() {
        var ts = [Float](repeating: 0, count: R.nRef), rp = [Float](repeating: 0, count: R.nRef)
        ts[0] = 0.4; ts[1] = 0.6; ts[2] = 0.2; ts[3] = 0.1
        rp[0] = 1; rp[1] = -2; rp[2] = 0; rp[3] = Float(log(3.0))
        let ref = R.refPoints(ts: ts, refpointEmbed: rp)
        XCTAssertEqual(1 * 0.2 + 0.4, ref[0], accuracy: 1e-6)     // rp[:2] * wh + cxcy
        XCTAssertEqual(-2 * 0.1 + 0.6, ref[1], accuracy: 1e-6)
        XCTAssertEqual(exp(Float(0)) * 0.2, ref[2], accuracy: 1e-6)   // exp(rp[2:]) * wh
        XCTAssertEqual(3 * 0.1, ref[3], accuracy: 1e-6)
    }

    func testMemoryIsHalfOfMemory2() {
        XCTAssertEqual([1, -2, 0.5], R.memory([2, -4, 1]))
    }

    private func logits(_ q: [(Int, Int, Float)]) -> [Float] {
        var a = [Float](repeating: -10, count: R.nLogits)
        for (qi, k, v) in q { a[qi * R.classes + k] = v }
        return a
    }

    private func boxes(_ q: [(Int, [Float])] = []) -> [Float] {
        var a = (0..<R.nBoxes).map { $0 % 4 < 2 ? Float(0.5) : Float(0.2) }
        for (qi, b) in q { for j in 0..<4 { a[4 * qi + j] = b[j] } }
        return a
    }

    func testThresholdSigmoidAndNonCocoIdsAreDropped() {
        let l = logits([(0, 62, 2), (1, 62, -1), (2, 12, 5), (3, 0, 6)])   // 12 = unused COCO id, 0 = background slot
        let c = R.candidates(boxes: boxes(), logits: l)
        XCTAssertEqual([0], c.map { $0.query })
        XCTAssertEqual(1 / (1 + exp(Float(-2))), c[0].score, accuracy: 1e-6)
        XCTAssertEqual(62, c[0].coco)
        XCTAssertEqual(0.4, c[0].x0, accuracy: 1e-6); XCTAssertEqual(0.6, c[0].x1, accuracy: 1e-6)   // cxcywh -> corners
    }

    func testPerClassNmsKeepsTheBestAndOtherClasses() {
        let same: [Float] = [0.5, 0.5, 0.4, 0.4]
        let near: [Float] = [0.52, 0.5, 0.4, 0.4]
        let l = logits([(0, 62, 3), (1, 62, 2), (2, 63, 1), (3, 62, 4)])
        let b = boxes([(0, same), (1, near), (2, near), (3, [0.1, 0.1, 0.1, 0.1])])
        let kept = R.nms(R.candidates(boxes: b, logits: l))
        XCTAssertEqual([3, 0, 2], kept.map { $0.query })   // query 1 (chair, overlaps the better chair 0) dies; the couch survives
        XCTAssertEqual(1, R.nms(R.candidates(boxes: b, logits: l), max: 1).count)
    }

    func testDecodeUnrotatesBoxAndTakesTheMaskCentroid() {
        let b = boxes([(0, [0.25, 0.5, 0.2, 0.4])])     // upright box x .15..35, y .3..7
        let l = logits([(0, 62, 3)])
        var masks = [Float](repeating: -5, count: R.nMasks)
        // Mask pixels (x 20..21, y 40..41) of query 0 -> centroid (21 / 78, 41 / 78) in the upright image.
        for y in 40...41 { for x in 20...21 { masks[y * R.mask + x] = 3 } }
        let up = R.decode(boxes: b, logits: l, masks: masks, turns: 0, w: 640, h: 480)
        XCTAssertEqual(1, up.count)
        XCTAssertEqual("chair", up[0].label)
        XCTAssertEqual(0.15 * 640, up[0].box.x0, accuracy: 1e-3); XCTAssertEqual(0.7 * 480, up[0].box.y1, accuracy: 1e-3)
        XCTAssertEqual(21.0 / 78 * 640, up[0].cx, accuracy: 1e-2); XCTAssertEqual(41.0 / 78 * 480, up[0].cy, accuracy: 1e-2)
        // The same scene seen through a 90 degree clockwise rotated image: corners map back to the sensor image.
        let r = R.decode(boxes: b, logits: l, masks: masks, turns: 1, w: 640, h: 480)[0]
        XCTAssertEqual(0.3 * 640, r.box.x0, accuracy: 1e-3); XCTAssertEqual(0.7 * 640, r.box.x1, accuracy: 1e-3)       // x = v
        XCTAssertEqual((1 - 0.35) * 480, r.box.y0, accuracy: 1e-3); XCTAssertEqual((1 - 0.15) * 480, r.box.y1, accuracy: 1e-3)   // y = 1 - u
        // No mask pixels: the box centre.
        let none = R.decode(boxes: b, logits: l, masks: [Float](repeating: -1, count: R.nMasks), turns: 0, w: 100, h: 100)[0]
        XCTAssertEqual(25, none.cx, accuracy: 1e-3); XCTAssertEqual(50, none.cy, accuracy: 1e-3)
    }

    func testRotationHelpersRoundTrip() {
        XCTAssertEqual(0, R.quarterTurns(dxView: 1, dyView: 0.1)); XCTAssertEqual(1, R.quarterTurns(dxView: 0.1, dyView: 1))
        XCTAssertEqual(2, R.quarterTurns(dxView: -1, dyView: 0)); XCTAssertEqual(3, R.quarterTurns(dxView: 0, dyView: -1))
        // Rotating the image clockwise by k and un-rotating the corner of a pixel must land on the original pixel.
        for k in 0...3 {
            let (x, y) = R.unrotate(k, 0.2, 0.7)
            var u = x, v = y
            for _ in 0..<k { let nu = 1 - v, nv = u; u = nu; v = nv }   // forward clockwise quarter turn: (x, y) -> (1 - y, x)
            XCTAssertEqual(0.2, u, accuracy: 1e-6); XCTAssertEqual(0.7, v, accuracy: 1e-6)
        }
    }

    private struct TestImage: SegImage {
        let w: Int, h: Int
        let pixel: (Int, Int) -> UInt32
        func argb(_ x: Int, _ y: Int) -> UInt32 { pixel(x, y) }
    }

    func testPreprocessIsNchwImageNetNormalisedAndRotates() {
        // 4 x 2 landscape image: left half black, right half white.
        let img = TestImage(w: 4, h: 2) { x, _ in x >= 2 ? 0xFFFFFFFF : 0xFF000000 }
        var out = [Float](repeating: 0, count: R.nImage)
        R.preprocess(img, turns: 0, out: &out)
        let plane = R.side * R.side
        XCTAssertEqual((0 - 0.485) / 0.229, out[0], accuracy: 1e-4)                            // R plane, top-left = black
        XCTAssertEqual((1 - 0.456) / 0.224, out[plane + R.side - 1], accuracy: 1e-4)           // G plane, top-right = white
        XCTAssertEqual((1 - 0.406) / 0.225, out[2 * plane + R.side - 1], accuracy: 1e-4)       // B plane
        // Rotated 90 degrees clockwise the white half is on the bottom: top-left stays black, bottom-left is white.
        R.preprocess(img, turns: 1, out: &out)
        XCTAssertEqual((0 - 0.485) / 0.229, out[0], accuracy: 1e-4)
        XCTAssertEqual((1 - 0.485) / 0.229, out[(R.side - 1) * R.side], accuracy: 1e-4)
    }

    func testHostConstantsMustHaveTheExactSize() {
        func le(_ f: Float) -> [UInt8] { let b = f.bitPattern; return [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8(b >> 24)] }
        let bytes = le(1) + le(-2) + le(0.5)
        XCTAssertEqual([1, -2, 0.5], R.loadFloats(bytes, count: 3))
        XCTAssertNil(R.loadFloats(bytes, count: 4)); XCTAssertNil(R.loadFloats(Array(bytes.prefix(11)), count: 3))
    }

    func testEveryGraphBufferHasADistinctFloatCountSoSlotsCanBeToldApart() {
        let a = [R.nImage, R.nClsPos, R.nPosPatch]
        let aOut = [R.nEncClass, R.nEncDelta, R.nMemory]
        let b = [R.nMemory, R.nQueryFeat, R.nRef]
        let bOut = [R.nBoxes, R.nLogits, R.nMasks]
        for s in [a, aOut, b, bOut] { XCTAssertEqual(3, Set(s).count) }
        XCTAssertEqual(3 * 312 * 312, R.nImage); XCTAssertEqual(676 * 91, R.nEncClass); XCTAssertEqual(100 * 78 * 78, R.nMasks)
    }

    /// Slot resolution by float count, in whatever order the converter lists the buffers.
    func testResolveSlotsByFloatCount() {
        let shuffled = [R.nPosPatch, R.nImage, R.nClsPos]
        XCTAssertEqual([1, 2, 0], R.resolveSlots(bufferCounts: shuffled, wanted: [R.nImage, R.nClsPos, R.nPosPatch]))
        XCTAssertEqual([2, 0, 1], R.resolveSlots(bufferCounts: [R.nQueryFeat, R.nRef, R.nMemory], wanted: [R.nMemory, R.nQueryFeat, R.nRef]))
        XCTAssertNil(R.resolveSlots(bufferCounts: [R.nImage, R.nClsPos], wanted: [R.nImage, R.nClsPos, R.nPosPatch]))
        // The same size twice needs two buffers of that size.
        XCTAssertNil(R.resolveSlots(bufferCounts: [5, 6], wanted: [5, 5]))
        XCTAssertEqual([0, 1], R.resolveSlots(bufferCounts: [5, 5], wanted: [5, 5]))
    }

    func testCocoCategoryLabelMapPinsChairCouchTv() {
        // RF-DETR class = COCO category id = EfficientDet index + 1 (ADR 0035; ADR 0017 chair 61 -> 62).
        XCTAssertEqual(LabelMap.chair, LabelMap.fromCocoCategory(62)); XCTAssertEqual("chair", LabelMap.cocoName(62))
        XCTAssertEqual(LabelMap.couch, LabelMap.fromCocoCategory(63)); XCTAssertEqual("couch", LabelMap.cocoName(63))
        XCTAssertEqual(LabelMap.tv, LabelMap.fromCocoCategory(72)); XCTAssertEqual("tv", LabelMap.cocoName(72))
        XCTAssertEqual(LabelMap.bed, LabelMap.fromCocoCategory(65)); XCTAssertEqual(LabelMap.diningTable, LabelMap.fromCocoCategory(67))
        XCTAssertEqual(LabelMap.unknown, LabelMap.fromCocoCategory(1))      // person: not a core class
        XCTAssertEqual("person", LabelMap.cocoName(1)); XCTAssertEqual("toothbrush", LabelMap.cocoName(90))
        XCTAssertEqual("", LabelMap.cocoName(12)); XCTAssertEqual("", LabelMap.cocoName(0)); XCTAssertEqual("", LabelMap.cocoName(91))
        // Every core-mapped category has a COCO name.
        for cat in 1...90 where LabelMap.fromCocoCategory(cat) != LabelMap.unknown { XCTAssertFalse(LabelMap.cocoName(cat).isEmpty, "\(cat)") }
    }
}
