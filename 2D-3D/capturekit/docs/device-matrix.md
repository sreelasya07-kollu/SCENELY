# Device support matrix

Android = ARCore-capable devices only, phone camera only, no LiDAR (AGENTS C). iOS not built yet.
Support tier, minimum OS and inclusion criteria: TBD owner.

| Device | OS / API | ARCore | CPU image | On-device speech (API 31+) | Status | Known issues |
|---|---|---|---|---|---|---|
| CPH2381 | TBD (`adb shell getprop ro.build.version.sdk`) | yes | 640x480 @30 fps | TBD (voice needs API 31+) | in test | see [android-perf-baseline.md](android-perf-baseline.md) |
| (add per tested device) | | | | | | |

Status values: supported / in test / unsupported. Promote to "supported" only after the
[capture-test-protocol.md](capture-test-protocol.md) cases and the [perf-budget.md](perf-budget.md) row are filled.
