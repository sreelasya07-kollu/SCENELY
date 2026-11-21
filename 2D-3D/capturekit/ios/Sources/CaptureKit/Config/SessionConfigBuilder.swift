import Foundation

/// Assembles the flat config handed to `CaptureSession.start` / `ck_session_create` from its parts (pure, host-tested):
/// feature flags (`guide.understanding`, `record_imu`), consent (`consent_version`, `consent_at`, `redaction_mode`) and the
/// hold-still result (`calib.*`). Port of the Android shell's config map (ADR 0037).
public enum SessionConfigBuilder {
    /// Nil without consent (the caller must not start a scan). Later parts win on a key clash: `extra` < flags < consent < calibration.
    public static func build(flags: FeatureFlags.Flags, consent: SessionConfig?, calibration: StillnessCalibrator.Result?,
                             extra: SessionConfig = [:]) -> SessionConfig? {
        guard let consent else { return nil }
        var m = extra
        FeatureFlags.extraConfig(understanding: flags.understanding, recordImu: flags.recordImu).forEach { m[$0.key] = $0.value }
        consent.forEach { m[$0.key] = $0.value }
        calibration?.toSessionConfig().forEach { m[$0.key] = $0.value }
        return m
    }
}
