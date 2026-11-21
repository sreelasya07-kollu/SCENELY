import SwiftUI
import CaptureKit

/// One bundle folder as shown in My scans.
struct ScanRow: Identifiable, Equatable {
    let id: URL
    let timeMs: Int64
    let verdict: String?
    let size: Int64
    /// manifest.json bundle_id (nil until the scan is finalized); needed for the server results.
    var bundleId: String? = nil
}

/// Disk reads for My scans (blocking: call off the main thread). Kept outside the View so it is not main-actor isolated.
enum ScanList {
    static func load() -> [ScanRow] {
        ScanStorage.list().map { dir in
            let manifest = (try? String(contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)) ?? ""
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let lastModifiedMs = Int64(modified.timeIntervalSince1970 * 1000)
            return ScanRow(id: dir, timeMs: ScanInfo.timeMs(dirName: dir.lastPathComponent, lastModified: lastModifiedMs),
                           verdict: ReviewRules.parseManifest(manifest).verdict, size: ScanStorage.sizeBytes(dir),
                           bundleId: UploadPlan.bundleId(manifest))
        }.sorted { $0.timeMs > $1.timeMs }
    }
}

/// "My scans" (mirrors S/ScansActivity.kt): every bundle on this phone, newest first, with date, size and the validator verdict as a
/// coloured badge with words. With server URLs configured (AppConfig) each row also shows the upload state, Upload / Retry (needs upload
/// consent and a PASS or WARN verdict) and, once the scan is verified, a link to its Results. Interrupted sessions are recovered before
/// listing (needs the core). `onRescan` is what Results' "Rescan this area" calls (the router opens Capture); nil hides that button.
struct ScansView: View {
    var onRescan: (() -> Void)?
    @State private var rows: [ScanRow]?
    @State private var consentUpload = ConsentStore.standard().uploadAllowed()
    @ObservedObject private var uploads = UploadCoordinator.shared
    private let verdictText = ScanStorage.verdictText()

    init(onRescan: (() -> Void)? = nil) { self.onRescan = onRescan }

    var body: some View {
        Group {
            if let rows = rows {
                if rows.isEmpty { empty } else { list(rows) }
            } else {
                ProgressView().tint(Theme.label)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .page()
        .navigationTitle("My scans")
        .navigationBarTitleDisplayMode(.large)
        .task { await reload() }
        .onAppear { consentUpload = ConsentStore.standard().uploadAllowed() }   // consent may have been revoked in Settings
        .task(id: rows?.count ?? -1) { await showServerChecks() }
    }

    /// Server-side check line for scans verified earlier (one bounded ask each; cancelled when the screen goes away).
    @MainActor private func showServerChecks() async {
        guard AppConfig.uploadAvailable else { return }
        for r in rows ?? [] where uploads.status(for: r.id).state == .verified && uploads.serverCheck(for: r.id) == nil {
            if Task.isCancelled { return }
            await uploads.refreshServerCheck(bundle: r.id)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No scans yet").font(.title2.bold()).foregroundStyle(Theme.label)
            Text("Start a scan from Home. Finished scans appear here.").font(.subheadline).foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func list(_ rows: [ScanRow]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if AppConfig.uploadAvailable && !consentUpload {
                    Text("Uploading is off. You did not allow uploads in the consent screen.")
                        .font(.subheadline).foregroundStyle(Theme.amber).frame(maxWidth: .infinity, alignment: .leading).card()
                }
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(friendlyDate(r.timeMs)).font(.headline).foregroundStyle(Theme.label)
                            Spacer()
                            Text(ReviewRules.humanSize(r.size)).font(.footnote).foregroundStyle(Theme.label2)
                        }
                        Chip(text: ScanInfo.badgeText(r.verdict), color: Theme.verdictColor(r.verdict))
                        Text(verdictText.headline(r.verdict)).font(.subheadline).foregroundStyle(Theme.label2)
                        if AppConfig.uploadAvailable { uploadSection(r) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).card()
                }
            }
            .padding(20)
        }
        .refreshable { await reload() }
    }

    private func uploadColor(_ s: UploadState) -> Color {
        switch s {
        case .none, .waiting: return Theme.grey
        case .uploading: return .blue
        case .retrying: return Theme.amber
        case .verified: return Theme.green
        case .failed: return Theme.red
        }
    }

    /// Upload chip with words, the server check line, Upload / Retry and View results. Upload needs consent now (re-read at the tap too)
    /// and a PASS or WARN verdict (UploadPolicy); a FAIL or unfinished scan gets an explanation instead of a button.
    @ViewBuilder private func uploadSection(_ r: ScanRow) -> some View {
        let s = uploads.status(for: r.id)
        let canUpload = consentUpload && UploadPolicy.eligible(consentNow: true, verdict: r.verdict)
        Chip(text: UploadText.text(s), color: uploadColor(s.state))
        if s.state == .uploading { ProgressView().tint(Theme.label).accessibilityLabel("Uploading") }
        if s.state == .verified, let check = uploads.serverCheck(for: r.id) {
            Text(check).font(.footnote).foregroundStyle(Theme.label2)
        }
        if canUpload && (s.state == .none || s.state == .failed) {
            let title = s.state == .failed ? "Retry upload" : "Upload"
            Button(title) { uploads.start(bundle: r.id, verdict: r.verdict) }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("\(title) for the scan from \(friendlyDate(r.timeMs))")
        } else if r.verdict != "PASS" && r.verdict != "WARN" && s.state == .none {
            Text(r.verdict == "FAIL" ? "A failed scan is never uploaded." : "Not finalized: this scan cannot be uploaded.")
                .font(.footnote).foregroundStyle(Theme.label3)
        }
        if AppConfig.resultsAvailable, s.state == .verified, let id = r.bundleId {
            NavigationLink { ResultsView(bundleId: id, onRescan: onRescan) } label: { Text("View results") }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("View the server results for the scan from \(friendlyDate(r.timeMs))")
        }
    }

    private func reload() async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> [ScanRow] in
            _ = await Recovery.result()
            return ScanList.load()
        }.value
        rows = loaded
    }

    private func friendlyDate(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let time = date.formatted(date: .omitted, time: .shortened)
        switch HomeText.day(ms: ms, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) {
        case .today: return "Today, \(time)"
        case .yesterday: return "Yesterday, \(time)"
        case .thisYear: return date.formatted(.dateTime.day().month(.abbreviated)) + ", \(time)"
        case .older: return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }
}
