# 0033 Keyframe selection: novelty against all saved keyframes, DUPLICATE reason (issue #9)

- Novelty is checked against every saved keyframe, not only the last: a candidate within translation / depth < `trans_ratio` AND rotation < `rot_deg` of a saved keyframe is skipped (`NOT_NOVEL` = the last keyframe, new append-only bit 14 `DUPLICATE` = an older one, i.e. a revisit). A better frame inside the 300 ms window that a saved keyframe covers cannot win it. Saved photos are never replaced. Pose index = ring of the newest 2048 keyframe poses (brute force, no per-frame allocation). Android `StatusPill` ignores `DUPLICATE` like the other selector reasons.
- Tracking re-anchor (ADR 0031 TRACKING_RESET): saved poses are in the pre-reset frame, so the session calls `KeyframeSelector::reanchor(drift_m, drift_deg)`, which clears the index (and the last keyframe) when the drift exceeds the dedup thresholds (drift_m / depth >= `trans_ratio` or drift_deg >= `rot_deg`); a smaller drift keeps it. Without this a post-reset view at an old pose would be wrongly skipped as `DUPLICATE`.
- Tuning: no threshold change (q1 kept: `trans_ratio` 0.10, `rot_deg` 10, `window_ms` 300; config hash unchanged). Larger thresholds cut synthetic keyframes but lost yaw coverage (G1 window 500 ms: 61 -> 46 keyframes, coverage 69.4 -> 50.0 %; 0.12 / 12 deg: 53, 63.9 %). Synthetic sessions (5 Hz, no revisits) barely change; the gain is on real revisits.

| session (`ckit recon-bench`) | keyframes old -> new | registered_pct | coverage_yaw_pct (sampled list) | yaw coverage, all posed keyframes |
|---|---|---|---|---|
| G1 (`ckit synth G1 --seed 0` + `import-raw --select-keyframes`) | 61 -> 61 | 100.0 -> 100.0 | 69.44 -> 69.44 | 69.44 -> 69.44 |
| G3 | 31 -> 31 | 25.81 -> 25.81 | 16.67 -> 16.67 | 16.67 -> 16.67 |
| G4 | 108 -> 107 (bench samples 80) | 100.0 -> 100.0 | 72.22 -> 63.89 (sampler artifact: 80 of 107 vs 80 of 108) | 75.0 -> 75.0 |
| scan_20261117_215819 replay from /frame_index metrics (old replay reproduces 117 of 118 recorded keyframes) | 146 -> 121 (-17 %; 198 frames `DUPLICATE`) | — | — | — |
| same, SUBSET bench: the 78 new picks that have a saved JPEG vs the recorded bundle | 118 -> 78 | 98.75 -> 98.72 | 88.89 -> 91.67 | 91.67 -> 91.67 |

- Real-scan rows are a subset (43 of the 121 new picks were never saved as JPEG), not final proof; device re-walk pending. Replay baselines (G1/G3/G7, 4 s): no quality-sink difference, not regenerated; `docs/reports/quality_synth.json` regenerated (`ckit quality-report build/golden/bundles/G* --uniform`). Overlay golden `overlay_box_seed1.jsonl` regenerated: the sim uses the same selector, last sample completeness 0.0563 -> 0.0578, seen 0.5456 -> 0.5071.
