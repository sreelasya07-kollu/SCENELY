# 10-minute soak test (Phase 5)

Goal: show that the governor degrades gracefully before the phone throttles hard or loses tracking, and that a
scan survives 10 minutes on every supported tier. Needs real phones (blocked until hardware is available).

## Setup
- Phone at 40–80 % battery, not charging, brightness 50 %, no other apps, room 20–25 °C (note it).
- Sample app build with the governor enabled and `/events` logging on (governor transitions are
  `governor.GOVERNOR_LEVEL` events; platform signals are `platform.thermal`, `platform.power`, `platform.perf`).
- Start temperature: let the phone idle 5 min with screen on.

## Protocol
1. Start a scan in the reference room and walk the perimeter continuously at normal speed for 10 minutes
   (repeat the loop; do not stop).
2. At minute 5, enable Low Power Mode / Battery Saver for 30 s, then disable it.
3. Note any OS warnings, UI warnings and whether tracking was lost.
4. Stop, finalize, keep the bundle. Run:
   `ckit validate <bundle> --level quality` and
   `ckit replay <bundle> --sink metrics --sink quality --sink governor --out soak_<device>.json`.

## Pass criteria (starting guesses; tune on data)
- No crash, bundle validates without ERROR.
- No tracking loss caused by heat (tracking_not_normal intervals only where the room explains them).
- If the OS reached `serious`, the governor was at LOWER_RESOLUTION or above within 1 s.
- SAFE_PAUSE only at `critical` or battery <= 5 %; the bundle is intact after it.
- Governor transitions <= 6 in 10 minutes (no flapping).

## Results template (one row per device)
| Device | OS | Tier | Start °C / end °C (if known) | Max OS thermal | Max governor level | Transitions | Tracking lost (s) | Keyframes | Battery used % | Pass |
|---|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | | |

Commit the replay JSONs to `capturekit/bench/thermal/<device>/` and the filled table to
`capturekit/docs/reports/soak.md`.
