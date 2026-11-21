// CaptureKit SampleApp (iOS). Generate the Xcode project with XcodeGen: `cd ios/SampleApp && xcodegen`.
import SwiftUI
#if os(iOS)
import ARKit
import CaptureKit

@main
struct SampleApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

/// Screens pushed on the Home stack.
enum Route: Hashable { case capture, review(ReviewArgs), scans, settings, recorder, clockCheck }

/// Root router (mirrors S/MainActivity.kt): onboarding on first launch, then Home. Consent is asked once after onboarding and again from
/// Start scan while missing (a full-screen cover, like Android's ConsentActivity); declining returns to Home, scanning stays blocked.
struct RootView: View {
    @State private var onboarded = Prefs.onboarded
    @State private var path: [Route] = []
    @State private var consentRequest: ConsentRequest?
    @State private var recoveryNote: String?

    var body: some View {
        Group {
            if onboarded {
                NavigationStack(path: $path) {
                    HomeView(path: $path, consentRequest: $consentRequest, recoveryNote: recoveryNote)
                        .navigationDestination(for: Route.self) { destination($0) }
                }
            } else {
                OnboardingView { finishOnboarding() }
            }
        }
        .fullScreenCover(item: $consentRequest) { req in
            ConsentView { accepted in
                consentRequest = nil
                if accepted && req.startScan { path.append(.capture) }
            }
        }
        .task {
            // App start: sessions still marked "recording" were interrupted (needs the linked core, see Recovery; runs once per process).
            let n = await Recovery.result()
            if n > 0 { recoveryNote = HomeText.recoveredNote }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .capture:
            CaptureScreen(
                // No consent at Start: back to the consent screen, which continues to capture on accept.
                onNeedConsent: { path.removeAll { $0 == .capture }; consentRequest = ConsentRequest(startScan: true) },
                // Finish done: the Review screen replaces the capture screen.
                onFinished: { args in path.removeAll { $0 == .capture }; path.append(.review(args)) })
        case .review(let args):
            ReviewView(args: args,
                       onNewScan: { path = [.capture] },
                       onMyScans: { path = [.scans] },
                       onDone: { path = [] })
        case .scans: ScansView(onRescan: { path.append(.capture) })
        case .settings: SettingsView()
        case .recorder: RecorderView(clockCheck: false)
        case .clockCheck: RecorderView(clockCheck: true)
        }
    }

    private func finishOnboarding() {
        Prefs.onboarded = true
        onboarded = true
        if !ConsentStore.standard().hasConsent() { consentRequest = ConsentRequest(startScan: false) }
    }
}

/// Phase 0 raw recorder / clock-check screen. Sessions land in Documents/sessions (Files app visible).
struct RecorderView: View {
    let clockCheck: Bool
    @State private var session = ARSession()
    @State private var recorder: RawRecorder?
    @State private var status = "idle"

    var body: some View {
        VStack(spacing: 16) {
            Text(clockCheck ? "Clock check" : "Raw recorder").font(.headline)
            Text(status).font(.caption.monospaced())
            Button(recorder == nil ? "Start" : "Stop") { recorder == nil ? start() : stop() }
                .buttonStyle(.borderedProminent)
        }
        .onDisappear { stop() }
    }

    private func start() {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions/\(clockCheck ? "clock" : "raw")_\(fmt.string(from: Date()))")
        let r = RawRecorder(dir: dir)
        r.clockCheck = clockCheck
        session.delegate = r
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity
        cfg.planeDetection = [.horizontal, .vertical]
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        r.start()
        recorder = r
        status = "recording \(dir.lastPathComponent)"
    }

    private func stop() {
        guard let r = recorder else { return }
        session.pause()
        r.stop()
        status = "saved \(r.dir.lastPathComponent), dropped=\(r.droppedCount)"
        recorder = nil
    }
}
#endif
