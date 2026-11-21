# Android perf baseline and crash matrix (CPH2381, ARCore, 2026-11-15)

Brief: android-stability-and-speed (steps 1-4). Build = step-1 instrumentation only (no behaviour change).
Conditions: USB powered (not charging-limited, battery 47%, 35.6 C), thermal status 3 at every run
(skin 36-40 C; the phone never cooled below the status-3 threshold in the session). Phone lay still in a dark
spot: tracking stayed INSUFFICIENT_LIGHT (trk 0), so this is NOT a walk: no keyframes, no drops to measure.

## Device facts (logged once per Session by CKArHost)
| Item | Value |
|---|---|
| Display refresh | 60 Hz |
| Current CPU image (what keyframes are cut from) | 640x480, GPU texture 1920x1080, 30 fps |
| Supported configs (all 30 fps, depth/stereo DO_NOT_USE, back cam) | cpu 640x480, 1280x720, 1920x1080 |

## Baseline (60 s idle-dark capture, step-1 build)
| Metric | Measured | Target |
|---|---|---|
| GL draws/s | 60.0 | = camera fps (~30) |
| duplicate Frame.timestamp reaching the core | 1832 of 3677 draws (49.8%) | 0 |
| frames ingested (frameEveryN=3, includes duplicates) | 1212 of 3641 poses | n/a |
| candidate drops (ingestSt 5) | 0 (no tracking, no real load) | < 5% cool |
| gfxinfo janky (modern) / legacy | 0.05% / 86.35% (p50 18 ms, p90 23 ms) | < 5% modern |
| Activity.onPause total (main thread) | 154-420 ms (n=4: 202, 192, 154, 420) | < 100 ms |
| of which view.onPause / session.pause | 9-31 ms / 134-384 ms | |
| session.close | 18-42 ms | |
| per-thread CPU (`top -H`) | not captured (toybox top printed 0.0 for the app) | |

Reading: the core was fed every GL draw, half of them duplicates (confirms the brief's finding). session.pause()
is the whole onPause cost (ARCore camera close), the view pause is cheap.

## Crash matrix, baseline build (1 run each, 3x not done)
| Run | Scenario | Result |
|---|---|---|
| R1 | Capture idle 25 s, Back | no crash |
| R2 | Start, 20 s, Back | no crash (destroyed mid-scan path, finish OK) |
| R3 | Start, 20 s, Finish, Back | no crash |
| R4 | Start, Home at 10 s, relaunch | CRASH, class (c) |
| R6 | power off/on mid-scan | INVALID: power key left the phone on a secure lock screen |
| R7 | launch, Back, relaunch | INVALID (phone locked after R6) |
| R5 | 3 min walk | not run |

R4 crash excerpt (class c: no "restarting AR session", no "destroyed mid-scan" before it):
```
18:09:50.333 F libc: Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x7603740050 in tid 29117 (tango_pool_lp3)
  #00 pc f9bfd8 base.apk!libarcore_c.so   #01 pc f8d550 base.apk!libarcore_c.so
18:09:50.437 CKArHost: timing view.onPause=31ms session.pause=384ms     <- crash happened INSIDE session.pause()
18:09:50.438 CKCapture: timing Activity.onPause total=420ms
exit-info: reason=5 (APP CRASH(NATIVE)) status=11
```
Same signature as the user's earlier log (ARCore worker tango_pool_lp*, only libarcore_c frames). This pause was
also the slowest of the set (384 ms vs 134-190 ms), so the crash is a race inside ARCore's pause while its worker
threads run; not our code. Trigger seen here: backgrounding (Home) while recording; Back paths did not crash in 1 run.

## After steps 3-4 (code in tree, NOT yet verified on device)
Blocked: the phone is on a secure lock screen after R6 (power button), cannot be unlocked from adb. Two aborted
"after" runs (R4 x3, R2 x2) ran against the lock screen and are invalid (no capture logs). To finish: unlock the
phone, then run the matrix script (R1-R7 x3), a 60 s lit walk, and fill this table:

| Metric | Baseline | After 3+4 |
|---|---|---|
| GL draws/s | 60.0 | ? |
| arDupFrames (reaching core) | 1832 | ? (expect 0; skipped dup counted separately as `skipped`) |
| Activity.onPause | 154-420 ms | ? |
| crashes R1-R7 x3 | 1 of 5 valid runs | ? |
| tracking NORMAL within 3 s, planes found | n/a (dark) | ? |
