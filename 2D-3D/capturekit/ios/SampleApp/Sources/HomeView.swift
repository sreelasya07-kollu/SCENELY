import SwiftUI
import ARKit
import CaptureKit

/// A list row inside a `RowGroup`: title, optional subtitle, optional trailing view (mirrors UiKit.listRow).
struct InfoRow<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    var titleColor: Color = Theme.label
    var chevron = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(titleColor)
                if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(Theme.label2) }
            }
            Spacer(minLength: 8)
            trailing()
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.label3) }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension InfoRow where Trailing == EmptyView {
    init(title: String, subtitle: String = "", titleColor: Color = Theme.label, chevron: Bool = false) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor, chevron: chevron, trailing: { EmptyView() })
    }
}

/// Rounded glass group of rows separated by hairlines (mirrors UiKit.group).
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 22).fill(Theme.card))
    }
}

/// Home (mirrors S/MainActivity.kt:showHome): readiness line, alert cards (recovery, camera, AR), Start scan, Library, Privacy, Developer.
/// Start scan gates on camera, then consent, then the capture route, exactly like Android.
struct HomeView: View {
    @Binding var path: [Route]
    @Binding var consentRequest: ConsentRequest?
    let recoveryNote: String?

    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraOK = CameraAccess.granted
    @State private var cameraDenied = CameraAccess.denied
    @State private var voice = Prefs.voiceEnabled
    @State private var showRevoke = false
    @State private var revision = 0   // bumped after a consent change so the summary re-reads the store

    private let consent = ConsentStore.standard()
    private var arSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    private var summary: String { _ = revision; return HomeText.consentSummary(consent.current()) }

    private var ready: (text: String, color: Color) {
        if !cameraOK { return ("Camera access needed", Theme.red) }
        if !arSupported { return ("This phone does not support AR", Theme.amber) }
        return ("Ready to scan", Theme.label2)
    }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CaptureKit").font(.largeTitle.bold()).foregroundStyle(Theme.label).accessibilityAddTraits(.isHeader)
                    Text(ready.text).font(.subheadline).foregroundStyle(ready.color)
                }
                .padding(.top, 8).padding(.bottom, 12)

                if let note = recoveryNote {
                    alertCard(title: "Scan recovered", color: Theme.green, text: note) {
                        Button("View scans") { path.append(.scans) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                if !cameraOK {
                    alertCard(title: "Camera access needed", color: Theme.red,
                              text: "CaptureKit uses the camera to see the room and track your movement.") {
                        Button(cameraDenied ? "Open Settings" : "Allow camera") { allowCamera() }.buttonStyle(BigButtonStyle())
                    }
                }
                if !arSupported {
                    alertCard(title: "AR not supported", color: Theme.amber,
                              text: "This phone does not support AR. CaptureKit needs it to track the phone's position in the room.") { EmptyView() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan a room").font(.title.bold()).foregroundStyle(Theme.label)
                    Text("Walk slowly around the room. CaptureKit tracks what you have covered and tells you what is missing.")
                        .font(.body).foregroundStyle(Theme.label2).padding(.bottom, 14)
                    Button("Start scan") { startScan() }.buttonStyle(BigButtonStyle())
                }
                .padding(22).background(RoundedRectangle(cornerRadius: 30).fill(Theme.card))
                .padding(.bottom, 16)

                section("Library")
                RowGroup {
                    NavigationLink(value: Route.scans) { InfoRow(title: "My scans", subtitle: "Saved rooms and their check results", chevron: true) }
                    Divider().overlay(Theme.label3)
                    InfoRow(title: "Voice guidance", subtitle: "Spoken coaching while you scan") {
                        Toggle("Voice guidance", isOn: $voice).labelsHidden()
                    }
                    Divider().overlay(Theme.label3)
                    NavigationLink(value: Route.settings) {
                        InfoRow(title: "Settings", subtitle: "Object boxes, motion sensors, prompts, voice commands", chevron: true)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)

                section("Privacy")
                RowGroup {
                    InfoRow(title: "Stored on this phone", subtitle: summary)
                    Divider().overlay(Theme.label3)
                    Button { showRevoke = true } label: { InfoRow(title: "Withdraw consent", titleColor: Theme.red) }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)

                section("Developer")
                RowGroup {
                    NavigationLink(value: Route.recorder) { InfoRow(title: "Raw recorder", subtitle: "Raw camera and IMU capture", chevron: true) }
                    Divider().overlay(Theme.label3)
                    NavigationLink(value: Route.clockCheck) {
                        InfoRow(title: "Clock check", subtitle: "Camera and sensor timestamp offsets", chevron: true)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)

                Text("Version \(version)").font(.footnote).foregroundStyle(Theme.label3).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .page()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { refresh() } }
        .onChange(of: voice) { Prefs.voiceEnabled = voice }
        .onChange(of: consentRequest == nil) { revision += 1 }
        .alert("Withdraw consent?", isPresented: $showRevoke) {
            Button("Withdraw", role: .destructive) {
                consent.revoke()   // P4 also cancels queued uploads here (Android UploadWorker.cancelAll)
                revision += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scanning will be blocked until you accept again. Uploading and anonymous telemetry stop, and recorded choices are removed from this phone. Your saved scans stay on the phone.")
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.label2).textCase(.uppercase).padding(.leading, 4)
    }

    private func alertCard<Action: View>(title: String, color: Color, text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(color)
            Text(text).font(.subheadline).foregroundStyle(Theme.label2)
            action().padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func refresh() {
        cameraOK = CameraAccess.granted
        cameraDenied = CameraAccess.denied
        voice = Prefs.voiceEnabled
        revision += 1
    }

    private func allowCamera() {
        if cameraDenied {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } else {
            CameraAccess.request { _ in refresh() }
        }
    }

    /// Camera first, then consent (the consent screen continues to capture on accept), then the capture route.
    private func startScan() {
        if !CameraAccess.granted {
            allowCamera()
        } else if !consent.hasConsent() {
            consentRequest = ConsentRequest(startScan: true)
        } else {
            path.append(.capture)
        }
    }
}
