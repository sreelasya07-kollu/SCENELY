# 0040 Android packs one zip at Finish; tus sends it as one upload; the verifier takes a zip (issue #10 stage 2)

Status: accepted (2026-11-22), completes stage 2 of ADR 0034. Zip layout is owned by `tools/ckit/bundle/archive.py` (unchanged).

- Pack: after `finalizeSession` is OK, and after `recoverInterrupted` recovers a bundle, `BundleArchive.packAndReplace` writes `scan_<stamp>.zip` (`.tmp`, verified against the manifest, renamed) and deletes the folder only after that. Any failure keeps the folder; folders (old scans, failed packs) work everywhere. Sibling files (research report, verified marker, upload work name) keep the folder name as key.
- Upload contract: a zip goes up as ONE tus upload with metadata `{bundle_id, path:"bundle.zip", sha256:<zip sha>, filename}`; the fixed path `bundle.zip` is the archive marker (no extra key). Folders keep the per-file uploads. Repair re-sends the zip once when `bundle.zip` is reported corrupt.
- Verifier: if the latest complete upload is `bundle.zip` (newer than any manifest upload) it copies it to a local temp file (S3 has no seek), checks the declared sha256, then `verify_archive`: COMPLETE (received = entries) or CORRUPT `[bundle.zip]`. `GET /bundles/<id>/files/<path>` serves zip entries, so roomscan-recon is unchanged. Server validation runs on `extract_archive` output.
- Kotlin cannot set zip `create_system`/`external_attr`, so bytes may differ from Python; names, order, methods, 1980 timestamps and sha/size match, and `verify_archive` is the oracle.
