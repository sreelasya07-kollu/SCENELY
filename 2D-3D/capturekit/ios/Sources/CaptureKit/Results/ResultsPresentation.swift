import Foundation

/// Plain-language text of the Results screen (pure, port of the string logic in S/ResultsActivity.kt). The verdict itself always comes
/// from the server; nothing is computed or invented here.
public enum ResultsText {
    public enum Tone { case ok, warn, error, info, muted }

    public static func headline(_ job: JobStatus) -> (text: String, tone: Tone) {
        if job.state == "failed" { return ("Processing failed" + (job.error.map { ": \($0)" } ?? "."), .error) }
        if job.state == "rejected" { return ("The server could not use this scan" + (job.error.map { ": \($0)" } ?? "."), .error) }
        switch job.verdict {
        case "pass"?: return ("The scan looks good.", .ok)
        case "pass_with_warnings"?: return ("The scan is usable, with some notes.", .warn)
        case "needs_rescan"?: return ("Part of the room needs another scan.", .error)
        default: break
        }
        if job.isActive { return (job.state == "queued" ? "Waiting for the server to start." : "Processing your scan...", .info) }
        return ("No verdict yet.", .info)
    }

    /// "Server check notes: ..." for ERROR/WARN issues, nil when there are none.
    public static func validationNotes(_ job: JobStatus) -> String? {
        let issues = (job.validation?.issues ?? []).filter { $0.severity == "ERROR" || $0.severity == "WARN" }
        if issues.isEmpty { return nil }
        return "Server check notes: " + issues.map { $0.message.isEmpty ? $0.code : $0.message }.joined(separator: "; ")
    }

    public static func stageTitle(_ name: String) -> String {
        switch name {
        case "validate": return "Scan check"
        case "spatial": return "Camera poses"
        case "recon": return "Reconstruction"
        case "export": return "Floor plan and exports"
        case "qa": return "Quality report"
        case "splat": return "3D splat"
        case "splat_eval": return "Splat quality"
        default: return name
        }
    }

    public static func stageLabel(_ status: String) -> (text: String, tone: Tone) {
        switch status {
        case "ok": return ("Done", .ok)
        case "running": return ("Running", .warn)
        case "failed": return ("Failed", .error)
        case "skipped": return ("Skipped", .muted)
        default: return ("Waiting", .muted)
        }
    }

    /// Reason (when the stage is not done) and a hint for stages that run on the GPU computer.
    public static func stageSubtitle(_ s: JobStatus.Stage) -> String? {
        var parts: [String] = []
        if let r = s.reason, !r.trimmingCharacters(in: .whitespaces).isEmpty, s.status != "ok" { parts.append(r) }
        if s.where_ == "gpu_worker" && s.status == "pending" { parts.append("Runs on the GPU computer") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Present measurements only, in the Android order.
    public static func measurementRows(_ job: JobStatus) -> [(label: String, value: String)] {
        guard let m = job.measurements else { return [] }
        var rows: [(label: String, value: String)] = []
        if let v = m.floorAreaM2 { rows.append((label: "Floor area", value: String(format: "%.2f m²", v))) }
        if let v = m.perimeterM { rows.append((label: "Perimeter", value: String(format: "%.2f m", v))) }
        if let v = m.ceilingHeightM { rows.append((label: "Ceiling height", value: String(format: "%.2f m", v))) }
        if let v = m.volumeM3 { rows.append((label: "Volume", value: String(format: "%.1f m³", v))) }
        if let v = m.scaleConfidence { rows.append((label: "Scale confidence", value: String(format: "%.0f %%", v * 100))) }
        return rows
    }

    /// Wraps the server's floor plan SVG for WKWebView.loadHTMLString: drops any XML/DOCTYPE prolog so the SVG sits inline in HTML,
    /// white page, scaled to the width. Scripts are not run (the web view disables JavaScript).
    public static func floorPlanHTML(svg: String) -> String {
        var s = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("<?") || s.hasPrefix("<!") {
            guard let end = s.firstIndex(of: ">") else { break }
            s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#fff}svg{width:100%;height:100%}</style></head><body>\(s)</body></html>
        """
    }
}

extension JobStatus {
    /// Highest priority first (stable for equal priority).
    public var rescanByPriority: [Rescan] {
        let indexed = Array(rescan.enumerated())
        let sorted = indexed.sorted { (a, b) -> Bool in
            if a.element.priority != b.element.priority { return a.element.priority > b.element.priority }
            return a.offset < b.offset
        }
        return sorted.map { $0.element }
    }
}
