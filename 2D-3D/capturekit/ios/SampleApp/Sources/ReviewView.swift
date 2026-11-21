import SwiftUI
import CaptureKit

/// Arguments of the Review screen, handed over by the capture screen after Finish (Android passes the same as Intent extras).
struct ReviewArgs: Hashable {
    let dir: String
    /// `ck_status` raw value of `CaptureSession.finish()` (0 = OK).
    let status: Int
    let elapsedMs: Int64
    let keyframes: Int
    /// The scan lifts detections to objects: "No objects recognised" is then meaningful.
    let objectsExpected: Bool
    /// Contract C3 summary JSON of the last live snapshot (nil = none).
    let summaryJSON: String?
    /// Last room snapshot's objects / openings in the overlay string formats (EventParser.encodeObjects / encodeOpenings).
    let objects: String
    let openings: String
}

/// What the Review screen reads from disk (off the main thread).
private struct ReviewFacts: @unchecked Sendable {
    let manifest: ReviewRules.Manifest
    let issues: [VerdictText.Issue]
    let verdictText: VerdictText
    let size: Int64
}

/// Review screen after Finish (twin of S/ReviewActivity.kt): save status, the validator verdict the core wrote into manifest.json
/// (PASS / WARN / FAIL) in plain language (verdict_messages.json), duration, keyframes, what was found, completeness and weak zones
/// (contract C3), size and folder; then My scans / Done / New scan. `extra` is a slot under the message for the upload state (p4);
/// `ScanResultsLink` shows "View results" only when the scan was uploaded and verified and a job server is configured.
struct ReviewView<Extra: View>: View {
    let args: ReviewArgs
    private let onNewScan: () -> Void
    private let onMyScans: () -> Void
    private let onDone: () -> Void
    private let extra: (URL, String?, Bool) -> Extra

    /// `extra`: (bundle folder, verdict, ready = saved and not FAIL) -> a view shown under the card (the upload state).
    init(args: ReviewArgs, onNewScan: @escaping () -> Void, onMyScans: @escaping () -> Void, onDone: @escaping () -> Void,
         @ViewBuilder extra: @escaping (URL, String?, Bool) -> Extra) {
        self.args = args; self.onNewScan = onNewScan; self.onMyScans = onMyScans; self.onDone = onDone; self.extra = extra
    }

    @State private var facts: ReviewFacts?
    private var dir: URL { URL(fileURLWithPath: args.dir, isDirectory: true) }
    private var ok: Bool { args.status == 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let f = facts { card(f) } else {
                    Text("Checking the scan...").font(.headline).foregroundStyle(Theme.label2).frame(maxWidth: .infinity, minHeight: 200)
                }
                if let f = facts {
                    let verdict = ok ? f.manifest.verdict : nil
                    let ready = ok && verdict != "FAIL"
                    extra(dir, verdict, ready)
                    if ok { ScanResultsLink(bundle: dir, onRescan: onNewScan) }
                }
                HStack(spacing: 12) {
                    Button("My scans", action: onMyScans).buttonStyle(SecondaryButtonStyle()).accessibilityHint("Open My scans")
                    Button("Done", action: onDone).buttonStyle(SecondaryButtonStyle())
                    Button("New scan", action: onNewScan).buttonStyle(BigButtonStyle())
                }
            }
            .padding(16)
        }
        .page()
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task { await load() }
    }

    // MARK: sections

    private func card(_ f: ReviewFacts) -> some View {
        let verdict = ok ? f.manifest.verdict : nil
        let ready = ok && verdict != "FAIL"
        let kf = f.manifest.keyframes ?? args.keyframes
        let durationMs = args.elapsedMs > 0 ? args.elapsedMs : f.manifest.durationMs
        let summary = ReviewRules.parseSummary(args.summaryJSON)
        return VStack(alignment: .leading, spacing: 12) {
            Text(ok ? "Scan saved" : "Save failed").font(.title.bold()).foregroundStyle(Theme.label)
            Chip(text: ok ? ScanInfo.badgeText(verdict) : "Not saved (status \(args.status))",
                 color: ok ? Theme.verdictColor(verdict) : Theme.red)
            VStack(alignment: .leading, spacing: 6) {
                if let d = durationMs, d > 0 { row("Duration", ReviewRules.mmss(d)) }
                row("Keyframes", "\(kf)")
                found
                if let s = summary {
                    row("Complete", "\(s.completenessPct)%")
                    if !s.zones.isEmpty { row("To improve", s.zones.map { "\u{2022} \($0)" }.joined(separator: "\n"), wrap: true) }
                }
                row("Size", ReviewRules.humanSize(f.size))
                row("Folder", dir.lastPathComponent)
                Text(dir.path).font(.caption.monospaced()).foregroundStyle(Theme.label3).textSelection(.enabled)
            }
            // Plain-language result: headline, then up to three notes (title, what happened, what to do), errors first.
            if ok, let v = verdict {
                Text(f.verdictText.headline(v)).font(.headline).foregroundStyle(Theme.label).padding(.top, 4)
                let notes = f.verdictText.describe(f.issues)
                ForEach(Array(notes.prefix(3).enumerated()), id: \.offset) { _, n in
                    let color = n.severity == "ERROR" ? Theme.red : Theme.amber
                    (Text("\u{25CF} ").foregroundColor(color) + Text("\(n.title). \(n.text) \(n.action)").foregroundColor(Theme.label2))
                        .font(.subheadline)
                        .accessibilityLabel("\(n.severity == "ERROR" ? "Problem" : "Note"): \(n.title). \(n.text) \(n.action)")
                }
                if notes.count > 3 { Text("and \(notes.count - 3) more").font(.footnote).foregroundStyle(Theme.label3) }
            }
            Text(message(ready: ready)).font(.subheadline).foregroundStyle(Theme.label2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// "Found" (objects by class plus doors / windows from the last room snapshot): needs the detector switch (ADR 0032).
    @ViewBuilder private var found: some View {
        if Prefs.flags().detector {
            let text = ObjectSummary.text(objects: EventParser.parseObjects(args.objects), openings: EventParser.parseOpenings(args.openings))
            if !text.isEmpty { row("Found", text, wrap: true).accessibilityLabel("Found in the room: \(text)") }
            else if args.objectsExpected { row("Found", "No objects recognised") }
        }
    }

    private func message(ready: Bool) -> String {
        if ready { return "The scan is stored on this phone." }
        return ok ? "Not ready: the check failed. Scan again, moving slowly and covering the whole room."
                  : "Something went wrong while saving. Scan again."
    }

    private func row(_ label: String, _ value: String, wrap: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.subheadline).foregroundStyle(Theme.label3).frame(width: 100, alignment: .leading)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Theme.label)
                .lineLimit(wrap ? nil : 1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: disk

    private func load() async {
        let dir = self.dir
        let f: ReviewFacts = await Task.detached(priority: .userInitiated) {
            let text = (try? String(contentsOf: dir.appendingPathComponent("manifest.json"), encoding: .utf8)) ?? ""
            return ReviewFacts(manifest: ReviewRules.parseManifest(text), issues: VerdictText.issuesOf(text),
                               verdictText: ScanStorage.verdictText(), size: ScanStorage.sizeBytes(dir))
        }.value
        facts = f
    }
}

extension ReviewView where Extra == EmptyView {
    init(args: ReviewArgs, onNewScan: @escaping () -> Void, onMyScans: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.init(args: args, onNewScan: onNewScan, onMyScans: onMyScans, onDone: onDone, extra: { _, _, _ in EmptyView() })
    }
}
