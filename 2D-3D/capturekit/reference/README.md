# reference/ — read-only study material

> **No code from `reference/` may be copied into this repository**, in whole or in part,
> and nothing here may be imported, linked or built by our code. Read for ideas; write
> our own implementation from our own specs. `reference/*` is gitignored; only this file
> is committed. Populate with `scripts/fetch_references.sh` (shallow clones).

| Dir | Upstream | License | What to study |
|---|---|---|---|
| `stray-scanner/` | [strayrobots/scanner](https://github.com/strayrobots/scanner) | MIT | `docs/format.md` (on-disk capture format) and the ARKit recording loop (frame/depth/pose capture per `ARFrame`). |
| `opencamera-sensors/` | [prime-slam/OpenCamera-Sensors](https://github.com/prime-slam/OpenCamera-Sensors) | **GPL-3.0** — reference only; copying would force GPL on our code | Camera + IMU clock synchronisation (sensor timestamp base vs. frame timestamps, Camera2 `SENSOR_INFO_TIMESTAMP_SOURCE`). |
| `videoimucapture/` | [DavidGillsjo/VideoIMUCapture-Android](https://github.com/DavidGillsjo/VideoIMUCapture-Android) | GPL-3.0 — reference only | Camera + IMU clock synchronisation; per-frame exposure/metadata recording alongside video. |
| `arcore-samples/` | [google-ar/arcore-android-sdk](https://github.com/google-ar/arcore-android-sdk) | Mixed: SDK binaries under Google's ARCore terms (LICENSE §1); SDK sources/samples Apache-2.0 (§2) | `samples/` recording & playback sample (ARCore Recording API, custom data tracks) and shared camera sample (Camera2 + ARCore sharing). |
| `nerfstudio/` | [nerfstudio-project/nerfstudio](https://github.com/nerfstudio-project/nerfstudio) | Apache-2.0 | `nerfstudio/process_data/` importers (e.g. Record3D, Polycam, ODM) as the model for our `tools/ckit/convert` converters and `transforms.json` output. |

Licenses were checked at setup time; re-check the upstream `LICENSE` before relying on this table.
