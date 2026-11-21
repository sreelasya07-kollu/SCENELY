import Foundation

/// One wall segment in world metres (x,z plan view), the percentage of its cells seen, and the stable 1-based wall id (0 = unknown, v1 core).
public struct WallSeg: Equatable {
    public var x0: Double, z0: Double, x1: Double, z1: Double
    public var pct: Int
    public var id: Int
    public init(_ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double, _ pct: Int, _ id: Int = 0) {
        self.x0 = x0; self.z0 = z0; self.x1 = x1; self.z1 = z1; self.pct = pct; self.id = id
    }
}

/// A point in the plan view (world metres).
public struct PlanPt: Equatable {
    public var x: Double, z: Double
    public init(_ x: Double, _ z: Double) { self.x = x; self.z = z }
}

/// One stretch of a layout wall: `state` 'o' observed, 'b' blocked (hidden by furniture, never demanded), 'm' missing.
public struct SpanSeg: Equatable {
    public var id: Int
    public var x0: Double, z0: Double, x1: Double, z1: Double
    public var state: Character
    public init(_ id: Int, _ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double, _ state: Character) {
        self.id = id; self.x0 = x0; self.z0 = z0; self.x1 = x1; self.z1 = z1; self.state = state
    }
}

/// A detected object footprint: centre (x, z), w x d metres, `yawDeg` 0..89, height `h`.
public struct ObjectBox: Equatable {
    public var id: Int
    public var cls: String
    public var x: Double, z: Double, w: Double, d: Double
    public var yawDeg: Int
    public var h: Double
    public init(_ id: Int, _ cls: String, _ x: Double, _ z: Double, _ w: Double, _ d: Double, _ yawDeg: Int, _ h: Double) {
        self.id = id; self.cls = cls; self.x = x; self.z = z; self.w = w; self.d = d; self.yawDeg = yawDeg; self.h = h
    }
}

/// A door or window on a wall: footprint segment (x0,z0)-(x1,z1), heights y0..y1 above the floor. `kind` = "door" | "window".
public struct Opening: Equatable {
    public var kind: String
    public var wall: String
    public var x0: Double, z0: Double, x1: Double, z1: Double, y0: Double, y1: Double
    public init(_ kind: String, _ wall: String, _ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double, _ y0: Double, _ y1: Double) {
        self.kind = kind; self.wall = wall; self.x0 = x0; self.z0 = z0; self.x1 = x1; self.z1 = z1; self.y0 = y0; self.y1 = y1
    }
}

/// An expected-but-unseen area (centre x, z; priority 0..1).
public struct GapMark: Equatable {
    public var type: String
    public var x: Double, z: Double, pri: Double
    public init(_ type: String, _ x: Double, _ z: Double, _ pri: Double) {
        self.type = type; self.x = x; self.z = z; self.pri = pri
    }
}

/// Glanceable "what the app understands" snapshot (~2 Hz, non-critical). Wording (whyText) comes from the core.
public struct OverlayEvent: Equatable {
    public var completeness: Double = 0
    public var seen: Double = 0
    public var tracking: Int = 0
    public var mode: String = ""
    public var wallFound = false
    public var floorFound = false
    public var ceilingFound = false
    public var walls: Int = 0
    public var userX: Double = 0, userZ: Double = 0, userYawDeg: Double = 0
    public var hasTarget = false
    public var targetX: Double = 0, targetZ: Double = 0
    public var whyId: String = ""
    public var whyText: String = ""
    public var surfaces: [WallSeg] = []
    /// Overlay v2: bit i set = a keyframe looked along heading [30i, 30i+30) deg. 0 when absent.
    public var yawMask: Int = 0
    /// Overlay v3: `surfaces` are layout walls, `walls` the layout wall count; false for an older core.
    public var layoutV3 = false
    public var spans: [SpanSeg] = []
    public var shell: [PlanPt] = []
    public var shellClosed = false
    public var ceilingSeen = false
    /// Only with guide.understanding on; empty otherwise.
    public var objects: [ObjectBox] = []
    public var openings: [Opening] = []
    public var gaps: [GapMark] = []
    public var gapWhyText: String = ""
    public init() {}
}

