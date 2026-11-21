import SwiftUI
import CaptureKit

/// Colours and small reusable views of the sample app (dark, like the Android sample).
enum Theme {
    static let bg = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)
    static let label = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let label2 = Color(red: 0xEB / 255, green: 0xEB / 255, blue: 0xF5 / 255).opacity(0.65)
    static let label3 = Color(red: 0xEB / 255, green: 0xEB / 255, blue: 0xF5 / 255).opacity(0.38)
    static let card = Color.white.opacity(0.08)
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let amber = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    static let red = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)
    static let grey = Color(red: 0x54 / 255, green: 0x6E / 255, blue: 0x7A / 255)
    /// The live object box colour 0xFF00E676 (contract: solid when seen in the last result, dashed when remembered).
    static let box = Color(red: 0, green: 0xE6 / 255, blue: 0x76 / 255)

    /// 0xAARRGGBB (the StatusPill tones) as a Color.
    static func argb(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255,
              opacity: Double((v >> 24) & 0xFF) / 255)
    }

    static func verdictColor(_ verdict: String?) -> Color {
        switch verdict {
        case "PASS"?: return green
        case "WARN"?: return amber
        case "FAIL"?: return red
        default: return grey
        }
    }
}

/// Full-width primary action.
struct BigButtonStyle: ButtonStyle {
    var tint: Color = Theme.label
    var foreground: Color = .black
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(enabled ? foreground : Theme.label3)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 26).fill(enabled ? tint : Theme.card))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Quiet secondary action.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.label)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 24).fill(Theme.card))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(RoundedRectangle(cornerRadius: 22).fill(Theme.card))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
    func page() -> some View { background(Theme.bg.ignoresSafeArea()).preferredColorScheme(.dark) }
}

/// A coloured pill with words (colour never carries the meaning alone).
struct Chip: View {
    let text: String
    var color: Color = Theme.grey
    var body: some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color))
    }
}
