# 0025 Device-bundle fixes: t_ns <= 0, pause-aware POSE_GAP, recovered redaction log

Status: accepted (2026-11-17). Evidence: three bundles recorded on the real phone that day.
- Core ingest rejects pose, intrinsics and frame events with `t_ns <= 0` (`CK_ERR_ARG`, counted in the INGEST_DROP attrs): an unmapped platform clock put the first /pose and /intrinsics at log_time 0 and produced a 484056797 ms POSE_GAP. Validators add ERROR TIME_ZERO for old recordings. IMU is not checked (no bundle rule depends on it).
- `recover()` writes `privacy/redaction.json` with empty `keyframes` and `"recovered":true` when `redaction_mode` is `faces` and the log is missing. Keyframes are redacted before they are written (fail-closed), so only the log is lost. An existing log is never overwritten.
- POSE_GAP subtracts time inside pauses recorded in /events (`SESSION_PAUSED` until `SESSION_RESUMED`/STOPPED/RECOVERED, or end of poses if still paused); user and governor pauses both count.
- 0 keyframes is ERROR NO_KEYFRAMES; FEW_KEYFRAMES WARN stays for 1 to 9. Python and C++ validators keep the same rules (parity test).
