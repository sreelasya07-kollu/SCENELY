# PROGRESS: roomscan-recon

Room Scanner Part 3 (`spatial/`) + Part 4 (`recon/`). This machine: Intel Core Ultra 200V,
15 GB RAM (~3 GB free in practice), Intel Arc iGPU (**no CUDA**), CPU-only runs.
GPU/ARKitScenes work is listed under "Pending for the GPU test machine".

| Phase | Scope | Status |
|---|---|---|
| 0 | Environment, pinned deps, Docker tools, env acceptance tests | done, except GPU tests (pending) |
| 1 | Dataset adapters, keyframe selection → workspace | done (Replica, TUM, ETH3D); Scan Bundle adapter blocked (no spec) |
| 2 | Pose refinement → metric, gravity-aligned `sparse/0` | done; depth-based scale added; global mapper experimental (documented miss) |
| 3 | Depth sources (sensor, OpenMVS, hybrid, mono), alignment, masks, consistency, TSDF fusion | done; mono is fallback only (documented) |
| 4 | Fusion evaluation | synthetic Chamfer + Replica done; ETH3D official-tool score see Phase 8 |
| 5 | Planes + room shell (box and L-shaped rooms) | done |
| 6 | SpatialMap writer/reader, schemas, `spatial.cli run` | done |
| 7 | Part 4 sparse hand-over to OpenMVS | done |
| 8 | OpenMVS dense + mesh + texture, ETH3D scoring, held-out PSNR | implemented; ETH3D targets see "Phase 8 evidence" |
| 9 | Gaussian-splat worker | written, **never executed (needs CUDA)**; CPU parts tested |
| 10 | Reconstruction packaging, manifest, `recon.cli run` | done; splat recorded as `skipped` without CUDA |

Reports with the exact measured numbers: `docs/PHASE_REPORTS/` (regenerate with
`python scripts/render_phase_reports.py`). Plan: `docs/PLAN.md`. Formats: `docs/INTERFACES.md`.

## Phase 0 evidence (2026-11-12, CPU)

| Test | Result |
|---|---|
| E1 versions | pass: torch 2.14.1+cpu, gsplat 1.5.3, open3d 0.19.0, pycolmap 4.2.1 |
| E2 RANSAC plane | pass: normal error < 0.01°, d = −0.5001, 5009 inliers |
| E3 ScalableTSDF sphere (8 views) | pass: radius 0.50019 m (GT 0.5), std 2.4 mm |
| E6 pycolmap SfM, ETH3D office 26 imgs @1555 px (/4, INTER_AREA) | pass 2026-11-19 (3 runs): 26/26 registered in all runs, mean reproj 0.484-0.489 px; 37-48 s per run. CPU, known PINHOLE K fixed, INTER_AREA /4. 3/3 runs pass 26/26; intermittency (20/26 on 2026-11-12) per PROGRESS.md:61 is tracked by sfm-repeat-gate (T-026); issue #1 |
| E4/E5 gsplat | pending (CUDA) |
| E7 OpenMVS image | pass: all 5 apps report `OpenMVS x64 v2.4.0`, no loader errors; image 594 MB |

## Phase 1 evidence (2026-11-13, CPU; `runs/test_results/phase1_*.json`)

| Check | Result |
|---|---|
| ETH3D pose convention: reproject GT points with converted poses | median 0.84 px, p95 3.05 px (11,687 obs) |
| Replica pose convention: ray-cast GT mesh vs rendered depth (10 frames) | median abs diff 0.038 mm (= depth quantisation) |
| Replica gravity: floor-plane tilt vs +Z | 0.26° → gravity = −Z confirmed |
| TUM rgb↔depth association | max Δt 17.2 ms (≤ 20 ms) |
| TUM gravity from accelerometer (motion-compensated) | spread 2.88° over 1468 samples; axis map diag(−1,−1,1); 4.29° from mocap Z |
| Simulated VIO prior (light) | yaw-only drift, grows with path |

## Phase 2 evidence (2026-11-13, CPU; `runs/test_results/phase2_*.json`)

