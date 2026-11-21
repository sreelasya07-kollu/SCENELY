import Foundation

/// Recorded consent. `at` is ISO 8601 UTC, written by the shell (the core never reads a clock).
public struct Consent: Equatable {
    public let version: String
    public let at: String
    public let upload: Bool
    public let telemetry: Bool

    public init(version: String, at: String, upload: Bool, telemetry: Bool) {
        self.version = version
        self.at = at
        self.upload = upload
        self.telemetry = telemetry
    }
}

/// Minimal key/value seam so the store is host-testable. `put` must apply all entries together.
public protocol ConsentStorage: AnyObject {
    func getString(_ key: String) -> String?
    func getBoolean(_ key: String) -> Bool
    func put(strings: [String: String], booleans: [String: Bool])
    func clear()
}

/// UserDefaults-backed storage (suite "ck_consent", like the Android SharedPreferences file).
public final class UserDefaultsConsentStorage: ConsentStorage {
    private let defaults: UserDefaults
    private let suite: String

    public init(suite: String = ConsentStore.prefsSuite) {
        self.suite = suite
        self.defaults = UserDefaults(suiteName: suite) ?? .standard
    }

    public func getString(_ key: String) -> String? { defaults.string(forKey: key) }
    public func getBoolean(_ key: String) -> Bool { defaults.bool(forKey: key) }

    public func put(strings: [String: String], booleans: [String: Bool]) {
        for (k, v) in strings { defaults.set(v, forKey: k) }
        for (k, v) in booleans { defaults.set(v, forKey: k) }
        defaults.synchronize()
    }

    public func clear() {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
    }
}

/// Versioned consent. Consent recorded under an older text version counts as none, so a text change re-asks.
/// Upload and telemetry are separate opt-ins (default off) readable only through `uploadAllowed` / `telemetryAllowed`;
/// both are false whenever there is no current consent. Revoking clears everything.
public final class ConsentStore {
    /// Matches the bundled consent_v1.txt. Bump with the text.
    public static let currentVersion = "1"
    /// Bundle resource name for `currentVersion`.
    public static let textResource = "consent_v" + currentVersion
    public static let redactionMode = "faces"
    public static let prefsSuite = "ck_consent"

    private static let lock = NSLock()   // shared by all instances
    private static let kVersion = "version"
    private static let kAt = "at"
    private static let kUpload = "upload"
    private static let kTelemetry = "telemetry"

    private let storage: ConsentStorage

    public init(_ storage: ConsentStorage) { self.storage = storage }

    public static func standard() -> ConsentStore { ConsentStore(UserDefaultsConsentStorage()) }

    /// The current consent, or nil when never given, revoked, or recorded under another text version.
    public func current() -> Consent? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let v = storage.getString(Self.kVersion), let at = storage.getString(Self.kAt) else { return nil }
        if v != Self.currentVersion || at.isEmpty { return nil }
        return Consent(version: v, at: at, upload: storage.getBoolean(Self.kUpload), telemetry: storage.getBoolean(Self.kTelemetry))
    }

    public func hasConsent() -> Bool { current() != nil }
    public func uploadAllowed() -> Bool { current()?.upload == true }
    public func telemetryAllowed() -> Bool { current()?.telemetry == true }

    /// Records consent to the current text. `nowMs` is epoch ms from the shell clock.
    public func accept(nowMs: Int64, upload: Bool, telemetry: Bool) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        storage.put(strings: [Self.kVersion: Self.currentVersion, Self.kAt: Self.iso(nowMs)],
                    booleans: [Self.kUpload: upload, Self.kTelemetry: telemetry])
    }

    public func revoke() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        storage.clear()
    }

    /// Session config keys for the core: consent_version + consent_at (always together) and redaction_mode.
    /// Nil without consent, so the caller must not start a scan.
    public func sessionConfig() -> SessionConfig? {
        guard let c = current() else { return nil }
        return ["consent_version": .string(c.version), "consent_at": .string(c.at), "redaction_mode": .string(Self.redactionMode)]
    }

    /// ISO 8601 UTC with a trailing Z, whole seconds.
    public static func iso(_ epochMs: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0))
    }
}