/// Events the core emits through ck_poll_events (flat JSON lines). Parsed with regexes, no JSON decoding (port of Kotlin EventParser).
public enum CoreEvent: Equatable {
    case keyframeRequest(frameId: Int, file: String)
    case keyframeExpired(frameId: Int, file: String)
    case stateChange(from: String, to: String, reason: String)
    case frameQuality(frameId: Int, quality: Double, hardReject: Bool, reasons: [String])
    case governor(from: String, to: String, reason: String)
    /// A guidance instruction. Voice/overlay shells render it; params are in the raw line.
    case instruction(id: Int, type: String, speakText: String, longText: String, priority: Int, haptic: String, overlayHint: String)
    case overlay(OverlayEvent)
    case ingestDrop(counts: [String: Int64])
    /// Tracking degraded for 2 s; the core paused keyframe capture until `trackingReset`.
    case trackingLost(tNs: Int64, trackingState: Int, reason: Int, degradedS: Double)
    /// Tracking is back and steady: the session was re-anchored.
    case trackingReset(tNs: Int64, lostS: Double, driftM: Double, driftDeg: Double)
    case other(type: String, raw: String)
}

public enum EventParser {
    // MARK: row lists

    /// Splits "a,b,...;..." rows; rows with another field count are skipped; `build` returns nil to skip a malformed row.
    private static func rows<T>(_ s: String, fields: Int, _ build: ([String]) -> T?) -> [T] {
        if s.isEmpty { return [] }
        var out: [T] = []
        for part in s.split(separator: ";", omittingEmptySubsequences: false) {
            let f = part.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if f.count != fields { continue }
            if let v = build(f) { out.append(v) }
        }
        return out
    }

