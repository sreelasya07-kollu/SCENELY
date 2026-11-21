import AVFoundation
import ARKit
import CaptureKit
import Foundation

/// Server URLs from Info.plist (XcodeGen build settings `CK_TUS_URL`, `CK_VERIFIER_URL`, `CK_JOBS_URL`). Empty = the feature is hidden,
/// like the Android standard flavour: no upload UI (and no results screen) without a server. Local dev needs
/// `NSAppTransportSecurity.NSAllowsLocalNetworking` (set in project.yml).
enum AppConfig {
    private static func url(_ key: String) -> URL? {
        guard let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("$("), let u = URL(string: raw), u.scheme != nil else { return nil }
        return u
    }
    static var tusURL: URL? { url("CK_TUS_URL") }
    static var verifierURL: URL? { url("CK_VERIFIER_URL") }
    static var jobsURL: URL? { url("CK_JOBS_URL") }
    /// Upload UI is shown only with both server URLs (phase P4 uses them).
    static var uploadAvailable: Bool { tusURL != nil && verifierURL != nil }
    static var resultsAvailable: Bool { jobsURL != nil }
}

/// App-level preferences and the feature switches (contract C4, UserDefaults suite "capturekit").
enum Prefs {
    static let app = UserDefaults(suiteName: "ck_prefs") ?? .standard
    static let onboardedKey = "onboarded"
    static var onboarded: Bool {
        get { app.bool(forKey: onboardedKey) }
        set { app.set(newValue, forKey: onboardedKey) }
    }

    /// Spoken guidance on/off and the volume step (persisted like the Android SpeechRenderer).
    static let voiceEnabledKey = "voice_enabled"
    static let voiceVolumeKey = "voice_volume_step"
    static var voiceEnabled: Bool {
        get { app.object(forKey: voiceEnabledKey) as? Bool ?? true }
        set { app.set(newValue, forKey: voiceEnabledKey) }
    }

    /// The switches' storage: the C4 keys `ck.*` (Bool).
    static let features = UserDefaults(suiteName: FeatureFlags.userDefaultsSuite) ?? .standard

    /// Precedence: debug environment variable `CAPTUREKIT_<NAME>` (debug builds only) > the user setting > the default.
    static func flags() -> FeatureFlags.Flags {
        #if DEBUG
        let props = FeatureFlags.environmentProp(ProcessInfo.processInfo.environment)
        #else
        let props: (String) -> String? = { _ in nil }
        #endif
        return FeatureFlags.resolve(props: props, prefs: FeatureFlags.userPrefs(features))
    }
}

enum CameraAccess {
    static var granted: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    static var denied: Bool { [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video)) }
    static func request(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }
}

/// Where scans live: Documents/bundles/scan_yyyyMMdd_HHmmss (Files app visible; the name pattern is what `ScanInfo.timeMs` reads).
enum ScanStorage {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bundles", isDirectory: true)
    }

    static func newDir() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd_HHmmss"
        return root.appendingPathComponent("scan_" + f.string(from: Date()), isDirectory: true)
    }

    static func list() -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    static func sizeBytes(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in e { n += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return n
    }

    /// The verdict text bundled with the app (a copy of the Android verdict_messages.json), or the built-in fallback.
    static func verdictText() -> VerdictText {
        guard let u = Bundle.main.url(forResource: "verdict_messages", withExtension: "json"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return .fallback }
        return VerdictText.parse(s)
    }
}
