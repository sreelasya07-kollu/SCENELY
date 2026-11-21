# Quality metrics and keyframe selection (Phase 4)

Core: `core/include/capturekit/quality/quality.hpp`. Sink: `quality` (`ckit replay --sink quality`).
Config: `QualityConfig` (version `q1`), flat JSON overrides, `hash()` recorded in the manifest
(`capture_settings.quality_config_hash`) and in a `quality.QUALITY_CONFIG` event.

## Per-frame metrics (luma, downscaled to ~320 px wide)
sharpness (Laplacian variance), texture (Laplacian variance after a further 4x downscale), sharpness_norm
(ADR 0006), gyro blur risk = mean |w| over the exposure window x exposure x fx (px), clip_low (<=5),
clip_high (>=250), FAST-9 corners and 4x4-grid spread, tracking state.

## Score
| Reason | Hard reject | Soft penalty |
|---|---|---|
| TRACKING_LOST | state NOT_AVAILABLE | — |
| TRACKING_LIMITED | — | x0.6 |
| MOTION_BLUR | > 4.0 px | > 1.5 px, linear to x0.5 |
| BLUR / SOFT_FOCUS | textured and norm < 0.35 | norm < 0.6 |
| OVER/UNDEREXPOSED | clipped >= 40 % | >= 10 % |
| LOW_TEXTURE, POOR_SPREAD | never | x0.5 / x(0.5+spread) |
| RECALIBRATING | session only: tracking recovery active (ADR 0031), keyframe capture paused | — |

## Keyframe selector
quality gate -> min gap (200 ms after last keyframe) -> novelty (translation / scene depth >= 0.1,
depth = median sparse-point depth or 2 m default; or rotation >= 10 deg) -> 300 ms candidate window ->
best quality frame becomes the keyframe. Every frame gets one decision with reason codes
(NOT_NOVEL, MIN_GAP, NOT_BEST, DUPLICATE plus metric reasons) written to /frame_index.

Novelty is checked against every saved keyframe, not only the last one (issue #9, ADR 0033): a saved
keyframe covers a candidate when it is within translation / depth < trans_ratio AND rotation < rot_deg.
Covered by the last keyframe = NOT_NOVEL; covered by an older one (a revisit) = DUPLICATE, skipped (saved
photos are never replaced). A better frame inside the candidate window that a saved keyframe covers cannot
win it. The pose index is a ring of the newest 2048 keyframe poses (oldest evicted, no per-frame allocation).
On a tracking re-anchor (TRACKING_RESET, ADR 0031) the index is cleared when the drift exceeds the dedup thresholds.
"Why kept / skipped" for every frame = /frame_index `reasons` + metrics; no extra debug channel.

## Performance (desktop proxy)
`QualityPerf.DesktopProxyTiming`: 1.43 ms per 1920x1440 frame (Release, x86-64 dev machine, one
thread; target <= 3 ms, strict with `CK_PERF_STRICT=1`). `QualityPerf.NoHeapAllocationPerFrame` proves
zero allocations per frame after the first frame at a resolution. Device numbers: Phase 6 (needs phones).

## Tools
`ckit import-raw RAW OUT --select-keyframes [--config cfg.json]` keeps only selected keyframes.
`ckit quality-report BUNDLE... [--json out] [--no-sfm]` adds pycolmap registration rate of the selection.
Reports for the synthetic golden sessions: `docs/reports/quality_synth.json`.

## Reconstruction bench (`ckit recon-bench`)
`ckit recon-bench SCAN [--baseline SCAN] [--json OUT]` reconstructs a bundle folder offline (pycolmap,
CPU, 1 thread, seed 0) and prints a table; `--baseline` adds a baseline column and a delta column.
Archive input is not supported yet. JSON keys (read by later issues; `seconds` is printed but never
written to JSON, so two runs on one bundle give byte-identical files):

| key | meaning |
|---|---|
| bundle | folder name |
| package_bytes | sum of sizes of the files listed in manifest.json plus manifest.json itself (every file under the folder if there is no readable manifest); archive size once archive input lands |
| keyframes | keyframe images in the sampled list given to SfM (capped at 80 by the e2e sampler) |
| registered_pct | % of the sampled keyframes registered by free incremental SfM (no pose prior) |
| reproj_images | posed keyframes (all of them, not the sampled list) used by the fixed-pose triangulation |
| mean_reproj_px | mean reprojection error of pose-seeded (fixed-pose) triangulation over all `reproj_images` |
| sparse_points | 3D points from that triangulation (all posed keyframes) |
| coverage_yaw_pct | % of 36 yaw sectors (10 deg, world Y-up) that >= 1 posed keyframe of the sampled list looks into (poses only; proxy, no ground truth) |
| baseline, delta | only with `--baseline`: the baseline's keys and `report - baseline` per key |

Fixed-pose triangulation registers every posed image by construction, so `registered_pct` comes from
the free mapping. Table and exact commands: `docs/reports/recon_bench.md`.

Scope: `keyframes` and `registered_pct` use the sampled list (at most 80); `reproj_images`,
`mean_reproj_px` and `sparse_points` use all posed keyframes, so the two groups differ for long scans.
A bundle with fewer than 3 keyframes exits 1 with a message on stderr.
