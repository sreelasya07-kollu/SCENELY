import SwiftUI
#if os(iOS) && canImport(CCaptureKit)
import CaptureKit

/// The capture HUD over the camera preview (twin of S/Hud.kt, one counterpart per element):
///  - top bar: Close (before a scan) | status pill | REC clock (PAUSED while paused)        = Hud.closeButton / pill / recRow
///  - second row: Mic chip | Boxes chip (on / off / unavailable) | Voice chip                = Hud.mic / boxes / voice
///  - banner (errors and blocking conditions) and the recalibration card                    = Hud.bannerRow / recalibrate
///  - left: completeness chip + top weak zone; beside it detail / voice feedback / result   = Hud.completeCard / detail / voiceLine / result
///  - action row: Repeat, What's missing, Volume -, Volume +                                = Hud.actionRow
///  - coaching capsule, then the shutter deck: Pause/Resume | Start/Finish | spacer         = Hud.coaching / shutterDeck
///  - viewfinder reticle while scanning                                                     = Hud.reticle
/// Left out on purpose: the research trial chip (field flavour only, no iOS counterpart) and the ingest debug line (long-press the pill).
struct HudView: View {
    @ObservedObject var m: CaptureModel
    var onClose: () -> Void

    var body: some View {
        ZStack {
            if m.recording { Reticle().frame(width: 84, height: 84).allowsHitTesting(false) }
            VStack(spacing: 8) {
                topBar
                chipsRow
                if let b = m.banner { bannerView(b) }
                middle
                Spacer(minLength: 0)
                if m.recording && !m.finishing { actionRow }
                coachingCapsule
                shutterDeck
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let text = m.recalPrompt { RecalibrateCard(text: text) }
        }
    }

    // MARK: top

    private var topBar: some View {
        HStack(spacing: 10) {
            if !m.recording && !m.finishing {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Theme.label)
                        .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.45)))
                }
                .accessibilityLabel("Close")
            }
            Chip(text: "\u{25CF} " + m.pill.text, color: Theme.argb(m.pill.tone.argb))
                .accessibilityLabel("Status: \(m.pill.text)")
            Spacer(minLength: 0)
            if m.recording { recRow }
        }
    }

    private var recRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.red).frame(width: 10, height: 10).opacity(m.paused ? 0.3 : 1)
            Text((m.paused ? "PAUSED  " : "REC  ") + ReviewRules.mmss(m.elapsedMs))
                .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Theme.label)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Capsule().fill(Color(red: 0x14 / 255, green: 0x18 / 255, blue: 0x24 / 255).opacity(0.9)))
        .accessibilityElement(children: .combine)
    }

    private var chipsRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let mic = m.mic { micChip(mic) }
            boxesChip
            if let on = m.voiceOn {
                Button { m.toggleVoice() } label: { Chip(text: on ? "Voice on" : "Voice off", color: on ? Theme.green : Theme.grey) }
                    .accessibilityLabel(on ? "Voice guidance on. Tap to turn off." : "Voice guidance off. Tap to turn on.")
            }
        }
    }

    private func micChip(_ s: MicState) -> some View {
        let (text, color, desc): (String, Color, String) = {
            switch s {
            case .idle: return ("Mic", Color(red: 0x45 / 255, green: 0x5A / 255, blue: 0x64 / 255), "Voice commands. Tap, then say pause, resume, repeat, what is missing, finish, louder or quieter.")
            case .listening: return ("Listening...", Theme.red, "Listening for a command. Tap to cancel.")
            case .thinking: return ("Working...", Theme.amber, "Understanding the command.")
            case .needsPermission: return ("Mic off", Theme.grey, "Voice commands need microphone permission. Tap to learn more.")
            }
        }()
        return Button { m.micTapped() } label: { Chip(text: text, color: color).frame(minHeight: 44) }
            .disabled(s == .thinking)
            .accessibilityLabel(desc)
    }

    @ViewBuilder private var boxesChip: some View {
        switch m.boxesChip {
        case .hidden: EmptyView()
        case .unavailable:
            // Flag on, but the model or GPU cannot run it (LiveObjectsController.isActive false): grey, not tappable (ADR 0038).
            Chip(text: "Object boxes unavailable", color: Theme.grey).frame(minHeight: 44)
                .accessibilityLabel("Object boxes are unavailable on this device.")
        case .on, .off:
            let on = m.boxesChip == .on
            Button { m.toggleBoxes() } label: { Chip(text: on ? "Boxes on" : "Boxes off", color: on ? Theme.green : Theme.grey).frame(minHeight: 44) }
                .accessibilityLabel(on ? "Object boxes on the camera view are shown. Tap to hide them." : "Object boxes on the camera view are hidden. Tap to show them.")
        }
    }

    private func bannerView(_ b: CaptureBanner) -> some View {
        HStack(spacing: 12) {
            Text(b.text).font(.subheadline).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            if b.action == .openSettings {
                Button("Settings") { m.openSettings() }.font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.2)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(color(b.kind)))
        .accessibilityElement(children: .combine)
    }

    private func color(_ k: CaptureBanner.Kind) -> Color {
        switch k {
        case .info: return Theme.grey
        case .warn: return Color(red: 0xEF / 255, green: 0x8F / 255, blue: 0)
        case .error: return Color(red: 0xC6 / 255, green: 0x28 / 255, blue: 0x28 / 255)
        }
    }

    // MARK: middle

    private var middle: some View {
        HStack(alignment: .center, spacing: 8) {
            if let s = m.summary { completeCard(s) }
            VStack(spacing: 6) {
                if let d = m.detail { glass(d) }
                if m.calibUi == .holdStill && !m.recording {
                    ProgressView(value: m.calibProgress).tint(Theme.green).frame(width: 160)
                        .accessibilityLabel("Hold still progress").accessibilityValue("\(Int(m.calibProgress * 100)) percent")
                }
                if let v = m.voiceLine { glass(v, lines: 3) }
                if let r = m.resultLine { glass(r) }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func completeCard(_ s: Completeness.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Chip(text: "Complete \(s.completenessPct)%", color: s.completenessPct >= 80 ? Theme.green : Theme.grey)
                .accessibilityLabel("Scan is \(s.completenessPct) percent complete")
            if let z = s.weakZones.first {
                Text(z.text).font(.footnote).foregroundStyle(Theme.label).lineLimit(2).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.45)))
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    private func glass(_ text: String, lines: Int = 2) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.label).lineLimit(lines).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.45)))
    }

    // MARK: bottom

    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                actionChip("Repeat", "Repeat the last instruction", .repeatLast)
                actionChip("What's missing", "Ask what is still missing", .missing)
                actionChip("Volume -", "Quieter voice", .quieter)
                actionChip("Volume +", "Louder voice", .louder)
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 48)
    }

    private func actionChip(_ label: String, _ desc: String, _ kind: ScanActions.Kind) -> some View {
        Button { m.perform(kind) } label: { Chip(text: label, color: Theme.grey).frame(minHeight: 48) }
            .accessibilityLabel(desc)
    }

    private var coachingCapsule: some View {
        Text(m.coaching).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.label)
            .multilineTextAlignment(.center).lineLimit(2)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(Capsule().fill(Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x24 / 255).opacity(0.95)))
            .animation(.easeInOut(duration: 0.15), value: m.coaching)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var shutterDeck: some View {
        HStack(spacing: 28) {
            Group {
                if m.recording && !m.finishing {
                    Button { m.togglePause() } label: {
                        Image(systemName: m.paused ? "play.fill" : "pause.fill").font(.title3).foregroundStyle(Theme.label)
                            .frame(width: 50, height: 50).background(Circle().fill(.black.opacity(0.45)))
                    }
                    .accessibilityLabel(m.paused ? "Resume scan" : "Pause scan")
                } else { Color.clear }
            }
            .frame(width: 50, height: 50)
            shutter
            Color.clear.frame(width: 50, height: 50)
        }
        .padding(.bottom, 4)
    }

    private var shutter: some View {
        let busy = m.finishing
        let enabled = m.recording ? !busy : m.startEnabled
        return Button { m.recording ? m.finishPressed() : m.startPressed() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                if m.recording { RoundedRectangle(cornerRadius: 6).fill(Theme.red).frame(width: 30, height: 30) }
                else { Circle().fill(.white).frame(width: 60, height: 60) }
            }
            .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
        .accessibilityLabel(m.recording ? "Finish scan" : "Start scan")
        .accessibilityHint(m.recording ? "" : (m.startEnabled ? "" : "Hold the phone still first"))
    }
}

/// Viewfinder corner brackets with a centre dot (Hud.ReticleView).
struct Reticle: View {
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 18, w = size.width, h = size.height
            var p = Path()
            for (cx, cy, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                p.move(to: CGPoint(x: cx + dx * l, y: cy)); p.addLine(to: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: cx, y: cy + dy * l))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: w / 2 - 3, y: h / 2 - 3, width: 6, height: 6)), with: .color(.white.opacity(0.9)))
        }
        .accessibilityHidden(true)
    }
}

/// Issue #1 / ADR 0031: centred "Recalibrating" card with a turning phone. `text` = the core's sentence (Recalibration.prompt).
struct RecalibrateCard: View {
    let text: String
    @State private var turn = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone").font(.system(size: 40)).foregroundStyle(Theme.amber)
                .rotationEffect(.degrees(turn ? 360 : 0))
                .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: turn)
            Text(Recalibration.title).font(.headline).foregroundStyle(Theme.label)
            Text(text).font(.subheadline).foregroundStyle(Theme.label2).multilineTextAlignment(.center)
        }
        .padding(20).frame(maxWidth: 300)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.78)))
        .onAppear { turn = true }
        .allowsHitTesting(false)   // never clickable
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Recalibration.title). \(text)")
    }
}
#endif
