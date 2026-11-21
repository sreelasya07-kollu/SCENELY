# 0011: Guidance is evaluated with a simulated walker until real trials exist
Status: accepted (2026-11-14). `ckit guide-eval` runs the real C++ engine against a deterministic human model (compliance 0.85,
1-3 s reaction delay, 6 deg yaw noise, 0.9 m/s) in box / L-shaped / furniture rooms. Ground truth uses the engine's sufficiency
rule with true occlusion, so "claimed vs actual coverage" is measurable (target: within a few points). Safety is judged against
the TRUE room (a target must be walkable for a 0.25 m disc), not the engine's own map. These numbers show the logic works and
which parameters matter; they do NOT show people will follow instructions: that is Phase 12 (Wizard-of-Oz, then trials).
Replace the human model parameters with measured ones as soon as real sessions exist.
