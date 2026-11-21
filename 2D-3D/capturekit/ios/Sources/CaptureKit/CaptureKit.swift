// Placeholder. No feature code yet.

// With the C++ core linked (CAPTUREKIT_CORE_LIB_DIR), re-export its C types so an app that imports CaptureKit can implement
// `CaptureSessionDelegate.didUpdatePolicy(_: ck_policy)` and compare `CaptureSession.finish()` with `CK_OK` without importing CCaptureKit.
#if canImport(CCaptureKit)
@_exported import CCaptureKit
#endif

/// CaptureKit SDK namespace.
public enum CaptureKit {
    /// SDK version string.
    public static let version = "0.0.1"
}
