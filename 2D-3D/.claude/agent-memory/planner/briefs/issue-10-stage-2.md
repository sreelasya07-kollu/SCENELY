# Brief: #10 stage 2: Android packs one zip at Finish, zip upload, verifier accepts a zip   slug: issue-10-stage-2   base commit: 47a594e6fc4ac1478aa2ac821ee7356be3951aba
Domain: android | backend (dev-server verifier)
Contract: zip layout owned by `capturekit/tools/ckit/bundle/archive.py` (ADR 0034), read-only here. This brief owns the new tus "single archive" upload contract (metadata `path=bundle.zip`) and writes it down in the new ADR (step 1).

## Goal
After a good Finish the phone keeps one `scan_<stamp>.zip` instead of the loose folder. My scans, Review and upload work from that zip, tus sends it as one upload, and the dev-server verifier checks it and serves it. Folders (old scans, or a failed pack) keep working everywhere.

## Settled (do not re-research)
- Zip layout = `archive.py:pack_bundle`/`_zip_info`/`_listed_files`: entries sit at the root with no folder prefix. `manifest.json` comes first, then the `manifest.files` paths sorted. `.jpg/.jpeg/.png/.zip` are STORED and everything else is DEFLATED (level 6). Every entry is dated 1980-01-01 00:00. Packing fails on an unsafe name, a listed file that is missing, or a file on disk that the manifest does not list (`*.tmp` excepted). The file is written as `<out>.tmp`, checked, fsynced, then renamed. The folder is deleted only after that. | ADR 0034 | archive.py@47a594e
- Byte-identical output with Python is NOT required: `java.util.zip` cannot set `create_system`/`external_attr`. What must match: entry names, entry order, compression method per extension, timestamps, and sha256/size against the manifest. Python `verify_archive` is the oracle.
- Sibling files keep using the folder name as their key: `ResearchReport.fileFor(dir)`, `UploadPolicy.verifiedMarker(dir)`, `UploadWorker.name(bundle)`. The zip is `File(dir.parent, dir.name + ".zip")`. Queued work and markers from before the change keep working.
- The runner in roomscan-recon fetches files one at a time with `GET /bundles/<id>/files/<path>` (`roomscan-recon/jobs/runner.py:106-114`). The verifier must keep that endpoint working for zip uploads by serving zip entries. roomscan-recon does not change.
- `Store.open` on S3 does not support seek. The verifier copies the zip to a local temp file before it opens it with `zipfile`. It lazily imports `ckit.bundle.archive` (`verify_archive`, `extract_archive`). The Dockerfile already ships `tools/ckit`.
- minSdk 26, so `ZipEntry.setTimeLocal(LocalDateTime)` is available. Do not use `setTime(ms)`: it depends on the time zone.

## Non-goals
Python `ckit upload` zip mode (the docker smoke stays per-file). iOS. roomscan-recon. RecorderActivity raw recordings. Any schema change. Commits or push.

