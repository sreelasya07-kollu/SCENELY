# Feature status: the 14 stages, one row per feature

One table for the whole program (Part 1 phone capture + Parts 3 and 4 in this repo). Audited against the code at
base commit cde7a62 plus the uncommitted `2D-3D` working tree of 2026-11-22. Where a row says "unknown" the
code and docs give no evidence either way. The stage list is the owner's own 14 stages (coordinator message
2026-11-22), not a project document. Ownership of this file: T-029 in [04-TASKS.md](04-TASKS.md).

Status values: **done** (built and tested on its own terms, see the gap) · **partial** · **GPU-unverified**
(built, never run on an NVIDIA GPU) · **Android-only** (iOS never compiled) · **not built** ·
**removed from scope** · **unknown**.

Evidence paths: `capturekit/...` is `2D-3D/capturekit/...`; every other path is in `roomscan-recon/`. Detailed
Part 1 state: [2D-3D docs/STATUS.md](../../2D-3D/docs/STATUS.md) (section 0 is the default-build feature table,
audited against the phone), [DEVICE_TEST_LOG.md](../../2D-3D/docs/DEVICE_TEST_LOG.md), ADRs in
`2D-3D/capturekit/docs/decisions/`. Whole-program facts that apply to stages 1 to 7: **iOS was never compiled**
(no Mac), so every phone feature below is Android-only; features switched off by default (ADR 0032) have never
passed on a phone.

## Stages 1 to 7: phone capture and transport (Part 1)

