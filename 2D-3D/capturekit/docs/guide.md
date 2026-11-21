# GuideMind (Phase 8): coverage, planner, instructions

Core: `core/include/capturekit/guide/` (deterministic, no clock, no I/O). Stages, each with unit tests in `core/tests/guide_test.cpp`:

| Stage | File | What it does |
|---|---|---|
| Params | params.hpp | every threshold, versioned, hash recorded in the manifest (`guide_config_hash`) |
| LiveMap | live_map.hpp | AR planes: updates replace, duplicates merge, floor/ceiling levels, room extents |
| Layout (ADR 0026) | room_shell.hpp, layout.hpp | runs at every understanding level, refreshed in `update()` at most once per event-second (event `t_ns`; it may lag the map, points and nav by up to 1 s; `report_json` always recomputes it on a copy): wall LINES (Manhattan axis + inward side + offset cluster, `merge_off` 0.15 m) instead of planes; collinear fragments merge across gaps <= 1 m (all member offsets within `merge_off`, not just the running mean), and across gaps up to 3.5 m when >= 60 % of the gap is explained by obstacles in front of it or wall points on the line (and no perpendicular wall crosses it); a plane-less side is inferred from sparse points (+ floor edge) beyond the outline; ids `W<n>` follow the line (tracks), smallest number wins, never reused; spans o/b/m per wall. LiveMap aliases a SUBSUMED plane (stale >= 2 s and >= 70 % inside a parallel same-offset plane that was updated later) to its subsumer; a later record of it that reaches > 5 cm beyond the subsumer is united into it (not dropped) |
| Coverage | coverage.hpp | per-plane 10 cm cells: qualifying views, ray spread, range, sharpness; sufficient = 3 views + 15 deg; occluded-forever cells drop out |
| NavGrid | nav_grid.hpp | 2D occupancy: free = traversed or carved by sight rays or seen floor; obstacles from points 0.2-1.8 m; target needs whole body disc known free |
| Planner | planner.hpp | next-best-view: lattice x headings x pitches, score = marginal gain / (path + turn + safety + instruction overhead), overlap constraint, hysteresis 1.3, discovery looks for a missing ceiling/floor, rule-based fallbacks (sweep, walk to unseen area, finish) |
| Steering (Phase 9 step 8) | steer.hpp, planner.cpp, engine.cpp | only with `guide.understanding >= 2` (default 0; 1 = step-5 behaviour, unchanged): the engine owns a RoomShell, GapFinder and virtual coverage grids (refreshed at most once per event-second) and hands MissingWall / UnseenCorner / Occluded gaps to the planner as targets: a viewpoint 1.2-3.5 m from the gap point with line of sight (`NavGrid::clear`), score `gap_gain * pri / (path + turn + overhead)`. Also a minimum hop (a target is within `reach_m` or >= 1 m away) and a 0.6 m clearance from every non-known-free cell, both with fallback to the unfiltered best. A gap stood at twice without closing is given up on; an open gap defers FINISH (only gap views are considered once coverage >= 0.9, none reachable -> FINISH). ADR 0027 (pending, real-room-fix T2; ADR 0025 is the device-bundle fixes) |
| Instructions | instruction.hpp | fixed vocabulary, egocentric text (positive yaw = left), cooldowns, 2 s minimum gap, priority interrupts (tracking loss, blur), lifecycle (issued -> completed / expired / superseded) |
| Log | guide_log.hpp | `guidance_log.json`: instructions, time-to-compliance, coverage delta, coverage series |

Vocabulary: SLOW_DOWN, HOLD_STILL, RELOCALIZE, MOVE_TO, ROTATE_TOWARD, TILT_UP, TILT_DOWN, STEP_BACK, SWEEP, MORE_LIGHT, AIM_TEXTURED, RECALIBRATE, FINISH, plus two
priority-1 info prompts PROGRESS and KEEP_TURNING (templates in `instruction.cpp`, message ids are the translation keys; every short
spoken variant is <= 8 words, tested). Each id has 2-3 phrasings; phrasing = (instruction id - 1) mod count, so it is deterministic and
the first instruction always uses phrasing 0. `{m_unit}` is plural-aware ("1 meter", "0.5 meters", "2 meters"). PROGRESS speaks once each
at 25 / 50 / 75 % completeness (a jump speaks only the highest; suppressed while the plan is Finish, pending thresholds resume afterwards); KEEP_TURNING speaks at 100 and 200 degrees turned
during a SWEEP; both are spaced >= 6 s apart (`kInfoGapS`, not a GuideParams field so existing config hashes are unchanged). The guide log counts them as `info_prompts`, separate from `instructions`, `by_state` and `median_time_to_compliance_s`.

