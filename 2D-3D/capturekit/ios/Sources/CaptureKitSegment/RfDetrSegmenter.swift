import CaptureKit
import Foundation
import LiteRT

/// RF-DETR-Seg Nano on the LiteRT CompiledModel (Metal GPU, CPU for ops the GPU cannot run), ADR 0035/0037: graph A (image + two host
/// constants -> encoder class / delta / memory2), host math (`RfDetr` in CaptureKit), graph B (memory, reference points, query
/// features -> boxes, logits, masks). Same .tflite files as Android, fetched by scripts/fetch_models.sh --with-segmentation and
/// copied into the app bundle (ios/README.md). The model card says baked large constants mis-execute on the ML Drift GPU delegate,
/// so clspos / pospatch / query_feat are fed as inputs.
///
/// UNVERIFIED until a device run (Mac/iPhone checks): that LiteRT-Swift 2.3.0 Metal executes these graphs, that `TensorBuffer.write`
/// throws on a wrong float count (input slots are found by offering each candidate array, largest first, like the Android code),
/// the proposal cell order (row-major assumed) and latency. Single-threaded: `segment` runs on the segmentation queue only.
public final class RfDetrSegmenter: Segmenter {
    public static let graphA = "rfdetrseg_graphA_fp16.tflite"
    public static let graphB = "rfdetrseg_graphB_fp16.tflite"
    public static let clspos = "clspos.bin"
    public static let pospatch = "pospatch.bin"
    public static let queryFeat = "query_feat.bin"
    public static let refpoint = "refpoint_embed.bin"
    public static let allFiles = [graphA, graphB, clspos, pospatch, queryFeat, refpoint]

    public let name: String

    private let env: Environment
    private let ga: CompiledModel
    private let gb: CompiledModel
    private let refpointEmbed: [Float]
    private var aIn: [TensorBuffer], aOut: [TensorBuffer], bIn: [TensorBuffer], bOut: [TensorBuffer]
    private let slotImage: Int, slotMem: Int, slotRef: Int
    private var chw = [Float](repeating: 0, count: RfDetr.nImage)

    private init(env: Environment, ga: CompiledModel, gb: CompiledModel, refpoint: [Float],
                 aIn: [TensorBuffer], aOut: [TensorBuffer], bIn: [TensorBuffer], bOut: [TensorBuffer],
                 slotImage: Int, slotMem: Int, slotRef: Int, name: String) {
        self.env = env; self.ga = ga; self.gb = gb; self.refpointEmbed = refpoint
        self.aIn = aIn; self.aOut = aOut; self.bIn = bIn; self.bOut = bOut
        self.slotImage = slotImage; self.slotMem = slotMem; self.slotRef = slotRef; self.name = name
    }

    public func segment(_ image: SegImage, quarterTurns: Int) -> [Instance]? {
        guard image.w > 0, image.h > 0, !aIn.isEmpty else { return nil }
        RfDetr.preprocess(image, turns: quarterTurns, out: &chw)
        do {
            try aIn[slotImage].write(chw)
            try ga.run(inputs: aIn, outputs: aOut)
            var encClass: [Float]?, encDelta: [Float]?, memory2: [Float]?
            for b in aOut {
                let a: [Float] = try b.read()
                switch a.count {
                case RfDetr.nEncClass: encClass = a
                case RfDetr.nEncDelta: encDelta = a
                case RfDetr.nMemory: memory2 = a
                default: break
                }
            }
            guard let encClass, let encDelta, let memory2 else { NSLog("CK/Segment: graph A outputs not recognised"); return nil }
            let props = RfDetr.proposals(encClass: encClass, encDelta: encDelta)
            try bIn[slotMem].write(RfDetr.memory(memory2))
            try bIn[slotRef].write(RfDetr.refPoints(ts: props.ts, refpointEmbed: refpointEmbed))
            try gb.run(inputs: bIn, outputs: bOut)
            var boxes: [Float]?, logits: [Float]?, masks: [Float]?
            for b in bOut {
                let a: [Float] = try b.read()
                switch a.count {
                case RfDetr.nBoxes: boxes = a
                case RfDetr.nLogits: logits = a
                case RfDetr.nMasks: masks = a
                default: break
                }
            }
            guard let boxes, let logits else { NSLog("CK/Segment: graph B outputs not recognised"); return nil }
            return RfDetr.decode(boxes: boxes, logits: logits, masks: masks, turns: quarterTurns, w: image.w, h: image.h)
        } catch {
            NSLog("CK/Segment: run failed: %@", String(describing: error))
            return nil
        }
    }

