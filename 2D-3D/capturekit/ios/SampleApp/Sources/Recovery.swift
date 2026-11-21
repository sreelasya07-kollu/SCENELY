import CaptureKit
import Foundation

/// Interrupted-session recovery (Android SessionManager.recoverInterrupted at app start). `CaptureSession` exists only when the C++ core is
/// linked into the CaptureKit package (CAPTUREKIT_CORE_LIB_DIR, see ios/README.md); the condition below mirrors CaptureSession.swift and is
/// UNVERIFIED: whether `canImport(CCaptureKit)` is true in the app target (it is an internal package target) needs a Mac build. Without it
/// nothing is recovered and 0 is returned.
enum Recovery {
    /// Runs at most once per process (CaptureSession.recoverInterrupted has no lock). Every caller awaits the same task.
    private static let once = Task.detached(priority: .utility) { () -> Int in
        #if os(iOS) && canImport(CCaptureKit)
        return CaptureSession.recoverInterrupted().count
        #else
        return 0
        #endif
    }

    /// Number of scans recovered by the single run of this process (waits for it if still running).
    static func result() async -> Int { await once.value }
}