Gap steering (`understanding >= 2`): while the target is a gap view, MOVE_TO / ROTATE_TOWARD use message ids `gap.move` ("Walk ahead to see the door wall.") and `gap.turn` ("Turn left to see the door wall.") with the gap's landmark phrase (`{why}`, from LandmarkLabeler, neutral wording because a relative phrase would be stale); a rendering over 8 words falls back to `move.to` / `rotate.to`. Instruction types, cooldowns and lifecycle are unchanged.

Tracking recovery (issue #1, ADR 0031, `recovery.hpp`): tracking not NORMAL for >= 2 s (ARCore PAUSED incl. INSUFFICIENT_FEATURES, or NOT_AVAILABLE) starts recovery: RECALIBRATE ("Turn your phone slowly in a small circle.", priority 3, `overlay_hint` "recalibrate") is the only prompt (RELOCALIZE after a long NOT_AVAILABLE loss), active guidance is superseded, planning is frozen and keyframes do not count as coverage; the session marks frames `RECALIBRATING` (hard reject: no keyframe saved). It ends after >= 1 s of NORMAL tracking with a steady gyro (or 4 s of NORMAL tracking): the engine re-anchors (motion estimates reset, immediate replan) and RECALIBRATE completes. Shell events `tracking_lost` / `tracking_reset`; `/events` TRACKING_LOST / TRACKING_RESET (`drift_m`, `drift_deg`, `lost_s`); overlay `recalibrating:true` + `why.recalibrating`; report `recovery` {losses, resets, max_drift_m, active} only after a loss.

Tracking reason (pose `tracking_reason`, only while tracking is LIMITED): EXCESSIVE_MOTION -> SLOW_DOWN (the reason path ignores the turning-on-request gate; only the blur path keeps it), INSUFFICIENT_LIGHT -> MORE_LIGHT, INSUFFICIENT_FEATURES -> AIM_TEXTURED ("Aim at a textured wall", priority 3, completes when the reason clears); other reasons add nothing.

Where it runs: `GuideEngine` inside the capture `Session` (instructions go out as `{"type":"instruction",...}` events via
`ck_poll_events` and as `/events` GUIDE_INSTRUCTION records; the log is written into the bundle at finalize; the planner rate follows the
governor's `ml_rate_scale`), and as the `guide` replay sink (`ckit replay B --sink guide`, `ckit guide-eval B`).
Input tiers: B (planes + sparse points) works today, C (pose only) falls back to SWEEP; tier A (depth) is not wired.

Report (`GuideEngine::report_json`, the `guide` replay sink output) v3 additions (ADR 0026), always present:
`layout` = `{walls, closed, blocked_m}` (layout walls with evidence, the `shell_closed` rule, total metres of blocked spans) and
`timeline` = `[{t_s, completeness, walls, prompts}, ...]`, one entry every 5 s of event time from the first pose (t_s seconds since
it, completeness as in `coverage`, layout wall count, prompts = cumulative instructions issued so far, all types), at most 720 entries.

## Evaluation
`ckit guide-eval --seeds 3 --max-s 450 --json docs/reports/guide_eval_synth.json` (planner vs scripted vs wander, 3 rooms, see
ADR 0011). Metrics: coverage at the horizon, time to 80/90 %, instructions, repetition rate, target switches per minute, unsafe
targets against the true room, claimed-vs-true coverage gap. Results: `docs/reports/guide_eval_synth.md`.

## Budgets and limits
Average step 1-2 ms (engine + simulator ground truth, `GuideSim.AverageStepWithinBudget`, budget 10 ms); a replan costs about 70 ms every
0.5 s, so the engine runs on the session worker, never on an AR callback.
Known limits: only detected planes are covered (Phase 9 adds the room shell and missing-area finder); no depth tier; obstacles come from
sparse points (a dilated 3x3 neighbourhood closes gaps); a person is modelled, not measured; English only.

## Overlay event (glanceable "what the app understands")
`GuideEngine::overlay(t_ns)` (`core/include/capturekit/guide/overlay.hpp`) builds an `OverlayModel`; `Session::guide_tick` emits it as a
**non-critical** event every 500 ms of event time (dropped and counted if the outbound queue is full; not written to the bundle; ADR 0013).
No `capturekit.h` change. Flat JSON, sorted keys, always under 4 KB (tested), one line per event:

| Field | Meaning |
|---|---|
| `type` ("overlay"), `t_ns` | event type, event time |
| `completeness`, `seen` | 0..1, sufficient / seen fraction of valid plane cells |
| `tracking` | 1 normal, 2 limited, 3 not available |
| `mode` | `sweep` \| `target` \| `finish` |
| `wall_found`, `floor_found`, `ceiling_found` | map flags: any wall / floor / ceiling plane in the live map |
| `walls` | v3 (ADR 0026): number of LAYOUT walls with evidence (a wall line built from one or more planes, or a plane-less wall inferred from sparse points + floor edge). Hypothesised sides of the outline do not count. This is the checklist's "Walls N" (v2: wall plane count) |
| `ceiling_seen` | v3: a ceiling plane was found OR a keyframe looked up by at least `pitch_up_deg` (ceiling is optional for completeness; reported separately) |
| `user_x`, `user_z`, `user_yaw_deg` | user position (m) and heading (positive = left) |
| `has_target`, `target_x`, `target_z` | current plan target (only while `mode` is `target`) |
| `why_id`, `why_text` | one reason, rendered by the core catalog (<= 8 words, English): sweep, tracking lost / weak, moving too fast, too dark, left/right/ahead/behind wall not scanned yet, ceiling/floor not seen yet, scan complete, keep scanning |
| `surfaces` | v3: LAYOUT walls (not planes), ONE string `x0,z0,x1,z1,pct,id;...` in outline order (world metres; endpoints = outline corners when the outline is closed; pct = % of the cells of the wall's member planes seen, 0 for a plane-less wall unless understanding >= 2 gives it a virtual grid; id = n of wall `W<n>`: the smallest first-seen plane number of the line, kept across plane merges / re-ids, never reused; a line whose candidates are all taken gets a fresh number from 100001 up; ids print within +-999999; id = -k for a plane-less inferred wall `I<k>`), at most 12, including hypothesised sides. v1 had 5 fields (no id); parsers accept 5 or 6 |
| `spans` | v3, always present (`""` when no wall): ONE string `id,x0,z0,x1,z1,state;...` (id = the `surfaces` id of its wall; state `o` observed = a wall plane or wall points there, `b` blocked = obstacles / furniture within 0.25-1.2 m in front of it (never demanded), `m` missing = nothing seen yet). Each wall is cut into spans of at least 0.3 m along its length, at most 24 spans in total, shared fairly per wall (`limit_spans`: equal quota per wall; an over-quota wall merges its shortest non-blocked span into a neighbour, so every wall keeps its full length and its blocked spans) |
| `yaw_mask` | integer 0..4095 (overlay v2, ADR 0022): bit i set = a keyframe looked along heading [30i, 30i+30) deg (yaw positive = left, 0 = world +z). Keyframes looking within 20 deg of straight up/down are ignored. Moves with zero planes; absent in v1 |
| `objects` | Phase 9, only with `guide.understanding` on and at least one published object (else the key is absent, flag-off overlays are unchanged): ONE string `id,cls,x,z,w,d,yaw_deg,h;...` (world metres; cls = core class name such as `chair`; box centre (x,z), footprint w x d, yaw_deg 0..89, height h), at most 12 objects, ordered by id. Objects come from recorded detections fed through `GuideEngine::on_detections` (live session and `ckit replay --sink guide` alike) |
| `openings` | Phase 9 step 8, only with `guide.understanding >= 2` and at least one door / window on a shell wall (else absent): ONE string `kind,wall,x0,z0,x1,z1,y0,y1;...` (kind `door` \| `window`, wall id such as `W1` or empty, footprint segment (x0,z0)-(x1,z1) in world metres, y0..y1 height above the floor), at most 6 |
| `shell`, `shell_closed` | v3, always present at every understanding level: the live room outline (RoomShell layout), ONE string `x,z;...` of the corners in order (at most 12; `""` while there is no outline); `shell_closed` = the outline is a closed polygon AND every wall of it has evidence (observed planes or inferred from points); a hypothesised side keeps it false. (v2: only with understanding >= 2) |
| `gaps`, `gap_why_id`, `gap_why_text` | same flag; expected-but-unseen areas, highest priority first, ONE string `type,x,z,pri;...` (type `missing_wall` \| `unseen_corner` \| `unseen_ceiling` \| `unseen_floor` \| `occluded` \| `weak`; x,z = centre in metres, pri 0..1), at most 4; `gap_why_id` = `gap.<type>` and `gap_why_text` = the landmark phrase (<= 8 words, e.g. "the door wall", "behind the sofa") of gap #1. Absent while there is no gap |

Golden: `core/tests/golden/overlay_box_seed1.jsonl` (sim `box`, seed 1, 60 s, one snapshot per 5 s). Regenerate with
`CK_UPDATE_GOLDEN=1 capturekit_core_tests --gtest_filter='Overlay.Golden*'` and review the diff.
