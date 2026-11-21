# Quality report, synthetic golden sessions (Phase 4)

Source: `docs/reports/quality_synth.json` (`ckit quality-report build/golden/bundles/G* --uniform`), config q1.
`reg` = pycolmap incremental-SfM registration rate of the selected keyframes; `reg_uniform` = same number of
frames picked at a fixed interval (the rejected alternative).

| Session | frames | keyframes | kf/m | hard rejects | reg | reg_uniform |
|---|---|---|---|---|---|---|
| G1 small room | 218 | 64 | 4.5 | 33 motion blur | 1.00 | 1.00 |
| G2 large room | 359 | 118 | 3.5 | 32 motion blur | 0.69 | 0.80 |
| G3 corridor | 200 | 27 | 1.9 | 142 motion blur | 0.15 | 0.15 |
| G4 cluttered | 349 | 107 | 4.4 | 42 motion blur | 0.45 | 0.62 |
| G5 low light | 218 | 19 | 1.3 | 173 motion blur | 0.00 | 0.00 |
| G6 blank walls | 218 | 61 | 4.3 | 33 motion blur | 0.13 | 0.11 |
| G7 fast motion | 89 | 13 | 1.1 | 71 motion blur, 4 blur | 0.23 | 0.00 |
| G8 tracking loss | 200 | 50 | 4.0 | 53 motion, 30 lost, 30 dark | 1.00 | 0.84 |

## Reading it
- Selection wins where the faults are real in the images or poses (G7 blur, G8 tracking loss), ties on G1/G3/G5.
- G2/G4 favour fixed spacing. Two caveats: SfM varies run to run (G4 moved 0.31 → 0.45 between identical
  runs), and the synthetic renderer only draws motion blur in G5/G7, so gyro-based MOTION_BLUR rejects elsewhere
  drop frames that are sharp in the synthetic images but would be blurred on a phone.
- Low absolute registration in G3/G5/G6 also happens with fixed spacing: synthetic texture and corridor
  geometry are hard for SIFT incremental SfM. Phase 2 known-pose triangulation works on all eight.
- Thresholds (blur 4 px, rotation 10°, translation 0.1 × depth) are starting guesses: re-run on real
  recordings and tune before Phase 12 targets are set.