## Steps
1. [x] Write the ADR (next free number, which is 0040 unless the other coder has taken it; check `ls capturekit/docs/decisions` first). It covers: pack at Finish and after recovery, the folder fallback, tus metadata `{bundle_id, path:"bundle.zip", sha256:<zip sha>, filename}`, and verifier semantics. Add a line to ADR 0034 under "Stage 2" and to `decisions/README.md`. | done when: the ADR is 3–6 lines and indexed
2. [x] Kotlin `BundleArchive` (new, `capturekit/src/main/kotlin/dev/capturekit/upload/BundleArchive.kt`, pure JVM, hand-parse `manifest.files[].path`, no org.json). Functions: `archiveFor(dir)`, `pack(dir): File` (throws), `verify(zip): List<String>` (sha/size per manifest, no extras, safe names), `packAndReplace(dir): File?` (pack, verify, delete the folder, return null and keep the folder on any failure), `manifestText(bundle: File)` and `readEntry(zip, name)` for folder or zip, `sizeBytes(bundle)`, `cleanTmp(root)`. | done when: the new `BundleArchiveTest` passes
3. [x] `BundleArchiveTest` [parallel with 5]: pack `../../spec/scanbundle/examples/frozen-1.0.0` (skip if missing) and a temp bundle. Assert entry order, STORED for jpg and DEFLATED for others, 1980 time, sha against the manifest, and refusal of an unlisted extra file, an unsafe path, a missing listed file and a pre-existing `.tmp`. `packAndReplace` keeps the folder when verify fails. | done when: `:capturekit:testDebugUnitTest` is green
4. [x] Pack in `SessionManager.finish` after `finalizeSession` returns OK (status row stays "complete"). Also pack in `recoverInterrupted` after it recovers a bundle. Both go through `packAndReplace`, off the main thread (finish already is). `CaptureActivity.finishScan` passes the zip path (or the folder path if packing failed) to Review. Run `cleanTmp` at launch next to the `recoverInterrupted` calls (`MainActivity`, `CaptureActivity`). | done when: it compiles and no folder is deleted unless the zip verified
5. [x] Upload: `UploadPlan` gets `ARCHIVE_PATH = "bundle.zip"`. `TusUploader.uploadBundle` sends a zip as one upload: bundle id from `manifestText`, repair re-sends the zip fresh once when `corruptPaths` contains `bundle.zip`, progress covers the zip length. Folders keep the per-file path. `UploadWorker.doWork` reads the manifest through `BundleArchive`, accepts a zip or folder in `KEY_DIR`, and switches to the zip if the folder is gone. With delete-after-verify it deletes the zip and its siblings. Add `UploadPlanTest` cases (ARCHIVE_PATH, `ServerStatus.parse` with `bundle.zip` corrupt). | done when: the tests are green
6. [x] Sample app: `ScansActivity.loadRows` lists folders and `*.zip`, with folder taking priority if both exist. Manifest, size and thumbnail come from the zip entry (`BitmapFactory.decodeByteArray`). `ReviewActivity` reads the manifest and size through `BundleArchive`, and labels the row "File" or "Folder". `UiKit.dirSizeBytes` callers use `BundleArchive.sizeBytes`. | done when: `assembleStandardDebug` and `assembleFieldDebug` pass
7. [ ] Verifier (`dev-server/verifier/bundle_verify.py`): `ARCHIVE = "bundle.zip"`. In `check`, if the latest complete upload is `bundle.zip` (newer than any manifest upload), copy it to a temp file and check its declared sha256. Then call `verify_archive`. The result is COMPLETE with `received` = entries, or CORRUPT `[{path:"bundle.zip", reason}]`. Cache by zip sha. Set `_listing` so that `open_listed` serves zip entries (stream plus `file_size`). `_run_validation` runs `extract_archive` and then the validator. `server.py:do_POST` also triggers `after_manifest` for `path == "bundle.zip"`. | done when: step 8 is green
8. [ ] `tools/tests/test_verifier.py` new cases, using `Fake.put("bundle.zip", ...)` with a zip from `ckit.bundle.archive.pack_bundle(FROZEN)`: complete, wrong declared sha leads to CORRUPT, tampered entry leads to CORRUPT, truncated upload leads to PENDING, `open_listed` serves `keyframes/...` from the zip, server validation passes, and a zip re-upload replaces the previous result. | done when: pytest is green
9. [ ] Docs: `docs/HUMAN_TESTS.md` (pull `scan_*.zip`, add a #10 stage 2 device check), `docs/STATUS.md`, `PROGRESS.md` (≤40 lines). | done when: the docs mention the zip and list the blocked checks

## Reuse
- `capturekit/tools/ckit/bundle/archive.py` (in repo): layout spec and the verifier's checker/extractor.
- `java.util.zip` (JDK and Android, minSdk 26): no new dependency.

## Acceptance (commands that must pass)
- `cd 2D-3D/capturekit/android && JAVA_HOME="C:\Program Files\Java\jdk-21.0.11" ./gradlew --no-daemon -Pkotlin.incremental=false :capturekit:testDebugUnitTest :sample-app:testStandardDebugUnitTest :sample-app:assembleStandardDebug :sample-app:assembleFieldDebug --console=plain` -> BUILD SUCCESSFUL
- WSL: `cd capturekit/tools && uv run pytest -q tests/test_verifier.py && uv run pytest -q && uv run ruff check . && uv run ruff format --check .` -> 0 failed (env per capturekit/scripts/README.md)
- BLOCKED, not done: the device run (Finish leaves `scan_*.zip`, My scans/Review/upload on the phone) needs a phone. `dev-server/smoke.sh` / `failure_test.sh` with a zip need Docker. iOS needs a Mac. Report these as blocked.

## Review focus
- Folder deletion: it must happen only after the zip verified on disk. A crash at any point leaves either a valid folder or a valid zip.
- Kotlin layout against `archive.py` (order, STORED/DEFLATED, names, extras refused).
- Verifier: an untrusted zip must not escape the temp dir, the temp copy must be cleaned up, and the per-file upload path must be unchanged (all old tests still pass).

## Risks and stop-and-report triggers
- Files that may overlap with the concurrent suite-fixing coder (base 47a594e): `sample-app/.../CaptureActivity.kt` and `UiKit.kt` (already modified in the tree), `MainActivity.kt`, `capture/SessionManager.kt`, `tools/tests/test_verifier.py`, `docs/STATUS.md`, `PROGRESS.md`, `capturekit/docs/decisions/README.md` and the next ADR number. Re-read each file right before editing it, make small targeted edits, and never revert changes you did not make.
- The core's manifest may not list every file in the folder (packing then refuses). The folder fallback keeps the scan usable. Log this and report it; do not loosen the extras check.
- Stop if a schema change or a roomscan-recon change looks needed.

## Questions for the human
1. Should recovered (force-killed) scans also be packed at the next launch (planned: yes), or stay as folders?
2. Is the fixed tus path `bundle.zip` acceptable as the archive marker? (The alternative is an extra metadata key `archive=zip`.)

## Answers (2026-11-22, orchestrator defaults; the human asked to start in parallel without waiting)
1. Yes: recovered scans are packed at the next launch.
2. Yes: fixed tus path `bundle.zip` is the archive marker.
Also: do NOT commit anything; leave all changes uncommitted. No push.