    public func close() {
        aIn = []; aOut = []; bIn = []; bOut = []   // the buffers and models release with their last reference
    }

    // MARK: loading

    private static func path(_ file: String, in bundle: Bundle) -> String? {
        let ns = file as NSString
        return bundle.path(forResource: ns.deletingPathExtension, ofType: ns.pathExtension)
    }

    /// True when all six files are packaged. Cheap, never throws.
    public static func available(bundle: Bundle = .main) -> Bool { allFiles.allSatisfy { path($0, in: bundle) != nil } }

    private static func floats(_ file: String, count: Int, in bundle: Bundle) -> [Float]? {
        guard let p = path(file, in: bundle), let d = try? Data(contentsOf: p.asFileURL) else { return nil }
        return RfDetr.loadFloats([UInt8](d), count: count)
    }

    /// Slot of each candidate array among `bufs`: every buffer is offered the candidates largest first and keeps the first one it
    /// accepts (a write of the wrong float count throws). Nil when a candidate found no slot.
    private static func bind(_ bufs: [TensorBuffer], _ cands: [[Float]]) -> [Int]? {
        var slot = [Int](repeating: -1, count: cands.count)
        let bySize = cands.indices.sorted { cands[$0].count > cands[$1].count }
        for (bi, b) in bufs.enumerated() {
            for ci in bySize where slot[ci] < 0 {
                if (try? b.write(cands[ci])) != nil { slot[ci] = bi; break }
            }
        }
        return slot.allSatisfy { $0 >= 0 } ? slot : nil
    }

    /// Loads both graphs on the GPU, or nil (feature off) when a file is missing/bad or LiteRT cannot compile them. Slow: worker only.
    public static func open(bundle: Bundle = .main) -> RfDetrSegmenter? {
        guard available(bundle: bundle),
              let gaPath = path(graphA, in: bundle), let gbPath = path(graphB, in: bundle),
              let cls = floats(clspos, count: RfDetr.nClsPos, in: bundle),
              let pos = floats(pospatch, count: RfDetr.nPosPatch, in: bundle),
              let qf = floats(queryFeat, count: RfDetr.nQueryFeat, in: bundle),
              let rp = floats(refpoint, count: RfDetr.nRef, in: bundle) else {
            NSLog("CK/Segment: segmentation off: model files missing or a host constant has the wrong size")
            return nil
        }
        do {
            let env = try Environment()
            let options = try Options()
            try options.setHardwareAccelerators([.gpu, .cpu])
            let ga = try CompiledModel(filePath: gaPath, environment: env, options: options)
            let gb = try CompiledModel(filePath: gbPath, environment: env, options: options)
            let aIn = try ga.createInputBuffers(), aOut = try ga.createOutputBuffers()
            let bIn = try gb.createInputBuffers(), bOut = try gb.createOutputBuffers()
            guard aIn.count == 3, bIn.count == 3, aOut.count == 3, bOut.count == 3 else {
                NSLog("CK/Segment: unexpected graph layout: A %d->%d, B %d->%d", aIn.count, aOut.count, bIn.count, bOut.count)
                return nil
            }
            guard let sa = bind(aIn, [[Float](repeating: 0, count: RfDetr.nImage), cls, pos]),
                  let sb = bind(bIn, [[Float](repeating: 0, count: RfDetr.nMemory), qf, [Float](repeating: 0, count: RfDetr.nRef)]) else {
                NSLog("CK/Segment: graph input slots not found")
                return nil
            }
            NSLog("CK/Segment: segmenter ready")
            return RfDetrSegmenter(env: env, ga: ga, gb: gb, refpoint: rp, aIn: aIn, aOut: aOut, bIn: bIn, bOut: bOut,
                                   slotImage: sa[0], slotMem: sb[0], slotRef: sb[2], name: "rf-detr-seg-nano litert-metal")
        } catch {
            NSLog("CK/Segment: RF-DETR-Seg init failed, segmentation off: %@", String(describing: error))
            return nil
        }
    }
}

private extension String {
    var asFileURL: URL { URL(fileURLWithPath: self) }
}
