# Understanding step 7: gap recall and false-gap rate (SYNTHETIC)

Gate 0 (docs/STATUS.md section 6): every number below comes from the simulator (`Understanding.SimGapRecallAndFalseGapTable`),
never from a real room. All thresholds are HYPOTHESES to be re-tuned on real bundles. Nothing here steers the planner yet
(step 8 integrates behind the default-OFF flag).

## What is measured
- Run: planner policy, `hold_level`, `view_points`, `guide.understanding=1`, detector oracle on (only "objects" has classed blocks),
  rooms box / L / objects / door_window x seeds 1-3, 90 s, checkpoint every 15 s (5 per run, 60 per table).
- Shadow stages (RoomShell + GapFinder + virtual coverage grids) run next to the engine; they never feed it
  (`SimGapHarnessIsInertAndDeterministic`: report without the block is byte-identical to a run without the harness).
- Truth (sim ground truth at each checkpoint): hidden WALL = true wall with <= 10 % of cells seen; hidden CORNER = vertex whose
  0.8 m wall neighbourhood is <= 10 % seen while both adjacent walls are not hidden; hidden BLOCK = floor ring (0.6 m) around a
  classed block < 30 % seen; CEILING / FLOOR = surface <= 10 % seen. Found = a gap of the matching type within 0.8 m (corner, wall
  centre to wall segment), rect-to-block <= 0.6 m, or any gap of that type (ceiling / floor).
- False gap = the true region was well seen (>= 50 % seen; Weak: >= 70 % sufficient), or a MissingWall farther than 1 m from every true wall.
- Seen = in a keyframe frustum (Coverage rule); a hidden region that no gap type can express with the shell at that time counts as missed.

## Result with the shipped defaults (`min_observed_walls = 3`, `corner_unseen 0.45`, `corner_max 1.5`, `looked_frac 0.5`)
| hidden region | truth | found | recall |
|---|---|---|---|
| wall | 77 | 1 | 0.01 |
| corner | 8 | 0 | 0.00 |
| block (behind / beside classed furniture) | 58 | 8 | 0.14 |
| ceiling | 22 | 7 | 0.32 |
| floor | 41 | 31 | 0.76 |
| all | 206 | 47 | 0.23 |

| gap type | gaps | false | false rate |
|---|---|---|---|
| missing_wall | 6 | 4 | 0.67 |
| unseen_corner | 5 | 2 | 0.40 |
| unseen_ceiling | 9 | 0 | 0 |
| unseen_floor | 31 | 0 | 0 |
| occluded | 6 | 0 | 0 |
| weak | 96 | 2 | 0.02 |
| all | 153 | 8 | 0.05 |

## Trade-off found (same runs, `min_observed_walls` 1 = no requirement)
| setting | recall (all) | wall recall | false-gap rate | missing_wall gaps (false) |
|---|---|---|---|---|
| 1 (first measurement) | 0.30 (62/206) | 0.19 (15/77) | 0.27 (60/224, incl. phantom corners) | 70 (50) |
| 1, `corner_max` 1.5 | 0.30 (61/206) | 0.19 | 0.25 (54/217) | 70 (50) |
| 3 (shipped) | 0.23 (47/206) | 0.01 (1/77) | 0.05 (8/153) | 6 (4) |

Reading: 48 of the 50 false MissingWall gaps sat more than 1 m from any true wall. With one or two observed walls the shell
rectangle ends where the partial plane extents end (ARCore-style growing rectangles), so the inferred side is a phantom wall.
Requiring three observed walls removes them but also removes nearly all hidden-wall recall: the shell cannot name a wall it
cannot place. UnseenCorner phantom corners (L room bounding rectangle) are cut by `corner_max`. Hidden floor is found well
(a floor plane is rarely present early); ceiling recall is limited by `hold_level` walkers never looking up (true hidden, correctly
reported). Block recall is low: an Occluded gap needs a lifted object (detector oracle, only the "objects" room has classed blocks; the other rooms have none), and lifting takes several keyframes of a block.

## Follow-ups (not done here)
- Wall recall with few observed walls needs a different cue than the shell rectangle (e.g. camera-bounds extrapolation); step 8 should
  steer on MissingWall only after the shell has >= 3 walls and on Weak/Occluded/UnseenCorner before that.
- Real rooms: ARCore planes and sparse points may behave nothing like the sim; the 15 s checkpoints, 3-wall rule and all radii are guesses.
