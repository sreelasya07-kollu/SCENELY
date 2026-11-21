import Foundation

/// One wall as the user knows it: "Wall N" (N = stable overlay wall id) and % seen.
public struct WallState: Equatable {
    public let id: Int
    public let pct: Int
    public init(id: Int, pct: Int) { self.id = id; self.pct = pct }
    public var name: String { "Wall \(id)" }
}

/// What the app currently knows about the scan, as plain data: the only input of `StateAnswers`.
/// No image, pixel, path, position or timestamp is carried. Port of the Kotlin ScanStateSnapshot.
public struct ScanStateSnapshot: Equatable {
    public var completeness: Double
    /// Overlay `tracking`: 1 normal, 2 limited, 3 not available.
    public var tracking: Int
    public var wallFound: Bool
    public var floorFound: Bool
    public var ceilingFound: Bool
    public var walls: [WallState]
    /// Number of 30-degree heading sectors (of 12) a keyframe has looked along.
    public var headingSectors: Int
    public var labels: [String]
    /// Named areas still missing, already worded by the producer. Cited as is.
    public var gaps: [String]
    public var wallCount: Int

    public init(completeness: Double, tracking: Int, wallFound: Bool, floorFound: Bool, ceilingFound: Bool, walls: [WallState],
                headingSectors: Int, labels: [String] = [], gaps: [String] = [], wallCount: Int? = nil) {
        self.completeness = completeness; self.tracking = tracking; self.wallFound = wallFound
        self.floorFound = floorFound; self.ceilingFound = ceilingFound; self.walls = walls
        self.headingSectors = headingSectors; self.labels = labels; self.gaps = gaps
        self.wallCount = wallCount ?? walls.count
    }

    /// False until the core has reported anything about the room: answers must abstain.
    public var hasScanData: Bool {
        wallFound || floorFound || ceilingFound || !walls.isEmpty || headingSectors > 0 || completeness > 0.0
    }

    /// Every region name an answer may cite.
    public var regions: Set<String> {
        var s = Set(walls.map { $0.name })
        if floorFound { s.insert(ScanStateSnapshot.floor) }
        if ceilingFound { s.insert(ScanStateSnapshot.ceiling) }
        s.formUnion(gaps)
        return s
    }

    public static let floor = "Floor"
    public static let ceiling = "Ceiling"

    /// Sorted-key flat JSON for the dialog-proxy request ("state" object).
    public func toJSON() -> String {
        var s = "{"
        s += "\"ceiling_found\":\(ceilingFound)"
        s += ",\"completeness\":\(ScanStateSnapshot.round2(completeness))"
        s += ",\"floor_found\":\(floorFound)"
        s += ",\"gaps\":\(ScanStateSnapshot.strings(gaps))"
        s += ",\"heading_sectors\":\(headingSectors)"
        s += ",\"labels\":\(ScanStateSnapshot.strings(labels))"
        s += ",\"tracking\":\(tracking)"
        s += ",\"wall_found\":\(wallFound)"
        s += ",\"walls\":["
        s += walls.map { "{\"id\":\($0.id),\"pct\":\($0.pct)}" }.joined(separator: ",")
        s += "]}"
        return s
    }

    /// Walls the user can still be asked about. A v3 core (layout walls): only walls with a real id (> 0) whose spans are
    /// not ALL blocked by furniture. An older core: every surface, as before.
    public static func evidencedWalls(_ o: OverlayEvent) -> [WallSeg] {
        o.layoutV3 ? o.surfaces.filter { $0.id > 0 && !allSpansBlocked(o, $0.id) } : o.surfaces
    }

    private static func allSpansBlocked(_ o: OverlayEvent, _ id: Int) -> Bool {
        var n = 0
        for s in o.spans where s.id == id {
            n += 1
            if s.state != "b" { return false }
        }
        return n > 0
    }

    public static func fromOverlay(_ o: OverlayEvent, labels: [String] = [], gaps: [String] = []) -> ScanStateSnapshot {
        // v3: names come straight from the core ids. v1 core: walls without an id get ids after the largest real id.
        var nextId = max(o.surfaces.map { $0.id }.max() ?? 0, 0)
        let walls: [WallState]
        if o.layoutV3 {
            walls = evidencedWalls(o).map { WallState(id: $0.id, pct: min(max($0.pct, 0), 100)) }
        } else {
            walls = o.surfaces.map { s in
                var id = s.id
                if id <= 0 { nextId += 1; id = nextId }
                return WallState(id: id, pct: min(max(s.pct, 0), 100))
            }
        }
        return ScanStateSnapshot(
            completeness: finite01(o.completeness), tracking: o.tracking, wallFound: o.wallFound, floorFound: o.floorFound,
            ceilingFound: o.ceilingFound || o.ceilingSeen, walls: walls,
            headingSectors: (o.yawMask & 0xFFF).nonzeroBitCount, labels: labels, gaps: gaps,
            wallCount: o.layoutV3 ? o.walls : walls.count)
    }

    /// NaN and infinities become 0.0.
    private static func finite01(_ d: Double) -> Double { d.isFinite ? min(max(d, 0), 1) : 0.0 }

    /// Kotlin `Double.toString()` of a value rounded to 2 decimals (0.0, 0.35, 1.0).
    private static func round2(_ d: Double) -> String {
        let v = (finite01(d) * 100.0).rounded(.toNearestOrAwayFromZero) / 100.0
        if v == v.rounded() { return String(format: "%.1f", v) }
        return "\(v)"
    }

    private static func strings(_ l: [String]) -> String { "[" + l.map { "\"" + escape($0) + "\"" }.joined(separator: ",") + "]" }

    private static func escape(_ s: String) -> String { SessionConfigJSON.quote(s).dropFirst().dropLast().description }
}
