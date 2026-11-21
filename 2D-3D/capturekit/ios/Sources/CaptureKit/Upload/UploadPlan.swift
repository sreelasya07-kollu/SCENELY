import Foundation

/// Pure helpers (host-testable, unlike `BundleUploader` which needs TUSKit): upload order and the verifier's status JSON.
/// Port of android/.../upload/UploadPlan.kt (`UploadPlan`, `ServerStatus`).
public enum UploadPlan {
    public static let manifest = "manifest.json"

    /// Every file of the bundle, relative paths with '/', manifest.json LAST (the server verifies on its arrival).
    public static func order(_ bundle: URL) -> [String] {
        let root = bundle.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var all: [String] = []
        let e = FileManager.default.enumerator(at: bundle.standardizedFileURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let u = e?.nextObject() as? URL {
            let name = u.lastPathComponent
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !name.hasSuffix(".tmp"), !name.hasPrefix(".ckit_upload") else { continue }
            let p = u.standardizedFileURL.path
            all.append(p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : name)
        }
        all.sort()
        return all.filter { $0 != manifest } + all.filter { $0 == manifest }
    }

    /// `bundle_id` of manifest.json text, or nil.
    public static func bundleId(_ manifestJson: String) -> String? { Rx.firstGroup(#""bundle_id"\s*:\s*"([^"]+)""#, in: manifestJson) }
}

/// `GET /bundles/<id>` on the verifier. `serverValidation*` is the server-side `ckit validate --level semantic` result
/// (`server_validation: {verdict, issues}` and `server_validation_state` none | pending | done; see dev-server/README.md).
public struct ServerStatus: Equatable {
    public let status: String
    public let reason: String
    public let corruptPaths: [String]
    public let missing: [String]
    public let serverValidationVerdict: String?
    public let serverValidationState: String

    public var isFinal: Bool { status == "COMPLETE" || status == "CORRUPT" }

    /// Nil when the text is not a JSON object with a status.
    public static func parse(_ json: String) -> ServerStatus? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let status = o["status"] as? String else { return nil }
        let corrupt = ((o["corrupt"] as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["path"] as? String }
        let missing = ((o["missing"] as? [Any]) ?? []).compactMap { $0 as? String }
        let verdict = (o["server_validation"] as? [String: Any])?["verdict"] as? String
        return ServerStatus(status: status, reason: (o["reason"] as? String) ?? "", corruptPaths: corrupt, missing: missing,
                            serverValidationVerdict: verdict, serverValidationState: (o["server_validation_state"] as? String) ?? "none")
    }

    /// Server check line for the upload status text, nil when the server has no validator or no answer yet.
    public var checkText: String? {
        switch serverValidationState {
        case "pending": return "Server check running..."
        case "done":
            switch serverValidationVerdict {
            case "PASS"?: return "Server check: passed"
            case "WARN"?: return "Server check: usable, with notes"
            case "FAIL"?: return "Server check: failed"
            default: return nil
            }
        default: return nil
        }
    }

    /// True while the verifier is still validating, so the screen keeps asking.
    public var checkPending: Bool { status == "COMPLETE" && serverValidationState == "pending" }
}

/// Words for an upload state (port of ScanUi.uploadText).
public enum UploadText {
    public static func text(_ s: UploadStatus) -> String {
        switch s.state {
        case .none: return "Not uploaded"
        case .waiting: return "Upload waiting for a network"
        case .uploading: return (0...100).contains(s.percent) ? "Uploading \(s.percent)%" : "Uploading"
        case .retrying: return "Upload will retry soon"
        case .verified: return "Uploaded and verified"
        case .failed:
            let e = (s.error ?? "").trimmingCharacters(in: .whitespaces)
            return e.isEmpty ? "Upload failed" : "Upload failed: \(e)"
        }
    }
}