| Dataset (frames, prior) | Registered | Reproj | ATE SE(3) prior → refined | Scale err | Rot err | Time / peak RAM |
|---|---|---|---|---|---|---|
| ETH3D office (26, none: SfM only, Sim(3) eval) | 26/26 | 0.47 px | median 0.42 cm (Sim3) | n/a | 0.16° | 17.6 s / 4.3 GB |
| TUM fr1/xyz (60, vio_large) | 60/60 | 0.89 px | 3.87 → **1.13 cm** (−71 %) | 0.10 % | 1.83°* | 47.6 s / 1.4 GB |
| Replica room0 (80, vio_small) | 80/80 | 0.46 px | 4.67 → **0.63 cm** (−87 %) | 0.39 % | 0.13° | 17.8 s / 1.2 GB |
| Replica room0 (80, vio_large) | 80/80 | 0.46 px | 17.57 → 2.63 cm (−85 %) **MISS > 2 cm** | 2.35 % | 0.14° | — |

\* TUM GT orientation carries a camera↔mocap offset: SfM rotations match ETH3D's laser-registered
GT to 0.16° and Replica's exact GT to 0.13°, so TUM is judged on translation only.

Known issues:
- **Replica vio_large miss**: the shape is right (Sim(3) ATE 0.49 cm), but the scale comes from priors
  drifting 3 %/m over a 23 m path. Kept as an xfail with the measured cause; the fix is depth-based scale (Phase 3).
