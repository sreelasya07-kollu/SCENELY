# frozen-1.0.0

Frozen Scan Bundle at `schema_version` 1.0.0. NEVER regenerate or edit it after it is committed: the
CI `schema-compat` job proves every later validator still accepts a 1.0.0 bundle (SPEC.md,
Versioning: minor/patch changes must stay backward compatible).

Expected contents: `manifest.json`, `camera.json`, `streams.mcap`, `keyframes/`, and `SHA256SUMS`
(sha256 of every other file, so CI detects accidental edits).

Create it once, on a machine where `_ckcore` is built and the core still writes 1.0.0
(copy of a tiny valid synthetic bundle; do this from a commit whose bundle writer emits 1.0.0):

    cd capturekit
    scripts/build_core_py.sh
    tools/.venv/bin/ckit synth G1 build/frozen_raw --duration 4 --seed 0
    tools/.venv/bin/ckit import-raw build/frozen_raw spec/scanbundle/examples/frozen-1.0.0
    tools/.venv/bin/ckit validate spec/scanbundle/examples/frozen-1.0.0 --level semantic
    # README.md stays; write the checksums for all other files:
    (cd spec/scanbundle/examples/frozen-1.0.0 && find . -type f ! -name README.md ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS)

`import-raw` wipes its output directory: generate elsewhere and copy in, then re-add this README.
