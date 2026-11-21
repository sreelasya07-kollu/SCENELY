import Foundation

/// Answer of one fetch: the body text, or a plain-language error (exactly one of them is set).
public struct Fetched: Equatable {
    public let text: String?
    public let error: String?
    public init(_ text: String?, _ error: String?) { self.text = text; self.error = error }
}

/// Where the roomscan-recon job server is, and which URLs are allowed. Pure (no network): port of the field ResultsGate.kt
/// (available, absoluteUrl, segment encoding). An empty or missing base URL = results unavailable, like the Android standard flavour.
public struct ResultsGate: Equatable {
    public let base: String?

    /// `jobsURL` is the CK_JOBS_URL value; blank, whitespace or an unsubstituted "$(...)" means unavailable.
    public init(jobsURL: String?) {
        let t = jobsURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var b = t
        while b.hasSuffix("/") { b.removeLast() }
        base = (b.isEmpty || b.hasPrefix("$(")) ? nil : b
    }

    public init(jobsURL: URL?) { self.init(jobsURL: jobsURL?.absoluteString) }

    public var available: Bool { base != nil }

    /// Absolute URL for a server-relative path such as "/jobs/<id>/files/x"; an absolute URL passes only when it is on this server.
    public func absoluteUrl(_ rel: String) -> String? {
        guard let base else { return nil }
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return rel.hasPrefix(base + "/") ? rel : nil }
        return base + (rel.hasPrefix("/") ? rel : "/" + rel)
    }

    /// Percent-encodes one path segment like Java's URLEncoder (letters, digits and ".-*_" stay; space becomes %20).
    public static func segment(_ id: String) -> String {
        let keep = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_")
        return id.addingPercentEncoding(withAllowedCharacters: keep) ?? id
    }

    public func jobUrl(_ bundleId: String) -> String? { base.map { "\($0)/jobs/\(Self.segment(bundleId))" } }
    public var jobsCollectionUrl: String? { base.map { "\($0)/jobs" } }

    /// JSON body of POST /jobs.
    public static func startBody(_ bundleId: String) -> Data {
        let esc = bundleId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return Data(#"{"bundle_id":"\#(esc)"}"#.utf8)
    }

    public static let notSetUp = "The results server is not set up in this build."
    public static let unknownScan = "The server does not know this scan yet. Upload it first."
    public static let unreachable = "Could not reach the results server."
    public static let notOnServer = "That file is not on the results server."
}
