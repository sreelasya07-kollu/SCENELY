import Foundation

/// Pure wording and date rules of the Home and My scans screens (ports of the Kotlin MainActivity.paintConsent text and
/// ScansActivity.friendlyDate day logic). The SampleApp only renders what these return.
public enum HomeText {
    public static let recoveredNote = "Your last scan ended unexpectedly. It was recovered and saved."
    public static let consentMissing = "Consent not given yet. It is needed before scanning."

    /// "Upload on  ·  Anonymous telemetry off", or the not-given sentence.
    public static func consentSummary(_ c: Consent?) -> String {
        guard let c = c else { return consentMissing }
        return "Upload \(c.upload ? "on" : "off")  ·  Anonymous telemetry \(c.telemetry ? "on" : "off")"
    }

    public enum Day: Equatable { case today, yesterday, thisYear, older }

    /// Which date wording a scan time gets, by whole calendar days before `nowMs` (device calendar, like the Android sample).
    public static func day(ms: Int64, nowMs: Int64, calendar: Calendar = .current) -> Day {
        let then = Date(timeIntervalSince1970: Double(ms) / 1000)
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: then), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return .today }
        if days == 1 { return .yesterday }
        if calendar.component(.year, from: then) == calendar.component(.year, from: now) { return .thisYear }
        return .older
    }
}
