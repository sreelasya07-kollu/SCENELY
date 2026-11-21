# Guidance evaluation on synthetic rooms (Phase 8)

Sources: `guide_eval_synth.json` (`ckit guide-eval --seeds 3 --max-s 450`, simulated walker, ADR 0011) and
`guide_replay_synth.json` (`ckit guide-eval build/golden/bundles/G*`, engine on recorded sessions). Params `gp1`.
All numbers are from a SIMULATED person on SYNTHETIC rooms: they show the logic works, not that people will follow it.

## Simulated walker: planner vs baselines (3 seeds each, 450 s horizon, 90 % needs both coverage and no censoring)
| Room | Policy | Final coverage | Median t90 | Reached 90 % |
|---|---|---|---|---|
| box | planner | 0.94 | 378 s | 3/3 |
| box | scripted (2 laps + spins, looped) | 0.22 | never | 0/3 |
| box | wander | 0.97 | 324 s | 3/3 |
| L | planner | 0.94 | 397 s | 3/3 |
| L | scripted | 0.44 | never | 0/3 |
| L | wander | 0.93 | 436 s | 2/3 |
| furniture | planner | 0.78 | never | 0/3 |
| furniture | scripted | 0.12 | never | 0/3 |
| furniture | wander | 0.84 | never | 0/3 |

## What this says
- **Safety held:** 0 unsafe targets in all 9 planner runs, judged against the TRUE room (a target must be walkable for a 0.25 m disc),
  and 0 on all 8 recorded sessions. Flap rate <= 2.5 target switches/min, instruction repetition median 0.08.
- **Honest coverage:** the engine's claimed coverage is within 9 points of ground truth (max gap 0.093), and always a little low, so it does not
  tell people they are done early.
- **Beats the scripted routine clearly** (final coverage 0.94 vs 0.22 box, 0.94 vs 0.44 L, 0.78 vs 0.12 furniture).
- **Does NOT beat a random walk on time-to-90 %:** wander is faster in box (324 s vs 378 s) and about equal in L. Reasons: the simulated random
  walker pays no reaction delay or compliance loss, and the planner spends time on instructions, turns and a deliberate pitch sweep. What the planner adds is
  not speed but (a) a stop signal (FINISH when true coverage is about 0.93; wander never knows it is done), (b) 6x less walking (11-21 m vs 55-80 m),
  (c) safety around furniture. The Phase 8 plan asked for "beats scripted baseline on median time-to-90": that holds on final coverage in every room
  but on time-to-90 in 2 of 3 rooms (furniture is censored for every policy). Treat the plan's criterion as MET ON COVERAGE, OPEN ON TIME.
- **Furniture room is not solved:** 0.73-0.84 after 450 s; most missing cells are floor behind and between blocks and wall segments hidden by the
  tall unit. The room-shell and missing-area work in Phase 9 is the intended fix; the planner also blocks itself there (11-19 blocked moves per run).

## Replay on the 8 synthetic golden sessions (a recorded walker, not following guidance)
Tier B on all; instructions 7-24 per session; repetition 0-0.09; unsafe targets 0. Coverage at the end of the recording is what that walk achieved (0.06-0.57), not
what guidance would reach.

## Not measured here (needs people and phones)
Human compliance and reaction time, instruction annoyance, speech budget, coverage vs manual labels on real sessions (Phase 8 acceptance asks for 2-3), claim vs reconstruction quality (Gate 0 in docs/STATUS.md).
