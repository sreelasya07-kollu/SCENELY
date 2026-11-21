import Foundation

/// Small regex helper shared by the pure parsers (no caching: these run on user actions, not per frame).
enum Rx {
    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

/// Plain-language text for the validator's verdict and issue codes, from the bundled verdict_messages.json
/// ({"headlines":{FAIL,WARN,PASS},"codes":{CODE:{severity,level,title,text,action,next}}}). Unknown codes get a generic entry.
/// Port of the Kotlin VerdictText (ADR 0037); uses JSONSerialization instead of the hand-written reader.
public struct VerdictText {
    public struct Entry: Equatable {
        public let severity: String, level: String, title: String, text: String, action: String, next: String
        public init(severity: String, level: String, title: String, text: String, action: String, next: String) {
            self.severity = severity; self.level = level; self.title = title; self.text = text; self.action = action; self.next = next
        }
    }

    public struct Issue: Equatable {
        public let code: String, severity: String, message: String
        public init(_ code: String, _ severity: String, _ message: String) { self.code = code; self.severity = severity; self.message = message }
    }

    public let headlines: [String: String]
    public let codes: [String: Entry]

    public init(headlines: [String: String], codes: [String: Entry]) { self.headlines = headlines; self.codes = codes }

    public func headline(_ verdict: String?) -> String {
        (verdict.flatMap { headlines[$0] }) ?? headlines["WARN"] ?? "The scan check is not available."
    }

    public func entry(_ issue: Issue) -> Entry {
        codes[issue.code] ?? Entry(
            severity: issue.severity, level: "semantic", title: "Scan note",
            text: issue.message.isEmpty ? "The check reported a note about this scan." : issue.message,
            action: issue.severity == "ERROR" ? "Scan the room again." : "Nothing needed.",
            next: issue.severity == "ERROR" ? "rescan" : "proceed_with_note")
    }

    /// WARN/ERROR issues only, one entry per code, errors first (stable otherwise).
    public func describe(_ issues: [Issue]) -> [Entry] {
        var seen = Set<String>()
        let kept = issues.filter { ($0.severity == "ERROR" || $0.severity == "WARN") && seen.insert($0.code).inserted }
        let errors = kept.filter { $0.severity == "ERROR" }
        let rest = kept.filter { $0.severity != "ERROR" }
        return (errors + rest).map { entry($0) }
    }

    /// "rescan" if any entry says so or the verdict is FAIL, else "proceed_with_note" if any note, else "none".
    public func nextStep(_ verdict: String?, _ issues: [Issue]) -> String {
        let e = describe(issues)
        if verdict == "FAIL" || e.contains(where: { $0.next == "rescan" }) { return "rescan" }
        if e.contains(where: { $0.next == "proceed_with_note" }) || verdict == "WARN" { return "proceed_with_note" }
        return "none"
    }

    public static let fallback = VerdictText(
        headlines: ["FAIL": "This scan cannot be used. Please scan the room again.", "WARN": "Scan saved with notes.", "PASS": "Scan looks good."],
        codes: [:])

    /// Never throws: a damaged asset yields `fallback`.
    public static func parse(_ json: String) -> VerdictText {
        guard let data = json.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fallback }
        var heads: [String: String] = [:]
        for (k, v) in (root["headlines"] as? [String: Any]) ?? [:] { if let s = v as? String { heads[k] = s } }
        var codes: [String: Entry] = [:]
        for (k, v) in (root["codes"] as? [String: Any]) ?? [:] {
            guard let m = v as? [String: Any] else { continue }
            func s(_ n: String) -> String { (m[n] as? String) ?? "" }
            codes[k] = Entry(severity: s("severity"), level: s("level"), title: s("title"), text: s("text"), action: s("action"), next: s("next"))
        }
        if heads.isEmpty && codes.isEmpty { return fallback }
        return VerdictText(headlines: fallback.headlines.merging(heads) { _, new in new }, codes: codes)
    }

    /// Issues of manifest.json validation.issues ({"code","severity","message"} objects).
    public static func issuesOf(_ manifestJson: String) -> [Issue] {
        guard let data = manifestJson.data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = (root["validation"] as? [String: Any])?["issues"] as? [Any] else { return [] }
        return list.compactMap { o in
            guard let m = o as? [String: Any] else { return nil }
            return Issue((m["code"] as? String) ?? "", (m["severity"] as? String) ?? "", (m["message"] as? String) ?? "")
        }
    }
}

/// Pure helpers for the "My scans" list: when a bundle was recorded, its optional room label, its badge text.
public enum ScanInfo {
    /// Bundle folders are named scan_yyyyMMdd_HHmmss (device local time); falls back to `lastModified` (epoch ms).
    public static func timeMs(dirName: String, lastModified: Int64) -> Int64 {
        guard let stamp = Rx.firstGroup(#"^scan_(\d{8}_\d{6})$"#, in: dirName) else { return lastModified }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.isLenient = false
        guard let d = f.date(from: stamp) else { return lastModified }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    /// "room" of the field research file beside the bundle (JSON string), blank -> nil.
    public static func roomLabel(_ researchJson: String?) -> String? {
        guard let j = researchJson, let raw = Rx.firstGroup(#""room"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: j) else { return nil }
        let s = raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Badge wording: colour comes from the verdict, words always accompany it.
    public static func badgeText(_ verdict: String?) -> String {
        switch verdict {
        case "PASS"?: return "Passed"
        case "WARN"?: return "Usable, with notes"
        case "FAIL"?: return "Failed"
        default: return "Not checked"
        }
    }
}
