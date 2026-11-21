import SwiftUI
import CaptureKit

/// What the review-before-finish sheet shows (twin of S/ReviewSheet.kt). Pure: built from the last core overlay and the live summary, so
/// it has no ARKit / core dependency. Wall names are "Wall N" (the core's stable wall id); only evidenced walls count (ReviewRules).
struct ReviewSheetData: Equatable {
    let completenessPct: Int
    let empty: Bool
    let weakWalls: [Int]
    let gapsText: String
    let zones: [String]
    let found: String

    /// `guidance` off (ADR 0032): the weak-wall part is gated, only the empty-scan notice remains. "Found" needs `detector`.
    static func make(overlay: OverlayEvent?, summary: Completeness.Summary, guidance: Bool, detector: Bool) -> ReviewSheetData {
        let found = detector ? (overlay.map { ObjectSummary.text(objects: $0.objects, openings: $0.openings) } ?? "") : ""
        return ReviewSheetData(
            completenessPct: summary.completenessPct,
            empty: ReviewRules.nothingFound(overlay),
            weakWalls: guidance ? ReviewRules.weakWalls(overlay) : [],
            gapsText: ReviewRules.gapsText(overlay, guidance: guidance),
            zones: summary.weakZones.prefix(5).map { $0.text },
            found: found)
    }
}

/// "Before you finish": completeness, weak zones, "Scan the gaps" (resume the same bundle) or "Finish anyway". Not dismissable by
/// swiping: the scan is paused and the two buttons are the only ways out.
struct ReviewSheetView: View {
    let data: ReviewSheetData
    let onGaps: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Before you finish").font(.title2.bold()).foregroundStyle(Theme.label)
            Text("Complete: \(data.completenessPct)%").font(.subheadline.weight(.bold)).foregroundStyle(Theme.label)
            Text(data.gapsText).font(.subheadline)
                .foregroundStyle(data.empty || !data.weakWalls.isEmpty ? Theme.amber : Theme.label2)
                .accessibilityLabel("Complete \(data.completenessPct) percent. \(data.gapsText)")
            ForEach(Array(data.zones.enumerated()), id: \.offset) { _, z in
                Text("\u{2022} \(z)").font(.footnote).foregroundStyle(Theme.label2)
            }
            if !data.found.isEmpty { Text("Found: \(data.found).").font(.subheadline).foregroundStyle(Theme.label2).padding(.top, 4) }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button("Finish anyway", action: onFinish).buttonStyle(SecondaryButtonStyle())
                Button(data.empty ? "Keep scanning" : "Scan the gaps", action: onGaps).buttonStyle(BigButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .page()
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
