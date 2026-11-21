# Replay harness (Phase 3)

`ckit replay <bundle>` feeds a Scan Bundle through C++ core sinks in `t_ns` order and prints a
deterministic JSON report. Python only orders, injects faults and decodes JPEGs; every metric is
computed by the real core (`_ckcore.replay.Sink`). Two identical runs give byte-identical reports.

## Ordering
Merged by `(t_ns, channel rank, original index)`. Rank for equal `t_ns`:
`intrinsics < pose < gyro < accel < frame < event < points < planes < detections`.
`/guide/labels`, `/guide/shell`, `/guide/gaps` (schema 1.3.0, ADR 0028) are derived outputs: replay ignores them and recomputes them.
`/ar/detections` (schema 1.1.0, ADR 0016) is delivered through `ReplaySink::on_detections`; bundles without the channel replay exactly as before.
Injected events are placed by their own `t_ns` (before same-time events of higher rank).

## Modes and clock
`--fast` (default) delivers as fast as possible. `--realtime [--speed X]` paces delivery with a clock
object (`SystemClock`; tests use `FakeClock`). The mode never changes results, only pacing. The core
never reads a clock: all durations come from `t_ns`.

## Fault injection (all seeded with `--seed`)
| Flag | Effect |
|---|---|
| `--drop-frames P` | each frame dropped with probability P |
| `--jitter-ms J` | frame and IMU `t_ns` shifted by uniform ±J ms but delivered in the original order, so out-of-order samples reach the core (it must reject and count them) |
| `--inject-tracking-loss T0:T1` | poses in [T0, T1] s from start become NOT_AVAILABLE; event `replay.inject.tracking_loss` |
| `--inject-thermal T:STATE` | event `platform.thermal` with attr `state` (nominal/fair/serious/critical), the same record the apps log |

## Report
`{schema, bundle, options, input{delivered, injected, finalized, undecodable}, sinks{name: report}}`,
sorted keys, floats rounded to 6 digits, no wall-clock values. Compare with
`ckit replay-compare A B [--abs X] [--rel Y] [--tol key=ABS]` (exit 1 on difference).
`ckit replay-plot <bundle> out.png` draws the top-down trajectory.

## Adding a sink
1. Implement `capturekit::replay::ReplaySink` in the core (override the `on_*` you need,
   `needs_images()` if you need luma, and `report_json()` with `json::Object` so keys are sorted).
2. Register it in `core/replay/registry.cpp` (name → factory; the factory gets a flat JSON config).
3. Unit-test it in `core/tests/`, then add `--sink <name>` to `SINKS` in `scripts/replay_golden.sh`.

## Baselines
`scripts/replay_golden.sh` synthesizes G1, G3, G7 (4 s each, seed 0), replays them with fixed faults
and compares with `bench/replay_baselines/*.json` (CI job "Golden replay regression").
Refresh only on purpose: run `scripts/replay_golden.sh --update`, review `git diff bench/replay_baselines`,
and say in the commit message why the numbers changed.