- **ETH3D registration is intermittent**: 1 of ~9 runs registered only 20/26 (multithreaded COLMAP
  isn't bit-deterministic even with fixed seeds). Mitigated by seeding and `multiple_models=True` (keep the largest).
  Repeat runs: ATE 0.91–1.65 cm, rot 0.16–0.28°.
  T-026 (issue #4) gate, `pytest tests/test_phase2.py -k eth3d_sfm_repeat -m heavy`
  (`runs/test_results/phase2_eth3d_repeat.json`; seeds 0–4, multithreaded, 2026-11-19, CPU):
  registered min **26/26**, median 26/26, 5/5 runs full; reproj 0.47–0.49 px. Seeds 0 and 2 also
  produced a secondary model (sizes [26, 3] and [26, 6]); the largest is kept, and the SpatialMap
  quality warnings now flag any split ("SfM split into k models ...; largest model has N/M frames").
  So 2/5 full (26/26) runs also carry a small side model and get this warning; with N = M it is
  benign. The test asserts no failed run and min ≥ 0.95 × n.

T-027 (issue #3) pre-resize measurement, `scripts/heavy/preresize_measure.py`
(`runs/test_results/preresize_<scene>.json`; 5 seeded multithreaded `refine` runs per config, CPU,
2026-11-19). (a) = COLMAP resizes internally to `max_image_size`; (b) = `ingest --max-side` INTER_AREA
pre-resize to the same long side, same `refine`. ATE = Sim(3) to GT; min registered / median reproj /
median ATE over the 5 runs. Reproj is measured in each config's own pixel scale, so it is not
comparable across (a) and (b); the decision uses registered and ATE. In the ETH3D proxy, (a) is INTER_AREA /2 in ingest
then COLMAP's internal resize to 1600, while (b) is a single INTER_AREA step to 1600; on Replica (a) is COLMAP's resize only.

| Scene (ratio) | (a) COLMAP internal | (b) INTER_AREA pre-resize | (b) no worse? |
|---|---|---|---|
| ETH3D office proxy, 26 imgs (3110 px -> 1600, ratio 1.94) | 26/26 min; 0.599 px; ATE 2.24 mm, rot 0.115 deg | 26/26 min; 0.480 px; ATE 3.20 mm, rot 0.191 deg | no (ATE +42 %) |
| Replica room0, 80 frames, stride 5 (1200x680 -> 1024, ratio 1.17) | 80/80 min; 0.462 px; ATE 0.66 mm, rot 0.027 deg | 80/80 min; 0.436 px; ATE 0.88 mm, rot 0.025 deg | no (ATE +35 %) |
| TUM fr1/xyz (640x480, ratio 1) | n/a: below `max_image_size`, (a) and (b) are identical; not run | n/a | n/a |
| Scan Bundle (real phone frames) | BLOCKED: no real capture exists (synthetic bundles are invalid for SfM) | BLOCKED | BLOCKED |

Decision: default unchanged (`refine`/`pipeline` keep COLMAP's internal resize; `--max-side` stays
opt-in). (b) is not no-worse on ATE in either scene, though all differences are sub-centimetre
(0.2-1 mm) and well inside the 2 cm threshold; with 5 runs per config this is a measured
difference between configs, not proof of a general ranking. Issue #3 stays open: it cannot be
closed without a real Scan Bundle.

## Phase 5 evidence (2026-11-14, CPU; `runs/test_results/phase5_*.json`, `pytest tests/test_phase5.py`)

| Check | Result (target) |
|---|---|
| Synthetic room 4×3.5×2.6 m + table + cabinet, 40 ray-cast views, σ 3 mm, TSDF 2 cm | max normal err 0.23° (≤ 2°), max offset 4.3 mm (≤ 2 cm), ceiling height err 0.02 mm (≤ 2 cm), floor area err 0.34 % (≤ 3 %), max corner err 9.6 mm; 4 walls, cabinet/table rejected; 1.7 s |
| Determinism: rerun on same cloud | planes.json, room.json byte-identical |
| Replica room0 R1 cloud (sensor depth, refined poses) | 9 walls, wall⟂floor max 0.41° (≤ 3°); ceiling 2.7293 m vs 2.7279 m from GT mesh; floor area 35.38 vs 35.32 m² (0.17 %); 7.9 s, 0.8 GB peak |
| ETH3D office floor⟂wall | **not run**: SfM-only workspace is not gravity-aligned or metric; `room` CLI refuses it. Mono Phase 3 cloud there is also too sparse (0.28 % valid pixels) |

Known issues:
- Replica room0 refined frame is tilted 1.74° (floor normal vs +Z): a Phase 2 gravity residual. Ceiling height uses perpendicular plane distance, so it is unaffected.
- Floor polygon: recesses/bays are modelled by the wall-snapped footprint contour (used when it adds a blob wider than 0.20 m to the dominant-wall polygon, or when that polygon is invalid). Verified on synthetic L and recess rooms only; Replica room0 (two bays) was NOT re-run after this change, so its polygon IoU vs the GT mesh (heavy test, target >= 0.95) is unverified. The GT-mesh comparison is self-consistency, not an independent layout GT.
- `scale_confidence` is null (no estimator yet).

## Phase 3-7 evidence (2026-11-14, CPU)

| Check | Result (target) |
|---|---|
| OpenMVS depth vs Kinect, TUM xyz, conf ≥ 0.5 | AbsRel 0.070 (≤ 0.10), δ<1.25 0.935 (≥ 0.90), 63 % pixels kept. Unfiltered: AbsRel 0.130, **misses** |
| Replica room0 F@5cm: sensor R1 / OpenMVS R7 / hybrid R8 / best mono R5 | 0.946 / 0.617 / 0.610 / 0.338 |
| Scale recovery of a model deliberately scaled ×0.37 | TUM 1.3 %, Replica 0.7 % (≤ 2 %) |
| Replica vio_large with `--depth-scale` | ATE SE3 2.63 → 0.47 cm, scale error 2.35 → 0.05 % (the old miss stays as xfail without the flag) |
| Synthetic room TSDF Chamfer-L1 | 0.98 cm (≤ 1 cm): voxel-limited, close to the bar |
| L-shaped synthetic room (bay case) | area error 0.46 %, max corner error 4.5 cm before wall-line snapping, 1.0 cm after, 6 walls, polygon from footprint contour |
| Box + 0.8x0.4 m recess synthetic room (2.8 % of area) | area error 0.26 %, max corner error 0.93 cm, 7 walls, 8-corner polygon from footprint contour (old IoU gate dropped it) |
| TUM desk keyframes (99 of 594) | max gap 0.244 m / 13.1° (≤ 0.3 m / 15°); mean sharpness 901 vs 212 for uniform sampling |
| SpatialMap end-to-end Replica (one function call) | 40/40 registered, ceiling 2.7276 m (GT mesh 2.7279), all hashes verify, ~20 s of stages |
| Downstream determinism (24 files) | byte-identical across two runs |
| P7 ETH3D sparse | 26/26 registered, 0.466 px, OpenMVS loads 26 images + 1470 points |
| ETH3D scoring tool E8 | self-score F = 1.0; a 20 cm shifted copy 0.20 @1 cm / 0.42 @5 cm |

## Decisions and findings log

- **ETH3D tool pitfall (found 2026-11-14):** it silently scores 0 on Open3D-written PLYs (double
  coordinates / normals / colours). `eval/eth3d.py` converts to a float32 x,y,z PLY first. The
  first full-scan self-test (16 min) returned 0 because of this; tiny cropped-scan tests found it.
- **OpenMVS texture OBJ uses a v-down convention** (95 % of face centroids on black texels if
  sampled v-up, 24 % v-down): `recon/render.py` has `v_up`; `recon.evaluate` uses `v_up=False`.
  The GLB written by trimesh inherits the OBJ's uv as parsed: **not verified in a standard viewer**.
- **pycolmap 4.x:** images are deregistered through `deregister_frame`; the global mapper
  (`refine --mapper global`) registers 26/26 on ETH3D office but returns a wrong model (3.6 m
  residual vs incremental): experimental, incremental stays default.
- **OpenMVS licence is AGPL-3.0:** only called as a separate process (docker); see docs/MODELS.md.
- The benchmark workspaces store absolute GT paths from before the repo move;
  `eval.gt.resolve_gt_path` re-roots them under this repo's `data/`.
- Docker shares the 110 GB volume: the PCL-based ETH3D image is 4.2 GB. At 98 % disk usage keep
  runs small; `docker builder prune` would free ~8 GB of build cache (not done: it also holds
  other projects' layers).

- **Replica meshes have quad faces**; open3d 0.19's PLY reader silently keeps only triangles
  (16,516 of 953,647 faces). `eval/gt.py` loads with plyfile and splits quads.
- Phase 2 `prior_mode`: `sim3` (pure SfM, then robust Sim(3) to priors) is the default; `ba`
  (prior positions inside BA) gave identical accuracy on TUM (ATE 1.12 vs 1.14 cm) and is slower.
- Integer downscale uses the pixel-centre rule `c' = (c + 0.5)/D − 0.5` (light test).

- open3d **0.20.0 rejected**: `ScalableTSDFVolume` and tensor `VoxelBlockGrid` return 0 vertices
  (plane at 2 m, 8-view sphere); `UniformTSDFVolume` works. 0.19.0 works with numpy 2.5.4.
- nerfstudio 1.1.5 pins gsplat 1.4.0 + opencv-headless 4.10, so it's excluded; gsplat used directly.
- OpenMVS v2.4.0 needs OpenCV ≥ 4.10 → Ubuntu 26.04 base; two source patches (Boost.System
  CMake component, `IMWRITE_JPEGXL_QUALITY` constant). See `docker/openmvs/Dockerfile`.
- Depth-Anything-V2 **Small = Apache-2.0** (default); Base/Large = CC-BY-NC-4.0 (opt-in only).
- Phase 5 wall rule: vertical, ≥ 0.8 m², must reach within 0.35 m of the ceiling. Without the
  ceiling rule the synthetic cabinet front was labelled a wall and shifted a corner 0.4 m.
- Phase 5 horizontal-plane height = median inlier z (z at x=y=0 picked an 8.7°-tilted patch as floor on the Replica GT mesh).
- `tests/test_phase3_heavy.py` had two orphan lines (syntax error that broke collection); removed, no assertion changed.
- No `/usr/bin/time` on this machine: peak RAM is measured with psutil sampling.

## Pending for the GPU test machine

- E4/E5 gsplat tests; all `pytest -m gpu` tests (CUDA fusion, GPU inference parity).
- All `pytest -m arkit` tests (ARKitScenes: R0–R6 on real LiDAR, Step D on ARKitScenes).
- (E6 full-res rerun dropped: E6 now registers 26/26 at /4 on CPU, issue #1.)
