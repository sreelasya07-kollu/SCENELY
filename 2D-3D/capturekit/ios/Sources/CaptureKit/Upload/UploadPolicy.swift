import Foundation

/// What the user sees for one bundle's upload. `none` = never queued (or not allowed).
public enum UploadState { case none, waiting, uploading, retrying, verified, failed }

public struct UploadStatus: Equatable {
    public let state: UploadState
    public let percent: Int
    public let error: String?
    public init(state: UploadState, percent: Int = -1, error: String? = nil) { self.state = state; self.percent = percent; self.error = error }
}

/// Pure upload gate: consent now AND a usable verdict. Checked at enqueue and again on every upload run (port of the Kotlin UploadPolicy).
/// The Android WorkManager state mapping has no iOS counterpart (uploads run in `TusUploader`, not a job scheduler).
public enum UploadPolicy {
    public enum Decision { case run, noConsent, verdictFail, noVerdict }

    /// Upload needs consent now and a PASS or WARN verdict; nil/unparseable (not finalized) is not eligible. `consentNow` must come
    /// from ConsentStore at the moment of the call, so a revoke stops queued work.
    public static func decide(consentNow: Bool, verdict: String?) -> Decision {
        if !consentNow { return .noConsent }
        if verdict == "FAIL" { return .verdictFail }
        if verdict != "PASS" && verdict != "WARN" { return .noVerdict }   // no finalized manifest: nothing trustworthy to upload
        return .run
    }

    public static func eligible(consentNow: Bool, verdict: String?) -> Bool { decide(consentNow: consentNow, verdict: verdict) == .run }

    /// validation.verdict of manifest.json text, or nil when absent/unreadable.
    public static func verdictOf(_ manifestJson: String) -> String? {
        Rx.firstGroup(#""verdict"\s*:\s*"(PASS|WARN|FAIL)""#, in: manifestJson)
    }

    /// Beside the bundle (not inside it, so the bundle's file list stays exactly what the core wrote).
    public static func verifiedMarker(_ bundle: URL) -> URL {
        let b = bundle.standardizedFileURL
        return b.deletingLastPathComponent().appendingPathComponent(b.lastPathComponent + ".upload_verified")
    }

    public static func isMarker(_ name: String) -> Bool { name.hasSuffix(".upload_verified") }

    public static func percent(done: Int64, total: Int64) -> Int { total <= 0 ? 0 : min(max(Int((done * 100) / total), 0), 100) }
}
