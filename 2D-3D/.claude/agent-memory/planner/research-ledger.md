# Research ledger
2026-11-22 | Where must GH workflow files live? | docs.github.com workflow-syntax | root .github/workflows only; nested 2D-3D/.github and roomscan-recon/.github never run | VERIFIED
2026-11-22 | Do action tags in ci.yml exist? | GitHub releases API | checkout v7.0.1, setup-uv v10.4.0, setup-java v6.3.0, gradle/actions v6.4.1 latest | VERIFIED
2026-11-22 | CI runs on SCENELY? | gh run list | none | VERIFIED
2026-11-22 | How does roomscan-recon fetch a bundle from the verifier? | roomscan-recon/jobs/runner.py@47a594e:106-114 | per-file GET /bundles/<id>/files/<path>; verifier must keep serving entries for zip uploads | VERIFIED
2026-11-22 | Can verifier reuse ckit archive code in docker? | dev-server/verifier/Dockerfile@47a594e | yes, it COPYs tools/ckit; archive.py is stdlib-only | VERIFIED