| # | Feature | Status | Evidence | Gap |
|---|---|---|---|---|
| **1** | **Onboarding, permissions, consent** | | | |
| 1.1 | Permission handshake: camera, IMU, microphone | Android-only | Camera: `capturekit/android/sample-app/.../UiKit.kt` `CameraPermission`, `ArHost.kt:112`. Microphone: `VoiceController.kt` (rationale first, only when the voice flag is on). IMU: no permission is declared (rate cap 200 Hz, `SensorBridge.kt:50`) | Camera path device-tested (DEVICE_TEST_LOG 2026-11-17); microphone path never device-tested (`voice_commands` OFF, H12, H31); iOS none |
| 1.2 | Onboarding tutorial: pace, angles, lighting | partial | `MainActivity.kt:107` `showOnboarding`, 3 pages: "walk slowly and keep the phone steady", "use good light" | Pace and lighting only; nothing about viewing angles; no device-test row |
| 1.3 | Versioned consent | Android-only | `capturekit/android/capturekit/.../consent/ConsentStore.kt` (older text version counts as no consent), `ConsentActivity.kt`, manifest schema 1.2.0 `consent`, ADR 0020 | Device PASS (H13). Consent text is a placeholder pending a legal owner (STATUS.md section 3.4) |
| **2** | **Live sensor capture** | | | |
| 2.1 | Exposure and focus lock | removed from scope | No exposure/focus-lock code exists (no `AE_LOCK` / `FOCUS_MODE` in `capturekit/`); program spec lists none | Owner's decision: not built on purpose |
| 2.2 | Phone camera only (ARKit / ARCore, no LiDAR) | Android-only | `capturekit/android/capturekit/.../capture/ARAdapter.kt`; program spec `2D-3D/docs/program-spec/part1-room-capture.md` ("no LiDAR"); ADR 0018 (no depth in v1 bundle) | ARCore only; the iOS ARKit adapter was never compiled (`ios/Sources/CaptureKit/`) |
| 2.3 | IMU >= 100 Hz on the `t_ns` clock | partial | `SensorBridge.kt:50` (200 Hz cap, spec needs >= 100 Hz); one monotonic ns clock, core never reads the system clock (AGENTS.md section C); ADR 0036 (Android records IMU by default; core default `record_imu=0`, ADR 0034) | Per-device clock offsets need real recordings (Phase 0 blocked on 8 golden sessions); IMU in the bundle is optional since schema 1.4.0 |
| 2.4 | Coordinate normalization (OpenCV camera, Y-up world) | done | `capturekit/core/geometry/geometry.cpp` (ARKit / ARCore / COLMAP / OpenGL adapters), AGENTS.md section C; 28 C++ tests, reprojection 0.59 to 1.01 px on synthetic data | Verified on synthetic data only; the ADR 0003 pixel-centre check needs checkerboard recordings (ADR 0005) |
| **3** | **Frame quality and hardware protection** | | | |
| 3.1 | Laplacian sharpness | done | `capturekit/core/quality/quality.cpp:147` `laplacian_var` | Thresholds are guesses, tuned on synthetic data only |
| 3.2 | Gyro blur predictor | done | `quality.cpp:117` `blur_risk_px` | Replay of a lean bundle has no gyro, so it is not recomputed there (ADR 0034); not tuned on real data |
| 3.3 | Exposure and contrast guard | partial | `quality.cpp:255` `exposure_ok`, `clip_low` / `clip_high`; coarse-scale Laplacian `texture_min` (`quality.hpp:46`) | No separate contrast metric; thresholds untuned on real data |
| 3.4 | Keyframe selector (dt, dR, sharpness) | done | `capturekit/core/quality/quality.cpp` `KeyframeSelector` (`quality.hpp:129`, `rot_deg`, dedup ADR 0033) | "Lost to fixed spacing on some synthetic sessions" (STATUS.md section 6); needs real rooms to retune |
| 3.5 | Thermal and battery governor | Android-only | `capturekit/core/governor/governor.cpp` (battery warn/pause levels, ladder), `android/capturekit/.../platform/ThermalAdapter.kt`, ADR 0007 | 10-minute soak test per device not run (docs/soak-test.md); iOS adapter uncompiled |
| **4** | **On-device room understanding** | | | |
| 4.1 | LiveMap | Android-only | `capturekit/core/guide/live_map.cpp` | Coverage thresholds tuned on a simulated walker; real walked scan FAILED guidance (DEVICE_TEST_LOG 2026-11-17, H9/H22); `guidance` flag OFF |
| 4.2 | Surface classifier | Android-only | `capturekit/core/guide/surface_classifier.cpp` (ADR 0022) | Same OFF flag; no real-room accuracy number |
| 4.3 | Opening detector | Android-only | `capturekit/core/guide/opening_detector.cpp` (ADR 0024) | Parameters are guesses (ADR 0024); not verified on a phone |
| 4.4 | 3D object lifter from 2D detections (Core ML / LiteRT) | Android-only | `capturekit/core/guide/object_lifter.cpp`; detector `android/capturekit/.../capture/DetectorWorker.kt` (EfficientDet-Lite0 on LiteRT, ADR 0017); live segmentation `segment/` (ADR 0035) | Core ML path not built; `detector` and `segmentation` flags OFF, never device-tested (H18, H19, H33, H37, H38) |
| 4.5 | NavGrid | Android-only | `capturekit/core/guide/nav_grid.cpp`, ADR 0010 | Real walked scan FAILED (a 4-wall room reported 8 walls); `guidance` OFF |
| 4.6 | Missing-area and gap finder | Android-only | `capturekit/core/guide/gap_finder.cpp`, `room_shell.cpp`; bundle channels `/guide/gaps`, `/guide/shell` (schema 1.3.0, ADR 0028) | Hand-labelled gaps on real sessions not done (STATUS.md section 3.3, phase 9); OFF |
| **5** | **Guidance and interaction** | | | |
| 5.1 | Next-best-view planner (Calibrate, Perimeter Sweep, Detail Pass, Gap Revisit, Loop Closure) | partial | `capturekit/core/guide/planner.cpp`: modes are `Sweep`, `Target`, `Finish` (`planner.hpp:35`) with revisit weighting (`revisit_factor`) and gap steering (`set_steer`); stillness calibration before Start (ADR 0036, `StillnessCalibrator.kt`) | The five named modes do not exist as modes; no loop-closure logic found; the planner FAILED on the first walked scan (69 instructions in 257 s, completeness 3 to 7 %); `guidance` OFF (see `2D-3D/docs/WALK_FAILURE_RCA.md`) |
| 5.2 | AR overlay (heatmap, arrows) | partial | Overlay snapshot `capturekit/core/guide/overlay.cpp` (ADR 0013, 0022, 0026); Android HUD `sample-app/.../Hud.kt`; mini-map with heading arrow `RoomView.kt` (removed from the capture screen by issue #8a, kept in Review) | No coverage heatmap rendering found; `arrow:` is only a hint string (`instruction.cpp:174`), not drawn on the camera view |
| 5.3 | Audio and haptic prompts | Android-only | `android/capturekit/.../guidance/SpeechScheduler.kt`, `HapticMap.kt`, `sample-app/.../SpeechRenderer.kt` (TTS), ADR 0014 | Safety/tracking prompts are ON (DEVICE_TEST_LOG, "More light"); navigation / progress prompts OFF (`guidance`); iOS none |
| 5.4 | Voice assistant | Android-only | `VoiceController.kt`, `VoiceIntent.kt`, `StateAnswers.kt`, ADR 0019 (no LLM in the loop) | OFF (`voice_commands`), never device-tested (H12, H31); API 31+ only |
| 5.5 | Tracking recalibration | Android-only | `capturekit/core/guide/recovery.cpp`, `guidance/Recalibration.kt`, `RecalibrateOverlay.kt`, ADR 0031 | The card is OFF (`recalibrate_card`); the cover/uncover device check (H36) was not run |
| **6** | **Finalization, privacy, packaging** | | | |
| 6.1 | Review UI (completeness %, objects, weak-area thumbnails) | partial | `sample-app/.../ReviewActivity.kt`, `ReviewSheet.kt` (completeness %, weak walls; `weakWalls`), `RoomView.kt`; objects: "Found" list | Weak areas are listed as walls, not thumbnails (no thumbnail code found); completeness and objects are behind OFF flags (`guidance`, `detector`); the verdict + buttons + validation part is ON and device-tested (H29) |
| 6.2 | Face and screen blurring | partial | `android/capturekit/.../capture/Redactor.kt` (faces, fails closed), `privacy/Scrub.kt`, ADR 0021 | Faces only; screens (monitors, TVs) are not detected; ON but never device-tested (H14) |
| 6.3 | Scan Bundle v1.3.0 (MCAP, `keyframes/`, `camera.json`) | done | Current spec is **v1.4.0** (`capturekit/spec/scanbundle/SPEC.md`, additive over 1.3.0; ADR 0034); C++ MCAP writer/reader `capturekit/core/bundle/`; `ckit validate`; a walked scan validated PASS (DEVICE_TEST_LOG) | Version is 1.4.0, not 1.3.0; the one-zip archive (`ckit pack`, ADR 0034) is stage 1 of 2: the Android pack-at-Finish step is not built |
| 6.4 | SHA-256 manifest | done | `capturekit/core/bundle/finalize.cpp:84` (per-file sha256 in `manifest.json`), `core/util/sha256.cpp`; the verifier checks it (7.2) | None known |
| **7** | **Transport and ingestion** | | | |
| 7.1 | Resumable tus upload | Android-only | `android/capturekit/.../upload/TusUploader.kt` (one resumable upload per file, retry with backoff), `UploadWorker.kt`; iOS `ios/Sources/CaptureKit/Upload/` source only | Never run against a server from a phone (field flavour only; H16, H17); iOS uncompiled |
| 7.2 | Server verification (hashes, `t` monotonicity, channel completeness, pose continuity) | partial | Dev server only: `capturekit/dev-server/verifier/bundle_verify.py` (size + sha256, then `ckit validate semantic`: `NON_MONOTONIC_TIME`, `MISSING_CHANNEL`, `POSE_GAP`, `TIME_ZERO`), docker failure matrix 8/8 (STATUS.md phase 7). Ingest in `roomscan-recon`: `formats/scanbundle.py` reads **Scan Bundle v0.1 only** ([SCAN_BUNDLE.md](SCAN_BUNDLE.md)) | The backend cannot read v1.4.0 MCAP bundles; the dev-server verifier is not the production backend (job API: brief `backend-app-connection`, not approved); phone-side failure matrix not run |

## Stages 8 to 14: backend (Parts 3 and 4, this repo)

All backend numbers were measured on CPU; nothing here ever ran on an NVIDIA GPU
([heavy-compute/INVENTORY.md](heavy-compute/INVENTORY.md), runbook [GPU_RUNBOOK.md](heavy-compute/GPU_RUNBOOK.md)).
Inputs so far are public datasets (Replica, ETH3D, TUM, NYU), not real Scan Bundles; see 7.2.

| # | Feature | Status | Evidence | Gap |
|---|---|---|---|---|
| **8** | **Pose refinement and metric alignment** | | | |
| 8.1 | Undistort + INTER_AREA resize | done | `spatial/io/ingest.py:65` `_undistort_maps`, `:178` `cv2.INTER_AREA`; `--max-side` measured in [PROGRESS.md](../PROGRESS.md) (T-027) | Not run on a phone bundle |
| 8.2 | pycolmap SfM | done | `spatial/sfm/refine.py`; E6 pass 26/26 at 0.48 px ([PROGRESS.md](../PROGRESS.md)) | Intermittent registration (1 of ~9 runs 20/26, T-026); CPU wheel only here (`pycolmap-cuda12` untested, P2-01) |
| 8.3 | Sim(3) RANSAC scale from VIO | done | `spatial/sfm/refine.py:208` `pycolmap.estimate_sim3d_robust`, `spatial/geometry.py:24` `umeyama` | Priors come from datasets (`gt_noisy` simulates VIO noise); real device poses not tested |
| 8.4 | Gravity to -Z (+Z up) | done | `spatial/sfm/refine.py:240` (`rotation_aligning` gravity -> -Z); [INTERFACES.md](INTERFACES.md) §2 | Needs `gravity_world` in the manifest; tilt feedback is T-018 |
| **9** | **Depth and fusion** | | | |
| 9.1 | Depth tiers A / B / C | partial | Tier field `formats/scanbundle.py:87`, tier rules `:226`; sensor and monocular sources `spatial/depth/sources.py`; ablation R0 to R6 [PHASE_REPORTS/PHASE_3.md](PHASE_REPORTS/PHASE_3.md) | Tier B (device poses, no depth) and C (RGB only) run through monocular depth on public data; no real tiered bundle; ARKitScenes ablation P3-07 is GPU-batch work |
| 9.2 | Depth cleaning: bilateral, discontinuity mask, photometric consistency | partial | Discontinuity: `spatial/depth/masks.py` `edge_mask`; multi-view geometric consistency `spatial/depth/consistency.py`; temporal log-scale median only `spatial/depth/align.py:161` `smooth_scales` | No bilateral depth smoothing; consistency is geometric, not photometric; threshold dependence on baseline is T-016 |
| 9.3 | Open3D ScalableTSDF, 2 cm | done | `spatial/fusion/tsdf.py:34` `ScalableTSDFVolume`, 2 cm voxel in `TSDFParams` | CUDA VoxelBlockGrid path unverified (P3-08, Open3D CUDA only in the Linux wheel); Open3D 0.20 rejected (empty meshes) |
| **10** | **Structural extraction** | | | |
| 10.1 | RANSAC planes | done | `spatial/room/planes.py:114` `segment_plane`, `detect_planes` | Synthetic + Replica evidence only; ETH3D floor-perpendicular wall check open (T-020) |
| 10.2 | Wall-intersection floor polygon | partial | `spatial/room/planes.py` `floor_polygon`; `spatial/room/run.py` (records `floor_polygon_source`, falls back to a hull) | Replica room0 IoU re-run pending after the contour change (T-017) |
| 10.3 | Area, perimeter, wall lengths, ceiling height | done | `export/floorplan.py:92` `measurements` (`floor_area_m2`, `perimeter_m`, `wall_lengths_m`, `ceiling_height_m`) | `scale_confidence` is null today (T-019); no tape-measured rooms (T-013) |
| **11** | **Mesh** | | | |
| 11.1 | DensifyPointCloud | partial | `recon/dense.py`, `recon/openmvs.py` (docker `room-openmvs:2.4.0`) | ETH3D full-res run killed twice by out-of-memory on the 15 GB machine; F@5cm unmeasured (T-021, P7-02) |
| 11.2 | ReconstructMesh / Poisson | partial | `recon/dense.py` (OpenMVS `ReconstructMesh`; Poisson `poisson_depth=9` only as fallback without OpenMVS) | Same full-res run pending (P7-03) |
| 11.3 | RefineMesh | partial | `recon/dense.py` `refine=False` by default (slow on CPU); `--refine` in `recon/cli.py` | Code exists, never run (INVENTORY.md P7-03) |
| 11.4 | UV + texture (obj / mtl / glb) | partial | `recon/dense.py:6-7,56` `export_glb`, OpenMVS `TextureMesh`; held-out PSNR in `recon/evaluate.py` | Textured PSNR target >= 18 dB not yet measured at full res (T-021) |
| **12** | **Gaussian splatting** | | | |
| 12.1 | Depth-prior initialisation | GPU-unverified | `recon/splat/data.py` `init_gaussians` (fused depth cloud, falls back to COLMAP points); CPU test `tests/test_phase9_splat.py` | Trainer never run |
| 12.2 | gsplat CUDA, SH degree 3, Adam | GPU-unverified | `recon/splat/train.py` (`rasterization`, `SplatJob.sh_degree=3`); E4/E5 pending (P0-02) | Never executed on a GPU; first run compiles gsplat (JIT) |
| 12.3 | Densify and prune | GPU-unverified | `recon/splat/train.py:96` gsplat `DefaultStrategy` | Never executed |
| 12.4 | `splat/point_cloud.ply` | GPU-unverified | `recon/splat/train.py:171` `write_gaussian_ply` (layout round-trip tested on CPU, `tests/test_phase9_splat.py`); packaged by `recon/package.py` | Skipped (recorded, not faked) without CUDA; no compressed export (T-012) |
| **13** | **QA and rescan** | | | |
| 13.1 | Capture gates: registered >= 90 %, reprojection <= 1.0 px, angular spread | partial | `qa/thresholds.py` (`reg_ratio_pass` 0.95, `reproj_pass_px` 1.0, floor / wall coverage), `qa/gates.py`; per-cell viewing-ray spread inside coverage `qa/coverage.py` (`min_view_spread_deg` 5) | Registered-ratio pass is 0.95 (warn 0.80), not 0.90; no separate camera angular-spread gate |
| 13.2 | PSNR / SSIM / LPIPS on every 8th frame | GPU-unverified | Splat: `recon/splat/train.py:135-177` (PSNR, SSIM, LPIPS, held-out every 8th via `heldout_every=8`); mesh: `recon/evaluate.py` (PSNR, SSIM, no LPIPS; the pipeline passes `heldout_every=8` from `recon/cli.py` / `recon/package.py`) | Splat metrics never produced; mesh metrics have no LPIPS |
| 13.3 | `job_report.json` | done | `qa/cli.py` (`python -m qa.cli report`), `qa/gates.py`, `tests/test_qa.py` | Gates tuned on public data only |
| 13.4 | RescanRequest to the app | not built | `qa/` writes anchored `rescan_regions` into `job_report.json`; the RescanRequest type is only in the original spec ([specs/D-ScanQA.md](specs/D-ScanQA.md)) | Nothing sends it to the app; job API is brief `backend-app-connection` (not approved) |
| **14** | **Deliverables** | | | |
| 14.1 | `floorplan.dxf` (R2010 layers) | done | `export/floorplan.py:55` `write_dxf` (`ezdxf.new("R2010")`, layers FLOOR_OUTLINE, WALLS, ...) | Not opened in a CAD program |
| 14.2 | `floorplan.svg` | done | `export/floorplan.py:21` `write_svg` | None known |
| 14.3 | `measurements.json` | done | `export/cli.py:45`, `export/floorplan.py:92` | `scale_confidence` null (T-019) |
| 14.4 | `fused_cloud.laz` (RGB + normals) | partial | `export/pointcloud.py:13` `write_laz` (LAS point format 2: RGB, no normals) | LAZ carries no normals; E57 not built (T-012) |
| 14.5 | `room_shell.usda` / `.usdz` | partial | `export/usd.py:38` `write_usda` (text USD) | `.usdz` needs an external `usdzip` (T-012); no packaging in the repo |
| 14.6 | `mesh.glb` / `mesh.obj` | partial | `recon/dense.py` `export_glb`; `mesh/textured/mesh.obj` | Real OpenMVS output only on the ETH3D / Replica dev runs, never a full-res deliverable (11.1) |
| 14.7 | `point_cloud.ply` | GPU-unverified | Splat PLY: `recon/splat/train.py:171`; fused cloud `fusion/cloud.ply` via `spatial/fusion/tsdf.py` (done) | Splat PLY never produced; fused-cloud PLY is done |

## Open points from the audit

- The audit brief expected "verifier checks hashes only"; the code shows the dev-server verifier also runs the
  semantic validator (7.2). What stays true is that `roomscan-recon` itself ingests only Scan Bundle v0.1.
- The owner's stage 6.3 names v1.3.0; the spec in the tree is v1.4.0.
- `python -m recon.cli run` in INTERFACES.md and the router recipes does not work (T-030); not a stage feature.
