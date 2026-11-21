import SwiftUI
import UIKit
import WebKit
import CaptureKit

/// Entry point for other screens (p3b's Review): a "View results" button that exists only when this build has a job server
/// (CK_JOBS_URL) AND the scan was uploaded and verified (`.upload_verified` marker). Otherwise it renders nothing.
/// Call it as one line inside a NavigationStack: `ScanResultsLink(bundle: bundleURL)`.
struct ScanResultsLink: View {
    let bundle: URL
    var onRescan: (() -> Void)?

    var body: some View {
        if let id = ScanResultsLink.verifiedBundleId(bundle) {
            NavigationLink {
                ResultsView(bundleId: id, onRescan: onRescan)
            } label: {
                Text("View results")
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityHint("Shows what the server made of this scan")
        }
    }

    /// bundle_id when results can be shown for this folder, else nil.
    static func verifiedBundleId(_ bundle: URL) -> String? {
        guard AppConfig.resultsAvailable,
              FileManager.default.fileExists(atPath: UploadPolicy.verifiedMarker(bundle).path),
              let manifest = try? String(contentsOf: bundle.appendingPathComponent("manifest.json"), encoding: .utf8) else { return nil }
        return UploadPlan.bundleId(manifest)
    }
}

/// Results of one uploaded scan from the roomscan-recon job server (mirrors S/ResultsActivity.kt). Polls every 5 s while the job is queued
/// or running; the poll is the view's `.task`, so it is cancelled when the screen disappears and ends by itself at a terminal state.
/// Shows the server's verdict (never computed here), stages, measurements, floor plan, rescan hints and downloads.
struct ResultsView: View {
    let bundleId: String
    var onRescan: (() -> Void)?

    @State private var job: JobStatus?
    @State private var message: String? = "Loading the results..."
    @State private var planHTML: String?
    @State private var note: String?
    @Environment(\.openURL) private var openURL

    private let gate = ResultsGate(jobsURL: AppConfig.jobsURL)

    init(bundleId: String, onRescan: (() -> Void)? = nil) {
        self.bundleId = bundleId
        self.onRescan = onRescan
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note { Text(note).font(.footnote).foregroundStyle(Theme.amber) }
                if bundleId.isEmpty {
                    centered("This scan has no id, so there are no results to show.")
                } else if let job {
                    headline(job)
                    stages(job)
                    measurements(job)
                    floorPlan(job)
                    rescan(job)
                    downloads(job)
                } else if let message {
                    centered(message)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .page()
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.large)
        .task { await poll() }
    }

    private func poll() async {
        guard !bundleId.isEmpty else { return }
        let client = JobsClient(gate: gate)
        await client.poll(bundleId: bundleId) { update in
            Task { @MainActor in apply(update) }
        }
    }

    @MainActor private func apply(_ u: JobUpdate) {
        if let j = u.job { job = j; message = nil }
        else if let e = u.error { message = e }
        if let p = u.plan, let svg = p.svg { planHTML = ResultsText.floorPlanHTML(svg: svg) }
    }

    private func color(_ t: ResultsText.Tone) -> Color {
        switch t {
        case .ok: return Theme.green
        case .warn: return Theme.amber
        case .error: return Theme.red
        case .info: return Theme.grey
        case .muted: return Theme.label3
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.top, 48)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.label3).accessibilityAddTraits(.isHeader)
    }

    private func headline(_ job: JobStatus) -> some View {
        let h = ResultsText.headline(job)
        return VStack(alignment: .leading, spacing: 8) {
            Text(h.text).font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(RoundedRectangle(cornerRadius: 16).fill(color(h.tone).opacity(0.85)))
            if let notes = ResultsText.validationNotes(job) { Text(notes).font(.subheadline).foregroundStyle(Theme.label2) }
        }
    }

    @ViewBuilder private func stages(_ job: JobStatus) -> some View {
        if !job.stages.isEmpty {
            section("Progress")
            VStack(spacing: 0) {
                ForEach(Array(job.stages.enumerated()), id: \.offset) { _, s in
                    let label = ResultsText.stageLabel(s.status)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ResultsText.stageTitle(s.name)).foregroundStyle(Theme.label)
                            if let sub = ResultsText.stageSubtitle(s) { Text(sub).font(.footnote).foregroundStyle(Theme.label3) }
                        }
                        Spacer(minLength: 12)
                        Text("● " + label.text).font(.subheadline).foregroundStyle(color(label.tone))
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .card()
        }
    }

    @ViewBuilder private func measurements(_ job: JobStatus) -> some View {
        let rows = ResultsText.measurementRows(job)
        if !rows.isEmpty {
            section("Measurements")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack { Text(r.label).foregroundStyle(Theme.label); Spacer(); Text(r.value).foregroundStyle(Theme.label) }
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                }
            }
            .card()
        }
    }

    @ViewBuilder private func floorPlan(_ job: JobStatus) -> some View {
        if job.file(kind: "floorplan_svg") != nil, let html = planHTML {
            section("Floor plan")
            FloorPlanWebView(html: html)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Floor plan")
        }
    }

    @ViewBuilder private func rescan(_ job: JobStatus) -> some View {
        let items = job.rescanByPriority
        if !items.isEmpty {
            section("Areas to scan again")
            ForEach(Array(items.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 8) {
                    Text(r.surface.prefix(1).uppercased() + r.surface.dropFirst()).font(.headline).foregroundStyle(Theme.label)
                    Text(r.instruction.isEmpty ? "Scan this area again." : r.instruction).font(.subheadline).foregroundStyle(Theme.label2)
                    if let onRescan {
                        Button("Rescan this area") { onRescan() }
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityLabel("Rescan this area: \(r.surface)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).card()
            }
        }
    }

    @ViewBuilder private func downloads(_ job: JobStatus) -> some View {
        if !job.files.isEmpty {
            section("Downloads")
            VStack(spacing: 0) {
                ForEach(Array(job.files.enumerated()), id: \.offset) { _, f in
                    Button { open(f) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).foregroundStyle(Theme.label)
                                Text(ReviewRules.humanSize(f.size)).font(.footnote).foregroundStyle(Theme.label3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.label3)
                        }
                        .padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens the file")
                }
            }
            .card()
        }
    }

    private func open(_ f: JobStatus.File) {
        guard let abs = gate.absoluteUrl(f.url), let url = URL(string: abs) else { note = "This link is not from the results server."; return }
        note = nil
        openURL(url) { accepted in if !accepted { note = "No app can open this file." } }
    }
}

/// The floor plan SVG shown through WKWebView.loadHTMLString (inline SVG, JavaScript off, links not followed).
/// Apple docs: WKWebView.loadHTMLString(_:baseURL:), WKWebpagePreferences.allowsContentJavaScript.
struct FloorPlanWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences = prefs
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.isOpaque = true
        v.backgroundColor = .white
        v.scrollView.backgroundColor = .white
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            v.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .linkActivated ? .cancel : .allow)
        }
    }
}
