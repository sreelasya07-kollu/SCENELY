import Foundation

/// COCO class indices of the EfficientDet-Lite0 detector (0-based, person = 0, ADR 0017) mapped to the core's object
/// classes (understanding.hpp ObjectClass ids). Core ids are append-only (ADR 0030). Port of the Kotlin LabelMap (ADR 0037).
public enum LabelMap {
    public static let unknown = 0
    public static let chair = 1
    public static let couch = 2
    public static let bed = 3
    public static let diningTable = 4
    public static let tv = 5
    public static let pottedPlant = 6
    public static let laptop = 7
    public static let bench = 8
    public static let toilet = 9
    public static let sink = 10
    public static let refrigerator = 11
    public static let oven = 12
    public static let desk = 13
    public static let shelf = 14
    public static let cabinet = 15
    public static let lamp = 16

    /// Same names as the core's kObjectClassNames, indexed by core class id.
    public static let coreNames = [
        "unknown", "chair", "couch", "bed", "dining_table", "tv", "potted_plant", "laptop",
        "bench", "toilet", "sink", "refrigerator", "oven",
        "desk", "shelf", "cabinet", "lamp",
    ]

    private static let cocoToCore: [Int: Int] = [
        14: bench, 61: chair, 62: couch, 63: pottedPlant, 64: bed, 66: diningTable, 69: toilet,
        71: tv, 72: laptop, 78: oven, 80: sink, 81: refrigerator,
    ]

    /// Singular and plural words, keyed by core name; same words as the core's spoken landmark phrases.
    private static let spoken: [String: (String, String)] = [
        "chair": ("chair", "chairs"), "couch": ("sofa", "sofas"), "bed": ("bed", "beds"),
        "dining_table": ("table", "tables"), "tv": ("TV", "TVs"), "potted_plant": ("plant", "plants"),
        "laptop": ("laptop", "laptops"), "bench": ("bench", "benches"), "toilet": ("toilet", "toilets"),
        "sink": ("sink", "sinks"), "refrigerator": ("fridge", "fridges"), "oven": ("oven", "ovens"),
        "desk": ("desk", "desks"), "shelf": ("shelf", "shelves"), "cabinet": ("cabinet", "cabinets"),
        "lamp": ("lamp", "lamps"), "door": ("door", "doors"), "window": ("window", "windows"),
    ]

    /// Core class id for an EfficientDet class index, `unknown` when not mapped.
    public static func coreClass(_ cocoIndex: Int) -> Int { cocoToCore[cocoIndex] ?? unknown }

    /// Core class id for a COCO category id as RF-DETR emits it (category id = EfficientDet index + 1; ADR 0035). UNVERIFIED on device.
    public static func fromCocoCategory(_ categoryId: Int) -> Int { coreClass(categoryId - 1) }

    /// COCO 2017 category names by category id (index = id; "" = unused id), as the live object boxes label them.
    private static let cocoNames: [String] = ("|person|bicycle|car|motorcycle|airplane|bus|train|truck|boat|traffic light|fire hydrant||stop sign|" +
        "parking meter|bench|bird|cat|dog|horse|sheep|cow|elephant|bear|zebra|giraffe||backpack|umbrella|||handbag|tie|suitcase|frisbee|skis|" +
        "snowboard|sports ball|kite|baseball bat|baseball glove|skateboard|surfboard|tennis racket|bottle||wine glass|cup|fork|knife|spoon|bowl|" +
        "banana|apple|sandwich|orange|broccoli|carrot|hot dog|pizza|donut|cake|chair|couch|potted plant|bed||dining table|||toilet||tv|laptop|" +
        "mouse|remote|keyboard|cell phone|microwave|oven|toaster|sink|refrigerator||book|clock|vase|scissors|teddy bear|hair drier|toothbrush")
        .split(separator: "|", omittingEmptySubsequences: false).map(String.init)

    /// Display name of a COCO category id; "" for an id COCO does not use.
    public static func cocoName(_ categoryId: Int) -> String {
        (0..<cocoNames.count).contains(categoryId) ? cocoNames[categoryId] : ""
    }

    public static func coreName(_ coreClass: Int) -> String {
        (0..<coreNames.count).contains(coreClass) ? coreNames[coreClass] : "unknown"
    }

    /// Display word for a core class NAME or an opening kind; `plural` for counts other than 1.
    /// An unknown name is shown as itself with underscores as spaces, never dropped.
    public static func displayName(_ coreName: String, plural: Bool = false) -> String {
        guard let p = spoken[coreName] else {
            let s = coreName.replacingOccurrences(of: "_", with: " ")
            return plural ? s + "s" : s
        }
        return plural ? p.1 : p.0
    }

    /// Display word for a core class id.
    public static func displayName(coreClass: Int) -> String { displayName(coreName(coreClass)) }

    /// "chair 82%": the box label; the score is clamped to 0..100 % and rounded.
    public static func boxLabel(coreClass: Int, score: Float) -> String {
        let pct = score.isFinite ? Int((min(max(score, 0), 1) * 100).rounded()) : 0
        return "\(displayName(coreClass: coreClass)) \(pct)%"
    }
}
