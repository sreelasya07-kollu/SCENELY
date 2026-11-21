import Foundation

/// What a segmentation prompt points at.
public enum SurfaceKind { case floor, wall, ceiling, object }

/// Stable identity a prompt carries when it has one: the core 3D object id, an AR plane, or a core layout wall.
public enum TrackKey: Hashable {
    /// Core overlay object id.
    case coreObject(Int)
    /// AR plane (the host numbers each plane once per AR session).
    case plane(Int64)
    /// Core layout wall id (overlay v3 `surfaces` id, 1-based).
    case layoutWall(Int)
}

/// World point in metres (Y-up, the AR / core world frame).
public struct Vec3: Equatable {
    public var x: Float, y: Float, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    public func dist(_ o: Vec3) -> Float {
        let dx = x - o.x, dy = y - o.y, dz = z - o.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

/// Axis-aligned box in camera-image pixels (x0 < x1, y0 < y1).
public struct Box2: Equatable {
    public var x0: Float, y0: Float, x1: Float, y1: Float
    public init(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    public var area: Float { max(0, x1 - x0) * max(0, y1 - y0) }
    public func iou(_ o: Box2) -> Float {
        let iw = min(x1, o.x1) - max(x0, o.x0)
        let ih = min(y1, o.y1) - max(y0, o.y0)
        if iw <= 0 || ih <= 0 { return 0 }
        let inter = iw * ih
        let union = area + o.area - inter
        return union > 0 ? inter / union : 0
    }
}

/// One prompt for the tracker: a point (x, y in camera-image pixels), an optional projected box and the 3D centre used for re-identification.
public struct SegPrompt {
    public var key: TrackKey?
    public var kind: SurfaceKind
    public var label: String
    public var x: Float, y: Float
    public var box: Box2?
    public var centre: Vec3?
    /// Live object boxes: COCO category id and score of the sighting; 0 when not a model instance.
    public var cocoId: Int
    public var score: Float
    public init(key: TrackKey?, kind: SurfaceKind, label: String, x: Float, y: Float, box: Box2? = nil, centre: Vec3? = nil,
                cocoId: Int = 0, score: Float = 0) {
        self.key = key; self.kind = kind; self.label = label; self.x = x; self.y = y; self.box = box; self.centre = centre
        self.cocoId = cocoId; self.score = score
    }
}

/// What `TrackMemory.snapshot` reports per remembered track.
public struct TrackInfo: Equatable {
    public let id: Int
    public let kind: SurfaceKind
    public let label: String
    public let cocoId: Int
    public let score: Float
    public let box: Box2?
    public let centre: Vec3?
    public let seenCount: Int
    public let firstSeenNs: Int64
    public let lastSeenNs: Int64
}

/// A remembered object or surface: `id` never changes and is never reused; `color` is ARGB, a function of `id`.
public struct Track: Equatable {
    public let id: Int
    public let kind: SurfaceKind
    public let label: String
    public let color: UInt32
}

/// Identity memory for the live object overlay (ADR 0035). It lives in app code, not in the model. A prompt with a
/// `TrackKey` keeps its track for as long as the key is remembered; a prompt without one is matched to a remembered track of
/// the same kind and label by 3D centre distance <= `maxCentreDistM` or box IoU >= `minIou`. Bounded LRU of `capacity`
/// tracks. Not thread-safe: the segmentation worker owns it. Port of the Kotlin TrackMemory (ADR 0037).
public final class TrackMemory {
    private final class Entry {
        let id: Int
        let kind: SurfaceKind
        var label: String
        var key: TrackKey?
        var box: Box2?
        var centre: Vec3?
        var cocoId = 0
        var score: Float = 0
        var seenCount = 0
        var firstSeenNs: Int64 = 0
        var lastSeenNs: Int64 = 0
        init(id: Int, kind: SurfaceKind, label: String, key: TrackKey?) { self.id = id; self.kind = kind; self.label = label; self.key = key }
    }

    private let capacity: Int
    private let minIou: Float
    private let maxCentreDistM: Float
    private var byId: [Int: Entry] = [:]
    private var order: [Int] = []          // access order: first = least recently seen
    private var byKey: [TrackKey: Entry] = [:]
    private var nextId = 1

    public init(capacity: Int = 48, minIou: Float = 0.3, maxCentreDistM: Float = 0.5) {
        precondition(capacity >= 1)
        self.capacity = capacity; self.minIou = minIou; self.maxCentreDistM = maxCentreDistM
    }

    public var size: Int { byId.count }

    private func touch(_ id: Int) {
        if let i = order.firstIndex(of: id) { order.remove(at: i) }
        order.append(id)
    }

    /// One run's prompts -> one track each, same order. A track goes to at most one prompt per run.
    @discardableResult
    public func assign(_ prompts: [SegPrompt], tNs: Int64 = 0) -> [Track] {
        var out = [Entry?](repeating: nil, count: prompts.count)
        var used = Set<Int>()
        // 1) Known keys.
        for (i, p) in prompts.enumerated() {
            guard let k = p.key, let e = byKey[k] else { continue }
            if used.contains(e.id) { continue }
            out[i] = e; used.insert(e.id)
        }
        // 2) Re-identification by 3D centre / projected box among same kind + label.
        for (i, p) in prompts.enumerated() {
            if out[i] != nil { continue }
            var best: Entry?
            var bestScore: Float = 0
            for id in order {
                let e = byId[id]!
                if used.contains(e.id) || e.kind != p.kind || e.label != p.label { continue }
                if p.key != nil && e.key != nil && e.key != p.key { continue }
                let s = matchScore(p, e)
                if s > bestScore { bestScore = s; best = e }
            }
            if let b = best {
                out[i] = b; used.insert(b.id)
                if let k = p.key, b.key == nil { b.key = k; byKey[k] = b }
            }
        }
        // 3) New tracks.
        for (i, p) in prompts.enumerated() {
            if out[i] != nil { continue }
            let e = Entry(id: nextId, kind: p.kind, label: p.label, key: p.key)
            nextId += 1
            byId[e.id] = e
            order.append(e.id)
            if let k = p.key { byKey[k] = e }
            out[i] = e; used.insert(e.id)
        }
        // Update what was seen (also refreshes the LRU order), then trim the oldest tracks not used in this run.
        for (i, p) in prompts.enumerated() {
            let e = byId[out[i]!.id]!
            touch(e.id)
            e.label = p.label
            if let b = p.box { e.box = b }
            if let c = p.centre { e.centre = c }
            if p.cocoId != 0 { e.cocoId = p.cocoId }
            e.score = p.score
            if e.seenCount == 0 { e.firstSeenNs = tNs }
            e.seenCount += 1
            e.lastSeenNs = tNs
        }
        if byId.count > capacity {
            var idx = 0
            while byId.count > capacity && idx < order.count {
                let id = order[idx]
                if used.contains(id) { idx += 1; continue }
                let e = byId[id]!
                order.remove(at: idx)
                byId.removeValue(forKey: id)
                if let k = e.key, byKey[k] === e { byKey.removeValue(forKey: k) }
            }
        }
        return out.map { e in Track(id: e!.id, kind: e!.kind, label: e!.label, color: TrackMemory.colorFor(e!.id)) }
    }

    /// > 0 when `p` may be `e`. With both 3D centres known the centre decides (the stored box is from another viewpoint and
    /// only breaks ties); otherwise the projected-box IoU decides. 0 = no match.
    private func matchScore(_ p: SegPrompt, _ e: Entry) -> Float {
        let iou: Float = (p.box != nil && e.box != nil) ? p.box!.iou(e.box!) : 0
        if let pc = p.centre, let ec = e.centre {
            let d = pc.dist(ec)
            return d <= maxCentreDistM ? 1 + (1 - d / maxCentreDistM) + iou : 0
        }
        return iou >= minIou ? iou : 0
    }

    /// Every remembered track, oldest id first.
    public func snapshot() -> [TrackInfo] {
        byId.values.sorted { $0.id < $1.id }.map {
            TrackInfo(id: $0.id, kind: $0.kind, label: $0.label, cocoId: $0.cocoId, score: $0.score, box: $0.box, centre: $0.centre,
                      seenCount: $0.seenCount, firstSeenNs: $0.firstSeenNs, lastSeenNs: $0.lastSeenNs)
        }
    }

    public func clear() { byId.removeAll(); order.removeAll(); byKey.removeAll() }

    /// 12 well-separated hues (opaque ARGB); the overlay applies its own alpha.
    private static let palette: [UInt32] = [
        0xFF42A5F5, 0xFFFFA726, 0xFF66BB6A, 0xFFEC407A, 0xFFAB47BC, 0xFF26C6DA,
        0xFFFFEE58, 0xFF8D6E63, 0xFF5C6BC0, 0xFFD4E157, 0xFFEF5350, 0xFF26A69A,
    ]

    /// Stable colour of track `id` (1-based).
    public static func colorFor(_ id: Int) -> UInt32 {
        let n = palette.count
        return palette[(((id - 1) % n) + n) % n]
    }
}
