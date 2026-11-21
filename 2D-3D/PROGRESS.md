# PROGRESS
Program = 2 parts (docs/program-spec/README.md). This whole repo = Part 1 only (Part 2 = repo roomscan-recon). Phases 0–12. GitHub RealKarthiksai/2D-3D, branch `main`; issues #1-#10 are all closed (audit table: docs/STATUS.md top).
## Done (software verified on synthetic data; device acceptance mostly pending: docs/STATUS.md §0 + §3)
- Phases 0–8 done; 9–11 mostly (Android only); iOS never compiled (no Mac). Per-phase detail: docs/STATUS.md §1. Everything is committed; `git log` is authoritative (a history rewrite removed some old hashes).
- Since 2026-11-17 in `main`: real-room-fix T0/T1 (ADR 0025, 0026 layout, 0028 guide channels = schema 1.3.0, 0029 sim), detections 1.1.0, consent/privacy 1.2.0, object classes (#2, ADR 0030), tracking recalibration (#1, ADR 0031), UI redesign (#3), feature audit (#6: `FeatureFlags`, device-verified features only, ADR 0032), `ckit recon-bench` (#7), live segmentation (#8, flag OFF), keyframe dedup (#9, ADR 0033).
- #10 (lean bundle + one archive) was closed on GitHub without code. Stage 1 is PR `fix/issue-10-lean-bundle` (ADR 0034): the live session no longer records `/imu/*` (`record_imu`, default 0), schema 1.4.0 (IMU optional), `ckit pack` + `.zip` accepted by `validate`/`verdict`/`replay`/`recon-bench`. Stage 2 NOT done: Android packs at Finish, My scans/Review/upload read the zip, tus + dev-server verifier take one zip, device run.
- Flaky test fixed: `simulate(threaded=True)` lost the last keyframes in ~40 % of runs (it finalized before the worker drained); it now settles like the real shell.
- Verified 2026-11-20 on `cded9a6` (integrated main): core ctest 233/233 (1 skipped by design), Android `:capturekit` unit tests 267/267, standard debug APK built and installed on a CPH2527 (Android 15) and opens. With the #10 stage-1 PR: core ctest 238/238, WSL pytest 178 passed / 8 skipped, ruff clean, Android `:capturekit` 268/268, both sample-app flavours compile (APK with these changes not yet built or installed).
- Device: docs/DEVICE_TEST_LOG.md. First real walk FAILED guidance (completeness 3–7 %, 8 walls for 4, 16 prompts/min); data itself PASS. Guidance prompts are OFF by default since #6; the evidence scans are not on every machine (`capturekit/build/device/bundles/`, gitignored).

## Decisions
- capturekit/docs/decisions/README.md indexes ADRs 0001-0034. Recent: 0030 object classes, 0031 recovery, 0032 feature flags (default build = device-verified features only), 0033 keyframe dedup, 0034 lean bundle (+ keep/drop inventory of every channel and who reads it).
- Frozen: world Y-up, OpenCV camera frame, pose = T_world_from_camera, ARKit/ARCore only, no LLM in the real-time loop, bundle = MCAP + JPEG keyframes + JSON (now optionally one zip).

## Commands
- Core (WSL): PATH=$HOME/tools/cmake-3.31.6-linux-x86_64/bin; `cmake -S capturekit/core -B $HOME/ck-build-X -DCMAKE_BUILD_TYPE=Release && cmake --build ... -j6 && ctest --test-dir ...` (full suite ~25 min on this PC, run in background; WSL has 7 GB RAM: never more than -j6, the Python-binding build needs `CMAKE_BUILD_PARALLEL_LEVEL=4`).
- WSL Python: capturekit/scripts/README.md (uv in ~/.local/bin, `UV_PROJECT_ENVIRONMENT=$HOME/ck-venv`, `CKIT_CORE_DIR=$HOME/ck-build-core-py/py`, scripts/build_core_py.sh); then `cd capturekit/tools && uv run pytest -q && uv run ruff check . && uv run ruff format --check .`
- Android (Windows, this PC): SDK in `%LOCALAPPDATA%\Android\Sdk` (platform android-37.0, build-tools 37.0.0, NDK 30.0.16248370, CMake 4.1.2), `capturekit/android/local.properties` = `sdk.dir=C:/Users/samee/AppData/Local/Android/Sdk` (gitignored), JDK 25: `JAVA_HOME="C:\Program Files\Java\jdk-25" ./gradlew --no-daemon -Pkotlin.incremental=false :capturekit:testDebugUnitTest :sample-app:assembleStandardDebug --console=plain` (add `-Pcapturekit.skipNative=true` for unit tests only). Install: `adb install -r sample-app/build/outputs/apk/standard/debug/sample-app-standard-debug.apk`.
- Models (gitignored): `capturekit/scripts/fetch_models.sh` (detector), `--with-segmentation` (SAM 2.1 tiny, ~97 MB). Feature switches for a debug build: `adb shell setprop debug.capturekit.<guidance|detector|voice_commands|recalibrate_card|segmentation|record_imu|understanding> 1`, then force-stop.
- Replay baselines `scripts/replay_golden.sh` (WSL: LF copy); guide sim `ckit guide-eval --seeds 3` (~10 min); upload `dev-server/smoke.sh` (needs docker, not run).

## Gotchas
- CRLF scripts break in WSL (`*.sh text eol=lf`). Paths with spaces break nested quoting in `wsl.exe -- bash -c`: run a script file instead. `wsl.exe -t Ubuntu` stops a runaway build cleanly.
- One gradle at a time (--no-daemon). MCAP reader hangs on unfinalized files; per-channel t_ns strictly increasing; t_ns <= 0 is rejected at ingest.
- OPPO phones drop USB debugging often (re-toggle it, set USB mode to File transfer, tap Allow) or use Wireless debugging (`adb mdns services` finds the phone).
- GitHub Actions has never run on this repo (0 runs): CI in .github/workflows/ci.yml is untested. Commit messages of the owner's merges can be wrong (8444b6f is titled #10 but holds #6/#7): trust the diff.
- Accepted low findings: coverage virtual grids keep creation-time axes if a wall refits; Telemetry.scrub has no unit test; iOS/Swift never compiled; macOS CI job never seen green.

## Next
- 1) Review + merge PR `fix/issue-10-lean-bundle`; then #10 stage 2 (Android packing, upload of one zip, verifier, My scans/Review reading the archive) and a device scan to produce a real archive for `ckit recon-bench`.
- 2) Device checks listed in docs/STATUS.md §0 (H36 recalibration cover/uncover, H18/H19 detector, H37/H38 segmentation, H9/H22 guidance re-walk); fix guidance per docs/WALK_FAILURE_RCA.md, then flip defaults in `FeatureFlags`.
- 3) ADR for the segmentation model choice (#8) after a device trial; second walked room for recon-bench (#7); U12-D field trials.
