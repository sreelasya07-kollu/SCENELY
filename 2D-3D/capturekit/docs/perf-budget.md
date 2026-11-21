# Performance budget (Phase 12)

Targets are "TBD owner"; measured values go in the per-device table. First Android numbers (idle, not a walk):
[android-perf-baseline.md](android-perf-baseline.md). Soak procedure: [soak-test.md](soak-test.md).

## Budget
| Metric | Target | How |
|---|---|---|
| Sustained FPS (camera / GL) | TBD owner | gfxinfo |
| Per-frame latency (ingest) | TBD owner | CK logcat tags, `ckit replay <bundle> --sink metrics` |
| Thermal state at 5 and 10 min | TBD owner | thermalservice, `platform.thermal` events |
| Battery per scan (% / mAh) | TBD owner | batterystats |
| Memory (PSS peak) | TBD owner | meminfo |
| Bundle size per minute | TBD owner | `ckit validate`, folder size |
| APK size | TBD owner | CI size budget script (planned) |

## Measurement commands (Android, `adb` from platform-tools)
Package: `dev.capturekit.sample` (the planned `field` flavour adds `.field`).
```
adb shell dumpsys gfxinfo <pkg> reset          # before the scan
adb shell dumpsys gfxinfo <pkg>                # after: janky %, p50/p90 frame time
adb shell dumpsys thermalservice               # thermal status + skin temps; run at 5 and 10 min
adb shell dumpsys batterystats --reset         # unplugged, before the scan
adb shell dumpsys batterystats <pkg>           # after: app drain
adb shell dumpsys meminfo <pkg>                # at 5 and 10 min: TOTAL PSS
```
On Git Bash prefix with `MSYS_NO_PATHCONV=1`. Conditions to record: battery %, charging, room temperature, light.

## Per-device table
| Device | OS | FPS | Latency | Thermal 5/10 min | Battery/scan | PSS | Bundle MB/min |
|---|---|---|---|---|---|---|---|
| (fill from measurements) | | | | | | | |
