import Foundation

/// Scan completeness and weak zones (ADR 0035/0036), pure. Inputs: the core overlay (room coverage, wall spans, gaps; gaps need
/// guide understanding 2) and the live object tracks.
///
/// completeness_pct = round(100 * (0.8 * overlay.completeness + 0.2 * confirmed / max(1, tracks))), or the overlay only when there
/// are no tracks. A track is confirmed after `confirmSightings` or more segmentation sightings (guess).
/// Weak zones = overlay spans in state 'm' (per wall id), overlay gaps (by type) and unconfirmed tracks ("Look at the chair again").
/// The ReviewSummary JSON (contract C3) is handed to the review screen in memory; it is never recorded in the bundle.
/// Port of the Kotlin Completeness (ADR 0037).
public enum Completeness {
    public static let confirmSightings = 3
    public static let maxZones = 8
    /// Name of the hand-over key on Android (kept for parity in logs and docs).
    public static let extra = "ck.review_summary"

    public struct ObjectEntry: Equatable {
        public let trackId: Int
        public let label: String
        public let seenCount: Int
        public let confirmed: Bool
        public init(trackId: Int, label: String, seenCount: Int, confirmed: Bool) {
            self.trackId = trackId; self.label = label; self.seenCount = seenCount; self.confirmed = confirmed
        }
    }

    /// `kind` = "wall_span" | "gap" | "object"; `x`, `z` in metres (nil = unknown); `pri` 0..1 (1 = look here first).
    public struct WeakZone: Equatable {
        public let kind: String
        public let wallId: Int?
        public let x: Double?
        public let z: Double?
        public let text: String
        public let pri: Double
        public init(kind: String, wallId: Int?, x: Double?, z: Double?, text: String, pri: Double) {
            self.kind = kind; self.wallId = wallId; self.x = x; self.z = z; self.text = text; self.pri = pri
        }
    }

    public struct Summary: Equatable {
        public let completenessPct: Int
        public let roomPct: Int
        public let objects: [ObjectEntry]
        public let weakZones: [WeakZone]
        public init(completenessPct: Int, roomPct: Int, objects: [ObjectEntry], weakZones: [WeakZone]) {
            self.completenessPct = completenessPct; self.roomPct = roomPct; self.objects = objects; self.weakZones = weakZones
        }
    }

    /// Kotlin `Math.round`: half up.
    private static func round(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    public static func pct(room: Double, confirmed: Int, tracks: Int) -> Int {
        let r = room.isFinite ? min(max(room, 0), 1) : 0
        let v = tracks <= 0 ? r : 0.8 * r + 0.2 * Double(confirmed) / Double(max(1, tracks))
        return min(max(Int(round(100.0 * v)), 0), 100)
    }

    public static func compute(_ o: OverlayEvent?, live: [LiveObject]) -> Summary {
        let objects = live.map { ObjectEntry(trackId: $0.trackId, label: $0.label, seenCount: $0.seenCount, confirmed: $0.seenCount >= confirmSightings) }
        let room = o?.completeness ?? 0.0
        var zones: [WeakZone] = []
        if let o = o {
            // Missing wall stretches, one zone per wall: centre of the missing spans, priority by how much of the wall is missing.
            var ids: [Int] = []
            var byId: [Int: [SpanSeg]] = [:]
            for s in o.spans {
                if byId[s.id] == nil { ids.append(s.id); byId[s.id] = [] }
                byId[s.id]!.append(s)
            }
            for id in ids {
                let spans = byId[id]!
                let missing = spans.filter { $0.state == "m" }
                if missing.isEmpty { continue }
                func len(_ s: SpanSeg) -> Double { hypot(s.x1 - s.x0, s.z1 - s.z0) }
                let totalRaw = spans.reduce(0.0) { $0 + len($1) }
                let total = totalRaw > 0 ? totalRaw : 1.0
                let frac = min(max(missing.reduce(0.0) { $0 + len($1) } / total, 0), 1)
                let mx = missing.map { ($0.x0 + $0.x1) / 2 }.reduce(0, +) / Double(missing.count)
                let mz = missing.map { ($0.z0 + $0.z1) / 2 }.reduce(0, +) / Double(missing.count)
                zones.append(WeakZone(kind: "wall_span", wallId: id > 0 ? id : nil, x: mx, z: mz,
                                      text: id > 0 ? "Scan wall \(id) again" : "Scan the missing part of the wall", pri: 0.6 + 0.4 * frac))
            }
            for g in o.gaps {
                zones.append(WeakZone(kind: "gap", wallId: nil, x: g.x, z: g.z,
                                      text: "Look at the unseen area (\(g.type.replacingOccurrences(of: "_", with: " ")))", pri: min(max(g.pri, 0), 1)))
            }
        }
        for t in live where t.seenCount < confirmSightings {
            zones.append(WeakZone(kind: "object", wallId: nil, x: t.centreWorld.map { Double($0.x) }, z: t.centreWorld.map { Double($0.z) },
                                  text: "Look at the \(LabelMap.displayName(t.label)) again", pri: 0.5))
        }
        // Stable sort: priority descending, then text.
        let sorted = zones.enumerated().sorted { a, b in
            if a.element.pri != b.element.pri { return a.element.pri > b.element.pri }
            if a.element.text != b.element.text { return a.element.text < b.element.text }
            return a.offset < b.offset
        }.map { $0.element }
        let confirmed = objects.filter { $0.confirmed }.count
        return Summary(completenessPct: pct(room: room, confirmed: confirmed, tracks: live.count), roomPct: pct(room: room, confirmed: 0, tracks: 0),
                       objects: objects, weakZones: Array(sorted.prefix(maxZones)))
    }

    private static func esc(_ s: String) -> String { SessionConfigJSON.quote(s).dropFirst().dropLast().description }

    private static func num(_ d: Double?) -> String {
        guard let d = d, d.isFinite else { return "null" }
        return "\(round(d * 100.0) / 100.0)"
    }

    /// Contract C3 JSON.
    public static func toJSON(_ s: Summary) -> String {
        var out = "{\"completeness_pct\":\(s.completenessPct),\"room_pct\":\(s.roomPct),\"objects\":["
        out += s.objects.map {
            "{\"track_id\":\($0.trackId),\"label\":\"\(esc($0.label))\",\"seen_count\":\($0.seenCount),\"confirmed\":\($0.confirmed)}"
        }.joined(separator: ",")
        out += "],\"weak_zones\":["
        out += s.weakZones.map {
            "{\"kind\":\"\($0.kind)\",\"wall_id\":\($0.wallId.map(String.init) ?? "null"),\"x\":\(num($0.x)),\"z\":\(num($0.z)),\"text\":\"\(esc($0.text))\",\"pri\":\(num($0.pri))}"
        }.joined(separator: ",")
        out += "]}"
        return out
    }
}
