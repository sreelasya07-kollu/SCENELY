import CaptureKit
import CoreVideo
import Foundation

/// A bi-planar YCbCr 4:2:0 (NV12, ARKit's capturedImage format) pixel buffer as a `SegImage`. Holds the base-address lock for its
/// lifetime (read-only), so keep it only for one segmentation run. Pixels are converted on demand (BT.601 full range).
public final class PixelBufferSegImage: SegImage {
    public let w: Int
    public let h: Int
    private let buffer: CVPixelBuffer
    private let yPlane: UnsafePointer<UInt8>
    private let cPlane: UnsafePointer<UInt8>
    private let yStride: Int
    private let cStride: Int

    /// Nil unless the buffer has exactly two planes and a readable base address.
    public init?(_ pb: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pb) == 2 else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            return nil
        }
        buffer = pb
        w = CVPixelBufferGetWidthOfPlane(pb, 0); h = CVPixelBufferGetHeightOfPlane(pb, 0)
        yPlane = UnsafePointer(y.assumingMemoryBound(to: UInt8.self)); cPlane = UnsafePointer(c.assumingMemoryBound(to: UInt8.self))
        yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0); cStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    }

    deinit { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    public func argb(_ x: Int, _ y: Int) -> UInt32 {
        let px = min(max(x, 0), w - 1), py = min(max(y, 0), h - 1)
        let ci = (py / 2) * cStride + (px / 2) * 2
        return YCbCr.argb(yPlane[py * yStride + px], cPlane[ci], cPlane[ci + 1])
    }
}
