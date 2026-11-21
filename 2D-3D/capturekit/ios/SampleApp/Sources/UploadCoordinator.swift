import Foundation
import SwiftUI
import CaptureKit

/// App-wide upload state for My scans: one `BundleUploader` (TUSKit client) per bundle, started only by an explicit tap on Upload / Retry
/// (no background scheduler: iOS BGTaskScheduler is a non-goal). Consent and the validator verdict are checked again at every start via
/// `UploadPolicy.decide` with the consent value read from `ConsentStore` at that moment, so a revoked consent blocks the upload.
/// After the verifier says COMPLETE a `.upload_verified` marker is written beside the bundle (that is what unlocks "View results"),
/// and the verifier's `server_validation` answer is shown as a second status line.
@MainActor
final class UploadCoordinator: ObservableObject {
    static let shared = UploadCoordinator()

    @Published private(set) var statuses: [String: UploadStatus] = [:]
    @Published private(set) var serverChecks: [String: String] = [:]
    private var uploaders: [String: BundleUploader] = [:]
    private var generation: [String: Int] = [:]

    private func key(_ bundle: URL) -> String { bundle.standardizedFileURL.path }

    /// Current state: what this session did, else the marker left by an earlier verified upload, else never queued.
    func status(for bundle: URL) -> UploadStatus {
        if let s = statuses[key(bundle)] { return s }
        return FileManager.default.fileExists(atPath: UploadPolicy.verifiedMarker(bundle).path) ? UploadStatus(state: .verified) : UploadStatus(state: .none)
    }

    func serverCheck(for bundle: URL) -> String? { serverChecks[key(bundle)] }

    /// Upload or retry. Returns without effect when an upload for this bundle is already running.
    func start(bundle: URL, verdict: String?) {
        let k = key(bundle)
        if let s = statuses[k]?.state, s == .uploading || s == .waiting { return }
        guard let tus = AppConfig.tusURL else { return fail(k, "no upload server is set up in this build") }
        switch UploadPolicy.decide(consentNow: ConsentStore.standard().uploadAllowed(), verdict: verdict) {
        case .run: break
        case .noConsent: return fail(k, "uploads are off (consent)")
        case .verdictFail: return fail(k, "a failed scan is never uploaded")
        case .noVerdict: return fail(k, "this scan is not finalized")
        }
        let gen = (generation[k] ?? 0) + 1
        generation[k] = gen
        statuses[k] = UploadStatus(state: .uploading)
        do {
            let up = try uploaders[k] ?? BundleUploader(bundle: bundle, tusServer: tus, verifier: AppConfig.verifierURL, consent: true)
            uploaders[k] = up
            up.run { [weak self] outcome in
                Task { @MainActor in self?.finished(outcome, bundle: bundle, key: k, generation: gen) }
            }
        } catch {
            fail(k, error.localizedDescription)
        }
    }

    private func fail(_ k: String, _ message: String) { statuses[k] = UploadStatus(state: .failed, error: message) }

    private func finished(_ outcome: BundleUploader.Outcome, bundle: URL, key k: String, generation gen: Int) {
        guard generation[k] == gen else { return }   // a newer Retry replaced this run
        switch outcome {
        case .complete:
            _ = FileManager.default.createFile(atPath: UploadPolicy.verifiedMarker(bundle).path, contents: Data())
            statuses[k] = UploadStatus(state: .verified)
            uploaders[k] = nil
            Task { await refreshServerCheck(bundle: bundle) }
        case .retry(let why): statuses[k] = UploadStatus(state: .failed, error: why)
        case .failed(let why): statuses[k] = UploadStatus(state: .failed, error: why)
        }
    }

    /// Asks the verifier for `server_validation` (GET /bundles/<id>), every 3 s while it is still running, at most 20 times. Bounded, and it
    /// stops when the calling Task is cancelled (the screen's `.task` ends on disappear).
    func refreshServerCheck(bundle: URL) async {
        guard let verifier = AppConfig.verifierURL,
              let manifest = try? String(contentsOf: bundle.appendingPathComponent("manifest.json"), encoding: .utf8),
              let id = UploadPlan.bundleId(manifest) else { return }
        let k = key(bundle)
        var req = URLRequest(url: verifier.appendingPathComponent("bundles/\(id)"))
        req.timeoutInterval = 20
        for _ in 0..<20 {
            if Task.isCancelled { return }
            if let result = try? await URLSession.shared.data(for: req),
               let st = ServerStatus.parse(String(decoding: result.0, as: UTF8.self)) {
                if let line = st.checkText { serverChecks[k] = line }
                if !st.checkPending { return }
            } else {
                return   // unreachable: leave the last line as is
            }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
        }
    }
}
