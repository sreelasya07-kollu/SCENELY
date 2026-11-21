import Foundation
#if canImport(CoreVideo)
import CoreVideo

/// One camera frame handed to the live segmentation (ADR 0035/0037): a private copy of the captured image (bi-planar YCbCr,
/// never an ARFrame), the camera that took it and the quarter turns (clockwise) that make it upright on screen.
/// Defined here (not in CaptureSession.swift) so CaptureKitSegment can use it without the C++ core being linked.
public struct SegmentationFrame {
    public let pixelBuffer: CVPixelBuffer
    public let camera: CameraSnapshot
    public let tNs: Int64
    public let quarterTurns: Int
    public init(pixelBuffer: CVPixelBuffer, camera: CameraSnapshot, tNs: Int64, quarterTurns: Int) {
        self.pixelBuffer = pixelBuffer; self.camera = camera; self.tNs = tNs; self.quarterTurns = quarterTurns
    }
}
#endif

/// BT.601 full-range YCbCr -> opaque ARGB (0xAARRGGBB), the conversion of the JPEG keyframes (same as the Android SegImage).
public enum YCbCr {
    public static func argb(_ y: UInt8, _ cb: UInt8, _ cr: UInt8) -> UInt32 {
        let yy = Float(y), uu = Float(cb) - 128, vv = Float(cr) - 128
        func c(_ v: Float) -> UInt32 { UInt32(min(max(Int(v), 0), 255)) }
        let r = c(yy + 1.402 * vv), g = c(yy - 0.344136 * uu - 0.714136 * vv), b = c(yy + 1.772 * uu)
        return 0xFF00_0000 | (r << 16) | (g << 8) | b
    }
}
