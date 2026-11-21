# 0010: Guidance coverage on detected planes, free space by carving, marginal-gain planning
Status: accepted (2026-11-14), thresholds are starting guesses. Coverage is counted on detected AR planes only (undetected
surfaces are Phase 9's room shell); a cell needs >= 3 qualifying keyframe views with >= 15 deg ray spread. Qualifying incidence
is 75 deg, not 60: a ceiling 1.1 m above the camera is unreachable at 60 deg (sweep: 60 deg gave 0 % ceiling, 75 deg 96 %).
Free space is carved along sight rays to observed points but never through obstacle cells (rays at head height pass over low
furniture), and a target needs its whole body disc known free (unknown space blocks, not only obstacles). Planner gain is
marginal progress (views + spread), because "visible" alone made the planner rotate on the spot. Every instruction costs 3 m of
overhead in the score, since a person pays a reaction delay for each.
