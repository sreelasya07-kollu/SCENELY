import SwiftUI
import CaptureKit

/// Why the consent screen opened: from Start scan (continue to the capture screen on accept) or after onboarding.
struct ConsentRequest: Identifiable {
    let id = UUID()
    let startScan: Bool
}

/// Bottom edge (maxY) of the end-of-text marker in the scroll view's own coordinate space.
private struct EndMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Consent screen (mirrors S/ConsentActivity.kt). The bundled text (consent_v1.txt, a placeholder pending a legal owner) scrolls; the two
/// optional choices (upload, anonymous telemetry) sit at its end and both start off. Accept stays disabled until the end marker below the
/// choices has been inside the viewport (exact geometry check, UNVERIFIED without a compiler). Decline just leaves: no consent, no scanning.
/// `onDone(true)` after accept (already stored via ConsentStore), `onDone(false)` on decline.
struct ConsentView: View {
    let onDone: (Bool) -> Void
    @State private var reachedEnd = false
    @State private var upload = false
    @State private var telemetry = false
    @State private var accepting = false

    private let head: String
    private let bodyText: String

    init(onDone: @escaping (Bool) -> Void) {
        self.onDone = onDone
        let url = Bundle.main.url(forResource: ConsentStore.textResource, withExtension: "txt")
        let text = (url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "Consent text missing\nThe consent text could not be loaded. Do not accept."
        let lines = text.components(separatedBy: "\n")
        head = lines.first ?? ""
        bodyText = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Before you scan").font(.largeTitle.bold()).foregroundStyle(Theme.label)
                            .accessibilityAddTraits(.isHeader)
                        Text(head.prefix(1).uppercased() + head.dropFirst().lowercased())
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.amber)
                            .frame(maxWidth: .infinity, alignment: .leading).card()
                        Text(bodyText).font(.callout).foregroundStyle(Theme.label2).lineSpacing(4)
                        Toggle("Allow uploading my finished scans (optional)", isOn: $upload).card()
                        Toggle("Allow anonymous crash and usage reports (optional)", isOn: $telemetry).card()
                        // End marker: its bottom edge reaching the viewport bottom means the whole text (and a text shorter than the screen) was shown.
                        Color.clear.frame(height: 1)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: EndMarkerKey.self, value: g.frame(in: .named("consentScroll")).maxY)
                            })
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 20).padding(.top, 20)
                }
                .coordinateSpace(name: "consentScroll")
                .onPreferenceChange(EndMarkerKey.self) { maxY in
                    if maxY <= viewport.size.height + 1 { reachedEnd = true }
                }
            }
            VStack(spacing: 8) {
                Text(reachedEnd ? "You can accept now. Both optional choices are off unless you turned them on."
                                : "Scroll down and read to the end to enable Accept.")
                    .font(.footnote).foregroundStyle(Theme.label3).multilineTextAlignment(.center)
                Button("Accept and continue") { accept() }
                    .buttonStyle(BigButtonStyle())
                    .disabled(!reachedEnd || accepting)
                    .accessibilityHint("Available after you scroll to the end of the consent text.")
                Button("Decline") { onDone(false) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("You will not be able to scan without consent.")
            }
            .padding(20)
        }
        .page()
    }

    private func accept() {
        guard reachedEnd, !accepting else { return }
        accepting = true
        ConsentStore.standard().accept(nowMs: Int64(Date().timeIntervalSince1970 * 1000), upload: upload, telemetry: telemetry)
        onDone(true)
    }
}
