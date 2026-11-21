import SwiftUI
import CaptureKit

/// Live object boxes over the camera feed (ADR 0035, scanned state ADR 0038), the iOS twin of Android ObjectBoxOverlayView.
/// Amber with a "label ..." tag while the object is not yet scanned, green with a "check label" tag once scanned; solid when seen in
/// the last segmentation result, dashed when only remembered. Display only, never recorded, never takes touches.
///
/// Standalone: give it the boxes of `LiveObjectTracker.drawBoxes` (camera-image pixels) and the camera image size. By default the image
/// is mapped to the view with aspect-fill (what a resizable, fill-mode camera preview does); pass `mapRect` to use the AR view's own
/// display transform instead.
struct BoxOverlay: View {
    let boxes: [DrawBox]
    /// Camera image size in pixels (CameraSnapshot.w x h).
    let imageSize: CGSize
    /// Image-pixel rectangle -> view-point rectangle; nil = aspect-fill of `imageSize` into the view.
    var mapRect: ((CGRect, CGSize) -> CGRect)?

    /// Same colours as Android (0xFF00E676 scanned, 0xFFFFB300 not yet).
    static let scannedColour = Color(red: 0, green: 0xE6 / 255, blue: 0x76 / 255)
    static let scanningColour = Color(red: 1, green: 0xB3 / 255, blue: 0)
    static let maxBoxes = 24

    /// Tag text: "check label #id" when scanned, "label #id ..." otherwise (the id text already carries the " seen" suffix).
    static func tag(_ b: DrawBox) -> String { b.scanned ? "\u{2713} \(b.text)" : "\(b.text) \u{2026}" }

    var body: some View {
        Canvas { ctx, size in
            for b in boxes.prefix(Self.maxBoxes) {
                let r = rect(b.box, in: size)
                let colour = b.scanned ? Self.scannedColour : Self.scanningColour
                let alpha = b.solid ? 1.0 : 0.78
                let style = StrokeStyle(lineWidth: 3, dash: b.solid ? [] : [10, 7])
                ctx.stroke(Path(r), with: .color(colour.opacity(alpha)), style: style)

                let text = Text(Self.tag(b)).font(.system(size: 13, weight: .bold)).foregroundColor(.black)
                let resolved = ctx.resolve(text)
                let ts = resolved.measure(in: CGSize(width: size.width, height: .greatestFiniteMagnitude))
                let pad: CGFloat = 4
                let w = ts.width + 2 * pad, h = ts.height + pad
                let x = min(max(r.minX, 0), max(0, size.width - w))
                let y = max(r.minY - h, 0)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: 4), with: .color(colour.opacity(alpha)))
                ctx.draw(resolved, at: CGPoint(x: x + pad, y: y + pad / 2), anchor: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // visual hint only
    }

    private func rect(_ b: Box2, in size: CGSize) -> CGRect {
        let img = CGRect(x: CGFloat(b.x0), y: CGFloat(b.y0), width: CGFloat(b.x1 - b.x0), height: CGFloat(b.y1 - b.y0))
        if let mapRect { return mapRect(img, size) }
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let s = max(size.width / imageSize.width, size.height / imageSize.height)
        let ox = (size.width - imageSize.width * s) / 2, oy = (size.height - imageSize.height * s) / 2
        return CGRect(x: img.minX * s + ox, y: img.minY * s + oy, width: img.width * s, height: img.height * s)
    }
}
