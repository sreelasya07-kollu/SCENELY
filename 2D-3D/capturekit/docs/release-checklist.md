# Release checklist (Phase 12)

Every target is "TBD owner" until agreed. Tick only with evidence (command output or report path).

## Quality gates
- [ ] CI green (core ctest, `uv run pytest -q`, `uv run ruff check .`, Android build + unit tests).
- [ ] Golden replay regressions pass (`ckit replay-compare`).
- [ ] Schema compatibility: old 1.0.0 bundles still validate (`ckit validate <fixture>`).
- [ ] Upload smoke test against dev-server (`ckit upload <bundle> --consent`).
- [ ] APK size within budget: TBD owner.
- [ ] Crash-free sessions rate: target TBD owner, measured: ___.
- [ ] `ckit e2e` and `ckit trial-report` run on the golden dataset; trial targets met or gaps listed with owners ([trial-protocol.md](trial-protocol.md)).
- [ ] Perf table filled ([perf-budget.md](perf-budget.md)).

## Privacy review
- [ ] Consent text final (currently PLACEHOLDER, pending legal owner); consent version in manifest.
- [ ] Redaction mode stated in manifest; limits (faces only, no screens) stated in consent and docs.
- [ ] `standard` flavour has no INTERNET permission; endpoints/DSN not committed.
- [ ] Telemetry only with consent; scrubbed of paths/bundle names.
- [ ] Retention policy: TBD owner.

## Device support
- [ ] [device-matrix.md](device-matrix.md) updated with known issues per device.

## Handover to Part 2 (roomscan-recon)
- [ ] Bundle contract: `spec/scanbundle/` (SPEC version, schemas, examples) tagged with this release.
- [ ] RescanRequest: no schema yet (owner: Part 2); note as open.
- [ ] Sample bundles + `ckit validate` / `ckit inspect-raw` output shared.
