# 0034 Lean bundle: IMU not recorded by default (schema 1.4.0), one compressed archive (issue #10)

Status: accepted (2026-11-20), issue RealKarthiksai/2D-3D#10. Issue #10 was closed on 2026-11-19 with a comment but no
code for it landed (commit 8444b6f holds issue #6 / #7 work); this ADR and its PR deliver it in two stages.

## Inventory: what is in a bundle, who reads it, decision
| Item | Read by | Decision |
|---|---|---|
| `/pose`, `/intrinsics` | Part 2 P2 pose refinement, validator, replay | keep |
| `keyframes/*.jpg` (no EXIF: `YuvImage.compressToJpeg` writes plain JFIF; no GPS anywhere) | Part 2 P1 to P6 | keep |
| `/frame_index` (also non-keyframe rows) | Part 2 P1 "filter blur/exposure", validator, `quality-report`, replay compare | keep (about 35 B per candidate frame) |
| `/events` | validator (pause-aware POSE_GAP), governor / thermal timeline, `TRACKING_RESET` drift for Part 2 weighting | keep |
| `/ar/points`, `/ar/planes` | Part 2 P2 sparse prior, guide replay | keep |
| `/ar/detections`, `/guide/*`, `guidance_log.json` | Part 2 "labels, coverage map, guidance log are hints" | keep (only written when the feature that makes them is on, see ADR 0032) |
| `manifest.json`, `camera.json`, `privacy/redaction.json`, consent | Part 2 P0 / P1, legal | keep |
| **`/imu/gyro`, `/imu/accel`** | nothing in Part 2 (part2-reconstruction.md never reads them); the validator only checks NaN on samples that exist | **drop by default** |

ARCore still uses the IMU internally for tracking (frozen decision). The core keeps what it needs in memory only: the
gyro ring feeds `blur_risk_px` (quality) and the tracking-recovery steadiness check (ADR 0031); accel was only ever written.

## Decisions
- Session config key `record_imu` (default **0**): the live `Session` does not write `/imu/*`. `record_imu=1` keeps them for research (Android debug property `debug.capturekit.record_imu`). Writers outside the live session (`import-raw`, synthetic goldens, replay baselines) are unchanged: they write what they are given.
- Schema **1.4.0** (minor, additive): stamped by the manifest writer when the IMU was not recorded (`BundleMeta.imu_recorded = false`); `capture_settings.record_imu` says it too. From 1.4.0 `/imu/gyro` and `/imu/accel` are optional (the validator no longer reports MISSING_CHANNEL for them); older bundles with IMU, and 1.0.0 to 1.3.0 folders, validate unchanged. `counts.imu_gyro|imu_accel` stay required (0 when not recorded).
- Replay of a lean bundle has no gyro, so `blur_risk_px` is not recomputed there; the decisions the device took are in `/frame_index`.
- Archive: one `scan_<id>.zip` (JPEGs stored, everything else deflated, entries sorted, fixed timestamps: the same bundle always packs to the same bytes). `ckit pack` creates it, verifies it (every entry's size and sha256 against `manifest.files`, then the full validator on the archive) and only then may delete the loose folder (`--delete-source`). `ckit validate`, `replay`, `recon-bench` and the other readers accept `.zip` as well as a folder.
- Stage 2 (not in this PR): the Android shell packs at Finish, My scans / Review / upload read the archive, the tus client and the dev-server verifier take a single zip. It is separate because upload has never run on a device (docs/STATUS.md section 0) and the verifier needs the docker setup to test.
