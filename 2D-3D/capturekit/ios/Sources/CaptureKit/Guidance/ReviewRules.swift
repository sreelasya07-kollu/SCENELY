import Foundation

/// Pure rules of the review-before-finish sheet and the Review screen (ports of the Kotlin ReviewSheet and ReviewActivity helpers,
/// ADR 0037). The SampleApp only renders what these return.
public enum ReviewRules {
    /// Walls below this percentage are called weak (guess until Gate 0 data; the scanning band starts at 20).
    public static let weakPct = 50

    /// Wall numbers (core ids on a v3 core) whose coverage is below `threshold`. Only evidenced walls count: hypothesised outline
    /// sides, plane-less inferred walls and walls entirely hidden behind furniture are never called weak, so the sheet can always clear.
    public static func weakWalls(_ o: OverlayEvent?, threshold: Int = weakPct) -> [Int] {
        guard let o else { return [] }
        if !o.layoutV3 {
            return o.surfaces.enumerated().filter { $0.element.pct < threshold }.map { $0.offset + 1 }
        }
        return ScanStateSnapshot.evidencedWalls(o).filter { $0.pct < threshold }.map { $0.id }
    }

    /// Nothing of the room captured: no snapshot at all, or no floor and no wall seen.
    public static func nothingFound(_ o: OverlayEvent?) -> Bool {
        guard let o else { return true }
        return !o.floorFound && o.walls == 0 && o.surfaces.isEmpty
    }

    /// The sheet is skipped (finish straight away) only when something was captured and no wall is weak. With `guidance` off
    /// (ADR 0032) the weak-wall part is gated: only the empty-scan notice remains.
    public static func needed(_ o: OverlayEvent?, guidance: Bool) -> Bool {
        nothingFound(o) || (guidance && !weakWalls(o).isEmpty)
    }

    /// The sentence under "Complete: NN%".
    public static func gapsText(_ o: OverlayEvent?, guidance: Bool) -> String {
        if nothingFound(o) { return "Nothing of the room was captured yet." }
        let weak = guidance ? weakWalls(o) : []
        return weak.isEmpty ? "All evidenced walls meet coverage targets." : "Needs more scanning: " + weak.map { "Wall \($0)" }.joined(separator: ", ") + "."
    }

    /// manifest.json facts for the Review screen.
    public struct Manifest: Equatable {
        public let verdict: String?
        public let keyframes: Int?
        public let durationMs: Int64?
        public init(verdict: String?, keyframes: Int?, durationMs: Int64?) { self.verdict = verdict; self.keyframes = keyframes; self.durationMs = durationMs }
    }

    /// validation.verdict (PASS / WARN / FAIL), counts.keyframes and the clock span of manifest.json; all nil for a missing or corrupt file.
    public static func parseManifest(_ text: String) -> Manifest {
        guard let data = text.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Manifest(verdict: nil, keyframes: nil, durationMs: nil)
        }
        let v = (root["validation"] as? [String: Any])?["verdict"] as? String
        let verdict = (v == "PASS" || v == "WARN" || v == "FAIL") ? v : nil
        var kf: Int?
        if let n = (root["counts"] as? [String: Any])?["keyframes"] as? NSNumber, n.intValue >= 0 { kf = n.intValue }
        var dur: Int64?
        if let clock = root["clock"] as? [String: Any], let s = (clock["t_start_ns"] as? NSNumber)?.int64Value,
           let e = (clock["t_end_ns"] as? NSNumber)?.int64Value, (e - s) / 1_000_000 > 0 {
            dur = (e - s) / 1_000_000
        }
        return Manifest(verdict: verdict, keyframes: kf, durationMs: dur)
    }

    /// Contract C3 JSON -> completeness % and up to 5 weak-zone texts; nil when absent or unreadable.
    public struct SummaryView: Equatable {
        public let completenessPct: Int
        public let zones: [String]
        public init(completenessPct: Int, zones: [String]) { self.completenessPct = completenessPct; self.zones = zones }
    }

    public static func parseSummary(_ json: String?) -> SummaryView? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pct = (o["completeness_pct"] as? NSNumber)?.intValue else { return nil }
        let zones = ((o["weak_zones"] as? [Any]) ?? []).prefix(5).compactMap { ($0 as? [String: Any])?["text"] as? String }.filter { !$0.isEmpty }
        return SummaryView(completenessPct: pct, zones: Array(zones))
    }

    /// "1:05" style elapsed time.
    public static func mmss(_ ms: Int64) -> String {
        let s = max(ms, 0) / 1000
        return String(format: "%d:%02d", Int(s / 60), Int(s % 60))
    }

    /// "12.3 MB" style size.
    public static func humanSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(bytes) / 1024, i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
}
