# Brief: Run every runnable suite, fix failures, finish software-only pending items   slug: test-all-and-finish-pending   base commit: 47a594e6fc4ac1478aa2ac821ee7356be3951aba
Domain: android | backend | infra (milestones are sequential; M4 gets its own brief after Q1)
Contract: Scan Bundle spec `2D-3D/capturekit/spec/scanbundle/SPEC.md` (read-only here); zip archive format owned by `tools/ckit/bundle/archive.py` (ADR 0034), read-only.

## Goal
Find out what passes on this Windows PC today, fix what fails, and finish the pending work that needs only software. Then list what is still blocked on phones, a Mac, Docker or the user.

## Settled (do not re-research)
- Git root is `Hackathon/` (HEAD 47a594e). Top-level `android/` (140 tracked files from d0aebf0) is an OLD duplicate: 47 files differ from `2D-3D/capturekit/android`, which is newer (it has `segment/` RF-DETR, ADR 0035-0038). Its deletion is cleanup, not lost work.
- The uncommitted ObjectBoxes work matches ADR 0038 (untracked file, not in `decisions/README.md` yet): `segment/ObjectBoxes.kt:LiveObject.scanned`, `LiveObjectTracker.SCANNED_MIN_SIGHTINGS=3`, `DrawBox.scanned`, the tests, and overlay/Hud/CaptureActivity wiring.
- #10 stage 1 is in main: `ckit pack` (`tools/ckit/cli.py:pack_cmd`), `bundle/archive.py`, `record_imu`. Stage 2 is NOT done. No Kotlin code touches zip. `dev-server/verifier/bundle_verify.py` is per-file only. roomscan-recon already reads zips (`spatial/io/capturekit.py`, `jobs/attach.py`).
- What this PC has (checked 2026-11-22): WSL distro `Ubuntu` (user karthik, `~/tools/cmake-3.31.6`, `~/.local/bin/uv`, `~/ck-venv`, `~/ck-build-core-py`) · JDK 21.0.11 in `C:\Program Files\Java` (no JDK 25. Gradle provisions 25 itself through `gradle/gradle-daemon-jvm.properties`, and it is cached in `~/.gradle/jdks`) · Android SDK under itz_k: platform 37, NDK 30.0.16248370, CMake 4.1.2, **build-tools 36.0.0 only** (PROGRESS says 37.0.0) · `local.properties` already points at itz_k (the samee path is gone) · adb.exe is in `Sdk/platform-tools` but not on PATH · **no Docker** (Windows or WSL) · no Mac.
- No TODO/FIXME markers in core, android, tools, dev-server or ios sources.

## Non-goals
iOS changes that cannot be compiled. Flipping `FeatureFlags` defaults (ADR 0032 needs device PASS). roomscan-recon changes. Push or deploy.

## Steps
1. [x] M0 Commit hygiene (only after Q2): add 0038 to `capturekit/docs/decisions/README.md`. Grep that nothing references top-level `android/`. | done when: `git status` shows only the intended changes
2. [ ] M1 Android, first (fast): run the Android acceptance command. If build-tools 37 is demanded and fails offline, stop and report. | done when: BUILD SUCCESSFUL, test count >= 268 + new ObjectBoxes cases
3. [ ] M1 Core and Python in WSL, in the background from a script file (`.sh` with LF line endings; ctest takes about 25 min, use -j6; the Python binding needs `CMAKE_BUILD_PARALLEL_LEVEL=4`), with the build dirs in `$HOME`. | done when: ctest 0 failed, pytest 0 failed, ruff clean
4. [ ] M2 Triage: one table of failures (suite, test, cause, fix or blocked). Fix them. After 3 failed attempts on one item, log it in PROGRESS Gotchas and move on (AGENTS.md E). | done when: M1 commands are green again
5. [ ] M3 Small items that are software only: add a `Telemetry.scrub` unit test (an accepted gap) and refresh the stale numbers and paths in PROGRESS/STATUS (build-tools, JDK, test counts, docker missing). | done when: suites are green, PROGRESS stays <= 40 lines
6. [ ] M4 (if Q1 = yes, as a separate brief) #10 stage 2: `CaptureActivity.finishScan` / `SessionManager.finish` packs the zip (same layout as `archive.py`). `ScansActivity`, `ReviewActivity` and `upload/UploadPlan` + `TusUploader` read and send one zip. The verifier accepts a single zip upload with its own sha256. Add Kotlin tests and `test_verifier.py` cases. Its docker smoke and device run stay blocked.

