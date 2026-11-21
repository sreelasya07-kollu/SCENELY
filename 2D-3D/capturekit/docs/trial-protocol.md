# Field trial protocol (Phase 12)

Goal: measure whether real users produce bundles that reconstruct well, guided vs unguided.
All targets and counts below are "TBD owner" until agreed; do not fill them from memory.

## Before the trial
- Consent: participant reads and accepts the in-app consent text (PLACEHOLDER, pending legal owner). No scan without it.
- Room prep: screens switched off, other people asked to leave (redaction v1 covers faces only).
- Rooms: list each room (type, size, light) in the results sheet. Count per arm: TBD owner.
- Devices: from [device-matrix.md](device-matrix.md). Phone 40-80 % battery (from soak-test.md), field flavour build (planned, step 7).

## A/B design
- Arms: `guided` (voice + coaching) and `unguided` (voice/coaching muted; core still records). Set in Trial setup (planned, step 12).
- Each participant gets a participant code (no names). Arm order: TBD owner (e.g. counterbalanced).
- Script for the operator: "Scan this room until you think it is complete, then press Finish." No other help.

## Per scan
1. Bundle folder and `<scan>.research.json` (planned, step 12; written beside the bundle, never uploaded) copied to the dev machine.
2. `ckit validate <bundle> --level quality`
3. `ckit e2e <bundle>` (writes `<bundle>.e2e.json` and `.html`; `--research PATH` if the log is elsewhere, `--no-sfm` for a quick pass).

## Aggregate
`ckit trial-report <dir> --json trial.json --html trial.html` (groups by participant, device, room, arm; medians).

## Success
Downstream reconstruction succeeds with low reprojection error and good coverage (Phase 12). Thresholds:
| Metric (from `ckit e2e`) | Target |
|---|---|
| registered_ratio | TBD owner |
| reproj_mean_px | TBD owner |
| room-shell coverage / missing-area recall | TBD owner (recall null until Phase 9 labels) |
| duration_s, instruction count | TBD owner |

## Rolling-fix rule
Review after every 3-5 participants. Fix only defects found by the harness, each with a regression test;
note the build used for every scan so before/after groups stay separable.