    /// Double -> Int with truncation toward zero; non-finite or out-of-range values clamp instead of trapping.
    static func toInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= 9.2e18 { return Int.max }
        if d <= -9.2e18 { return Int.min }
        return Int(d)
    }

    /// v3 "id,x0,z0,x1,z1,state;..." (state o|b|m).
    public static func parseSpans(_ s: String) -> [SpanSeg] {
        rows(s, fields: 6) { f in
            var v: [Double] = []
            for i in 0..<5 { guard let d = Double(f[i]) else { return nil }; v.append(d) }
            guard let st = f[5].first, st == "o" || st == "b" || st == "m" else { return nil }
            return SpanSeg(toInt(v[0]), v[1], v[2], v[3], v[4], st)
        }
    }

    /// v3 "x,z;..." outline corners.
    public static func parseShell(_ s: String) -> [PlanPt] {
        rows(s, fields: 2) { f in
            guard let x = Double(f[0]), let z = Double(f[1]) else { return nil }
            return PlanPt(x, z)
        }
    }

    private static func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    /// Inverse of the parsers above, for the Review hand-over.
    public static func encodeShell(_ l: [PlanPt]) -> String { l.map { "\(f3($0.x)),\(f3($0.z))" }.joined(separator: ";") }
    public static func encodeSpans(_ l: [SpanSeg]) -> String {
        l.map { "\($0.id),\(f3($0.x0)),\(f3($0.z0)),\(f3($0.x1)),\(f3($0.z1)),\($0.state)" }.joined(separator: ";")
    }
    public static func encodeObjects(_ l: [ObjectBox]) -> String {
        l.map { "\($0.id),\($0.cls),\(f3($0.x)),\(f3($0.z)),\(f3($0.w)),\(f3($0.d)),\($0.yawDeg),\(f3($0.h))" }.joined(separator: ";")
    }
    public static func encodeOpenings(_ l: [Opening]) -> String {
        l.map { "\($0.kind),\($0.wall),\(f3($0.x0)),\(f3($0.z0)),\(f3($0.x1)),\(f3($0.z1)),\(f3($0.y0)),\(f3($0.y1))" }.joined(separator: ";")
    }

    /// "id,cls,x,z,w,d,yaw_deg,h;...".
    public static func parseObjects(_ s: String) -> [ObjectBox] {
        rows(s, fields: 8) { f in
            var n: [Double] = []
            for i in [0, 2, 3, 4, 5, 6, 7] { guard let d = Double(f[i]) else { return nil }; n.append(d) }
            return ObjectBox(toInt(n[0]), f[1], n[1], n[2], n[3], n[4], toInt(n[5]), n[6])
        }
    }

    /// "kind,wall,x0,z0,x1,z1,y0,y1;...".
    public static func parseOpenings(_ s: String) -> [Opening] {
        rows(s, fields: 8) { f in
            var n: [Double] = []
            for i in 2...7 { guard let d = Double(f[i]) else { return nil }; n.append(d) }
            return Opening(f[0], f[1], n[0], n[1], n[2], n[3], n[4], n[5])
        }
    }

    /// "type,x,z,pri;...".
    public static func parseGaps(_ s: String) -> [GapMark] {
        rows(s, fields: 4) { f in
            guard let x = Double(f[1]), let z = Double(f[2]), let p = Double(f[3]) else { return nil }
            return GapMark(f[0], x, z, p)
        }
    }

    /// "x0,z0,x1,z1,pct[,id];..." (5 fields v1, 6 fields v2) -> segments; malformed entries are skipped.
    public static func parseSurfaces(_ s: String) -> [WallSeg] {
        var out: [WallSeg] = []
        for part in s.split(separator: ";", omittingEmptySubsequences: false) {
            let f = part.split(separator: ",", omittingEmptySubsequences: false)
            if f.count != 5 && f.count != 6 { continue }
            var v: [Double] = []
            var ok = true
            for x in f {
                if let d = Double(x.trimmingCharacters(in: .whitespacesAndNewlines)) { v.append(d) } else { ok = false; break }
            }
            if !ok { continue }
            out.append(WallSeg(v[0], v[1], v[2], v[3], toInt(v[4]), f.count == 6 ? max(0, toInt(v[5])) : 0))
        }
        return out
    }

    // MARK: scalar fields

    private static let cacheLock = NSLock()
    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let r = cache[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern) else { return nil }
        cache[pattern] = r
        return r
    }

    private static func firstGroup(_ pattern: String, _ line: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func str(_ line: String, _ key: String) -> String? {
        firstGroup("\"" + NSRegularExpression.escapedPattern(for: key) + #"":"((?:[^"\\]|\\.)*)""#, line)
    }

    private static func num(_ line: String, _ key: String) -> Double? {
        firstGroup("\"" + NSRegularExpression.escapedPattern(for: key) + #"":(-?[0-9.eE+-]+)"#, line).flatMap { Double($0) }
    }

    /// Integer field without a round trip through Double (t_ns needs all 64 bits).
    private static func long(_ line: String, _ key: String) -> Int64? {
        firstGroup("\"" + NSRegularExpression.escapedPattern(for: key) + #"":(-?[0-9]+)(?![0-9.eE])"#, line).flatMap { Int64($0) }
    }

    // MARK: lines

    public static func parseLine(_ line: String) -> CoreEvent? {
        guard let type = str(line, "type") else { return nil }
        switch type {
        case "keyframe_request":
            guard let id = num(line, "frame_id"), let file = str(line, "file") else { return nil }
            return .keyframeRequest(frameId: toInt(id), file: file)
        case "keyframe_expired":
            guard let id = num(line, "frame_id") else { return nil }
            return .keyframeExpired(frameId: toInt(id), file: str(line, "file") ?? "")
        case "state":
            return .stateChange(from: str(line, "from") ?? "", to: str(line, "to") ?? "", reason: str(line, "reason") ?? "")
        case "governor":
            return .governor(from: str(line, "from") ?? "", to: str(line, "to") ?? "", reason: str(line, "reason") ?? "")
        case "frame_quality":
            guard let id = num(line, "frame_id") else { return nil }
            var reasons: [String] = []
            if let g = firstGroup(#""reasons":\[([^\]]*)\]"#, line) {
                reasons = g.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    .filter { !$0.isEmpty }
            }
            return .frameQuality(frameId: toInt(id), quality: num(line, "quality") ?? 0.0,
                                 hardReject: line.contains("\"hard_reject\":true"), reasons: reasons)
        case "instruction":
            guard let id = num(line, "id") else { return nil }
            return .instruction(id: toInt(id), type: str(line, "instruction") ?? "", speakText: str(line, "speak_text") ?? "",
                                longText: str(line, "long_text") ?? "", priority: toInt(num(line, "priority") ?? 2.0),
                                haptic: str(line, "haptic") ?? "none", overlayHint: str(line, "overlay_hint") ?? "")
        case "overlay":
            var o = OverlayEvent()
            o.completeness = num(line, "completeness") ?? 0.0
            o.seen = num(line, "seen") ?? 0.0
            o.tracking = toInt(num(line, "tracking") ?? 0.0)
            o.mode = str(line, "mode") ?? ""
            o.wallFound = line.contains("\"wall_found\":true")
            o.floorFound = line.contains("\"floor_found\":true")
            o.ceilingFound = line.contains("\"ceiling_found\":true")
            o.walls = toInt(num(line, "walls") ?? 0.0)
            o.userX = num(line, "user_x") ?? 0.0
            o.userZ = num(line, "user_z") ?? 0.0
            o.userYawDeg = num(line, "user_yaw_deg") ?? 0.0
            o.hasTarget = line.contains("\"has_target\":true")
            o.targetX = num(line, "target_x") ?? 0.0
            o.targetZ = num(line, "target_z") ?? 0.0
            o.whyId = str(line, "why_id") ?? ""
            o.whyText = str(line, "why_text") ?? ""
            o.surfaces = parseSurfaces(str(line, "surfaces") ?? "")
            o.yawMask = toInt(num(line, "yaw_mask") ?? 0.0) & 0xFFF
            o.layoutV3 = line.contains("\"shell_closed\":")
            o.spans = parseSpans(str(line, "spans") ?? "")
            o.shell = parseShell(str(line, "shell") ?? "")
            o.shellClosed = line.contains("\"shell_closed\":true")
            o.ceilingSeen = line.contains("\"ceiling_seen\":true")
            o.objects = parseObjects(str(line, "objects") ?? "")
            o.openings = parseOpenings(str(line, "openings") ?? "")
            o.gaps = parseGaps(str(line, "gaps") ?? "")
            o.gapWhyText = str(line, "gap_why_text") ?? ""
            return .overlay(o)
        case "tracking_lost":
            guard let t = long(line, "t_ns") else { return nil }
            return .trackingLost(tNs: t, trackingState: toInt(num(line, "tracking_state") ?? 0.0),
                                 reason: toInt(num(line, "reason") ?? 0.0), degradedS: num(line, "degraded_s") ?? 0.0)
        case "tracking_reset":
            guard let t = long(line, "t_ns") else { return nil }
            return .trackingReset(tNs: t, lostS: num(line, "lost_s") ?? 0.0, driftM: num(line, "drift_m") ?? 0.0,
                                  driftDeg: num(line, "drift_deg") ?? 0.0)
        case "ingest_drop":
            var counts: [String: Int64] = [:]
            for k in ["pose", "gyro", "accel", "intrinsics", "frame", "points", "plane", "platform"] {
                if let v = num(line, k) { counts[k] = Int64(exactly: v.rounded(.towardZero)) ?? 0 }
            }
            return .ingestDrop(counts: counts)
        default:
            return .other(type: type, raw: line)
        }
    }

    public static func parse(_ text: String) -> [CoreEvent] {
        var out: [CoreEvent] = []
        text.enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            if let e = parseLine(line) { out.append(e) }
        }
        return out
    }
}

/// Decoded ck_policy.
public struct Policy: Equatable {
    public let level: Int
    public let keyframeRateScale: Double
    public let mlRateScale: Double
    public let resolutionTier: Int
    public let overlay: Bool
    public let upload: Bool
    public let mustPause: Bool

    public static let levels = ["NOMINAL", "REDUCE_KEYFRAMES", "REDUCE_ML", "LOWER_RESOLUTION", "WARN", "SAFE_PAUSE"]

    public init(level: Int, keyframeRateScale: Double, mlRateScale: Double, resolutionTier: Int, overlay: Bool, upload: Bool, mustPause: Bool) {
        self.level = level; self.keyframeRateScale = keyframeRateScale; self.mlRateScale = mlRateScale
        self.resolutionTier = resolutionTier; self.overlay = overlay; self.upload = upload; self.mustPause = mustPause
    }

    /// `a` holds 7 doubles in the ck_policy order.
    public static func from(_ a: [Double]) -> Policy {
        Policy(level: EventParser.toInt(a[0]), keyframeRateScale: a[1], mlRateScale: a[2], resolutionTier: EventParser.toInt(a[3]),
               overlay: a[4] != 0.0, upload: a[5] != 0.0, mustPause: a[6] != 0.0)
    }

    public var levelName: String { (0..<Policy.levels.count).contains(level) ? Policy.levels[level] : "?" }
}