## Acceptance (commands that must pass)
- `cd 2D-3D/capturekit/android && JAVA_HOME="C:\Program Files\Java\jdk-21.0.11" ./gradlew --no-daemon -Pkotlin.incremental=false :capturekit:testDebugUnitTest :sample-app:assembleStandardDebug :sample-app:assembleFieldDebug --console=plain` -> BUILD SUCCESSFUL
- WSL: `cmake -S capturekit/core -B $HOME/ck-build-all -DCMAKE_BUILD_TYPE=Release && cmake --build $HOME/ck-build-all -j6 && ctest --test-dir $HOME/ck-build-all` -> 100% passed (1 skipped by design)
- WSL: `scripts/build_core_py.sh` then `cd capturekit/tools && uv run pytest -q && uv run ruff check . && uv run ruff format --check .` (env per capturekit/scripts/README.md) -> 0 failed
- WSL: `scripts/replay_golden.sh` -> exit 0 (CI job step)
- NOT runnable here: `dev-server/smoke.sh` and `failure_test.sh` (no docker), iOS `swift test`/xcodebuild (no Mac), and everything in docs/HUMAN_TESTS.md (phone).

## Pending items by blocker
- Software, doable here: ADR index 0038, the uncommitted ObjectBoxes work, #10 stage 2 code + unit tests, Telemetry.scrub test, stale docs.
- Needs a phone (adb is present, no device attached): H9/H22 guidance re-walk, H18/H19 detector, H36 recalibration, H37/H38 segmentation (RF-DETR GPU), H14 face redaction, the #10 stage 2 device run, the APK install.
- Needs Docker: upload smoke and failure matrix (or GitHub Actions `upload` job).
- Needs a Mac: all iOS (ADR 0037 Swift ports were never compiled).
- Needs a human: Phase 12 thresholds, consent text, prod endpoints, second walked room (#7), field trials.

## Review focus
- Changes in M2 must fix the code or the test for a real cause. Relaxing a threshold or adding skips to get green is not a fix.
- M4 zip layout must match `archive.py` byte for byte in the parts that matter (store JPEGs, entry names, no absolute or `..` paths).

## Risks and stop-and-report triggers
- Gradle asks for build-tools 37.0.0 or a JDK 25 download and the PC is offline.
- WSL runs out of memory (7 GB). Stop it with `wsl.exe -t Ubuntu`.
- The OneDrive path under /mnt/c is slow or has CRLF scripts. Use LF copies.
- Any failure that needs a schema bump: stop. It is a contract change.

## Questions for the human
1. Is #10 stage 2 (Android zip at Finish, zip upload, verifier) in scope now? It cannot be device-verified or docker-tested here.
2. Commit the ObjectBoxes changes (ADR 0038) and the deletion of the old top-level `android/` as they are, as two separate commits?
3. iOS and the docker upload tests cannot run here. Should they stay "blocked", or should we push a branch so GitHub Actions runs them (macOS + docker jobs)? Pushing needs your OK.

## Answers from the human (2026-11-22)
1. #10 stage 2: YES, in scope, but it gets its own brief (planner writes `issue-10-stage-2.md`). This brief covers M0–M3 only; do not start #10 stage 2 code here.
2. Commits: do NOT commit anything (not the ObjectBoxes work, not the android/ deletion, not your fixes). Leave all changes uncommitted in the working tree. M0 = only add ADR 0038 to the ADR index.
3. iOS and docker upload tests stay blocked. No push.
