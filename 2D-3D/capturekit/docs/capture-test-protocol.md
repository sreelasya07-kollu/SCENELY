# Capture test protocol (Phase 6, device work)

Run on every device in `docs/reports/devices.md` (>= 2 iOS, >= 3 Android, different tiers). Use the sample app's
"Capture (core session)" screen. After each case copy the bundle folder to the dev machine and run
`ckit validate <bundle> --level quality`, `ckit replay <bundle> --sink metrics --sink quality --sink governor`,
and for case 1 `ckit quality-report <bundle>` (pycolmap registration).
Pass = the stated result. Record device, OS, build, and anything odd in `docs/reports/capture-results.md`.

| # | Case | Steps | Pass |
|---|---|---|---|
| 1 | 5-minute scan | Walk a normal room for 5 min, Finish | Validates with 0 ERROR; registration rate >= target (Phase 12); no UI jank; thermal level reported |
| 2 | Forced kill | Scan 60 s, swipe the app away (iOS) / force-stop (Android), relaunch | App recovers the session ("recovered 1 interrupted session"); bundle validates with PARTIAL_BUNDLE warning only; at most ~1 s of data lost; no orphan JPEGs |
| 3 | Phone call | Scan 60 s, receive a call, answer 10 s, hang up, return | Core pauses (SESSION_PAUSED), resumes after tracking recovers; one bundle; no crash |
| 4 | Backgrounding | Scan 30 s, home screen 30 s, return | Same as 3; ARCore/ARKit tracking loss is recorded, not hidden |
| 5 | Tracking loss | Cover the lens 5 s, uncover; then point at a blank wall 10 s | Frames in the gap are hard-rejected (TRACKING_LOST / LOW_TEXTURE); no keyframes from the gap; scan continues |
| 6 | Low light | Scan in a dim room (< 50 lux) | UNDEREXPOSED / MOTION_BLUR rejections visible; bundle still valid; no thermal escalation from retries |
| 7 | Storage full | Fill storage to < 200 MB free, scan | Failure is reported (ingest error / FAILED state), existing frames stay recoverable, no crash |
| 8 | Android keyframe resolution | Log `Image.width x height` of the ARCore CPU image per device | Table in capture-results.md; decide ADR 0009 follow-up |

## Core checks that run without devices (already automated)
`SessionRecovery.*` and `SessionThreaded.*` (C++), `tests/test_capture_session.py` (real C ABI via ctypes with a
SIGKILL mid-capture), run under ASAN/UBSAN/TSAN in CI.
