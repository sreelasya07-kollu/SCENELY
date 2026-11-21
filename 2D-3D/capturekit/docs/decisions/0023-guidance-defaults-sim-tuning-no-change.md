# 0023: Guidance defaults after the C4 simulator sweep: no change

Status: accepted (2026-11-17, under ADR 0018 delegation). Rule (queue Settled 9): change a GuideParams default only if `ckit guide-eval --seeds 3` (box/L/furniture) shows >= 10 % faster time-to-90 and no new unsafe targets. No candidate met both, so params.hpp/params.cpp are unchanged and no goldens were regenerated.
Method: baseline full matrix (planner/scripted/wander, 3 seeds, 450 s, compliance 0.85), then planner-only sweeps of single knobs and combinations. t90 = mean over 9 planner runs (3 rooms x 3 seeds), never-reached censored at 451 s. unsafe = ground-truth unsafe targets (engine count was 0 everywhere). Built from a snapshot of the working tree (guide_log reports info_prompts separately; instr/min excludes PROGRESS/KEEP_TURNING).

| params (override of default) | t90 mean s | box / L / furn | reached90 | cov@end | unsafe | instr/min |
|---|---|---|---|---|---|---|
| baseline | 401 | 333 / 420 / 451 | 4/9 | 0.887 | 0 | 14.5 |
| expire_s 20 (12) | 427 | 402 / 428 / 451 | 4/9 | 0.811 | 0 | 12.4 |
| sweep_after_s 6 (3) | 401 | 333 / 420 / 451 | 4/9 | 0.858 | 1 | 14.4 |
| min_gain 2 (4) | 401 | identical to baseline | 4/9 | 0.887 | 0 | 14.5 |
| dwell_s 2 (3) | 389 | 339 / 376 / 451 | 5/9 | 0.883 | 0 | 13.9 |
| hysteresis 1.15 (1.3) | 381 | 313 / 378 / 451 | 5/9 | 0.860 | 4 | 13.9 |
| min_gap_s 3 (2) | 374 | 277 / 396 / 451 | 5/9 | 0.905 | 0 | 13.9 |
| rotate_deg 30 (40) | 384 | 327 / 375 / 451 | 5/9 | 0.902 | 0 | 14.6 |
| min_gap_s 3 + rotate_deg 30 | 369 (-8 %) | 270 / 387 / 451 | 5/9 | 0.893 | 0 | 13.2 |
| + dwell_s 2 | 379 | 346 / 341 / 451 | 6/9 | 0.893 | 0 | 13.5 |
| reach_m 0.7, reach_yaw_deg 40 (0.5, 30) | 351 (-12 %) | 250 / 352 / 451 | 5/9 | 0.887 | 4 | 12.4 |
| reach_m 0.6 | 410 | 374 / 406 / 451 | 4/9 | 0.867 | 2 | 13.8 |

Baseline other policies (t90 box/L/furniture): scripted never reaches 0.9 (cov@end 0.22/0.44/0.12), wander 324/436/451 (3/3, 2/3, 0/3). The planner does not yet beat wander in the sim; furniture never reaches 0.9 for any policy or setting (451 censored), so the sim furniture room is capped by occlusion, not by guidance tuning. Instruction demand (13-16/min) stays above the 8/min speech budget in every setting; the Android SpeechScheduler is what holds the spoken rate down.
Closest candidates: reach_m 0.7 is 12 % faster but adds 4 unsafe targets (rejected by the rule); min_gap_s 3 + rotate_deg 30 is 8 % faster with no new unsafe targets (below the 10 % bar, within the noise of 3 seeds). Both are worth re-testing on real bundles (`ckit replay B --sink guide`), not by more sim sweeps: values are hypotheses until Gate 0 data.
