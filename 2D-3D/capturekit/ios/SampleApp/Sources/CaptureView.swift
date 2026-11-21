import SwiftUI
#if os(iOS)
import ARKit
import CaptureKit

/// The capture route (twin of S/CaptureActivity.kt): AR preview, live object boxes, HUD, finish confirmation, review-before-finish sheet.
///
/// The screen needs the C++ core (`CaptureSession`), which exists only when the package is built with CAPTUREKIT_CORE_LIB_DIR (ios/README.md).
/// The `canImport(CCaptureKit)` condition mirrors Recovery.swift and is UNVERIFIED in the app target (needs a Mac build); without it the
/// route shows an explanation instead of a camera.
struct CaptureScreen: View {
    /// Consent is missing at Start: the router goes back to the consent screen.
    let onNeedConsent: () -> Void
    /// Finish completed: the router opens the Review screen.
    let onFinished: (ReviewArgs) -> Void

    var body: some View {
        #if canImport(CCaptureKit)
        CaptureView(onNeedConsent: onNeedConsent, onFinished: onFinished)
        #else
        CaptureUnavailableView()
        #endif
    }
}

#if canImport(CCaptureKit)
struct CaptureView: View {
    let onNeedConsent: () -> Void
    let onFinished: (ReviewArgs) -> Void
    @StateObject private var m = CaptureModel()
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ARPreview(session: m.arSession).ignoresSafeArea()
            // Live boxes, refreshed every display frame from the tracker (p5 draws them in BoxOverlay); never takes touches.
            GeometryReader { g in
                TimelineView(.animation) { _ in
                    let snap = m.boxSnapshot()
                    BoxOverlay(boxes: snap?.boxes ?? [], imageSize: snap?.imageSize ?? .zero,
                               mapRect: snap.map { s -> (CGRect, CGSize) -> CGRect in { rect, size in s.map(rect, size) } })
                }
                .onAppear { m.setViewport(g.size) }
                .onChange(of: g.size) { _, size in m.setViewport(size) }
            }
            .ignoresSafeArea()
            HudView(m: m, onClose: { dismiss() })
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(m.recording)
        .onAppear {
            m.onNeedConsent = onNeedConsent
            m.onFinished = onFinished
            UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on while scanning (Android FLAG_KEEP_SCREEN_ON)
            m.begin()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            m.teardown()
        }
        .onChange(of: phase) { old, new in
            if new == .background { m.appActive(false) } else if new == .active && old == .background { m.appActive(true) }
        }
        .alert("Finish the scan?", isPresented: Binding(get: { m.finishAsk }, set: { if !$0 && m.finishAsk { m.finishAnswered(false) } })) {
            Button("Finish", role: .none) { m.finishAnswered(true) }
            Button("Keep scanning", role: .cancel) { m.finishAnswered(false) }
        } message: {
            Text("Say yes or no, or tap a button.")
        }
        .alert("Voice commands", isPresented: Binding(get: { m.rationale != nil }, set: { if !$0 && m.rationale != nil { m.answerRationale(false) } })) {
            Button("Allow") { m.answerRationale(true) }
            Button("Not now", role: .cancel) { m.answerRationale(false) }
        } message: {
            Text("To hear your voice commands, CaptureKit needs the microphone and speech recognition. Listening starts only when you tap Mic, runs on the phone, and nothing is recorded. The buttons always work.")
        }
        .sheet(isPresented: Binding(get: { m.reviewSheet != nil }, set: { _ in })) {
            if let d = m.reviewSheet { ReviewSheetView(data: d, onGaps: { m.reviewGaps() }, onFinish: { m.reviewFinish() }) }
        }
    }
}
#else
/// Shown when this build has no C++ core linked.
struct CaptureUnavailableView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Scanning is not available in this build").font(.title3.bold()).foregroundStyle(Theme.label)
            Text("Build the app with the CaptureKit core linked (ios/README.md, CAPTUREKIT_CORE_LIB_DIR) to scan.")
                .font(.subheadline).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .page()
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
#endif
