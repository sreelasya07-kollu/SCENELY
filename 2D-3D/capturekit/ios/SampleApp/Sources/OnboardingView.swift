import SwiftUI

/// The three first-launch pages (mirrors S/MainActivity.kt:showOnboarding). The last page asks for the camera, then calls `onFinish`
/// (the router sets `Prefs.onboardedKey`, like Android finishOnboarding, whatever the camera answer was).
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(title: String, lines: [String])] = [
        ("Scan a room in 3D", [
            "CaptureKit guides you around the room, tracks what you have covered, and tells you what to revisit.",
            "Press Start and move smoothly.\nFollow the spoken and on-screen cues.\nFinish and review your scan."]),
        ("Camera and motion", [
            "The camera maps the room and tracks your movement. Your scan stays on this phone unless you choose to upload it.",
            "Motion sensors keep tracking stable. Uploads and anonymous telemetry are optional and off by default."]),
        ("Before you start", [
            "Use good light.\nWalk slowly and keep the phone steady.\nTurn the volume up for spoken guidance.\nClose doors and keep people out of view."]),
    ]

    private var last: Int { pages.count - 1 }

    private var primaryTitle: String {
        if page < last { return "Continue" }
        return CameraAccess.granted ? "Continue" : "Allow camera and continue"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text(pages[page].title)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.label)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(pages[page].lines.enumerated()), id: \.offset) { i, line in
                Text(line).font(.body).foregroundStyle(i == 0 ? Theme.label2 : Theme.label)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Capsule().fill(i == page ? Theme.label : Theme.label3).frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(page + 1) of \(pages.count)")
            Button(primaryTitle) { next() }.buttonStyle(BigButtonStyle())
            if page > 0 || page < last {
                HStack(spacing: 10) {
                    if page > 0 { Button("Back") { page -= 1 }.buttonStyle(SecondaryButtonStyle()) }
                    if page < last { Button("Skip") { page = last }.buttonStyle(SecondaryButtonStyle()) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .page()
    }

    private func next() {
        if page < last {
            page += 1
        } else if CameraAccess.granted {
            onFinish()
        } else {
            CameraAccess.request { _ in onFinish() }
        }
    }
}
