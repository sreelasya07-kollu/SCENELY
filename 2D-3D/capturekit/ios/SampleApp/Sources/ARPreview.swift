import SwiftUI
#if os(iOS)
import ARKit

/// The camera preview of the capture screen: an ARSCNView that SHOWS the ARSession owned by `CaptureSession` (`CaptureSession.arSession`).
/// It never runs, pauses or configures the session and never sets `session.delegate` (CaptureSession is the delegate), so there is only
/// one ARSession in the app. UNVERIFIED pattern (needs a device): ARSCNView.session is a read-write property in Apple's ARKit docs
/// (https://developer.apple.com/documentation/arkit/arscnview/session); assigning an externally owned session is the documented way to
/// render a session the view did not create.
struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.automaticallyUpdatesLighting = false
        v.autoenablesDefaultLighting = false
        v.isUserInteractionEnabled = false   // touches go to the HUD
        return v
    }

    func updateUIView(_ v: ARSCNView, context: Context) {
        if v.session !== session { v.session = session }   // never pauses the old one: CaptureSession owns the lifecycle
    }
}
#endif
