#!/usr/bin/env bash
# Golden replay regression: synthesize 3 small deterministic sessions, replay them through the core
# sinks with fixed faults/seed, and compare to the committed baselines in bench/replay_baselines/.
# Usage: scripts/replay_golden.sh            # check (CI)
#        scripts/replay_golden.sh --update   # refresh baselines deliberately (see docs/replay.md)
set -euo pipefail
cd "$(dirname "$0")/.."
CKIT="${CKIT:-tools/.venv/bin/ckit}"
W=build/replay_golden
BASE=bench/replay_baselines
SINKS=(--sink metrics --sink quality --sink governor --sink guide)
FAULTS=(--seed 7 --inject-tracking-loss 1:1.5 --inject-thermal 2:serious)
mkdir -p "$W" "$BASE"
fail=0
for g in G1 G3 G7; do
  if [ ! -f "$W/$g/manifest.json" ]; then
    $CKIT synth "$g" "$W/raw_$g" --duration 4 --seed 0 >/dev/null
    $CKIT import-raw "$W/raw_$g" "$W/$g" >/dev/null
  fi
  $CKIT replay "$W/$g" "${SINKS[@]}" "${FAULTS[@]}" --out "$W/$g.json"
  if [ "${1:-}" = "--update" ]; then
    cp "$W/$g.json" "$BASE/$g.json"
    echo "updated $BASE/$g.json"
  elif ! $CKIT replay-compare "$BASE/$g.json" "$W/$g.json" --rel 1e-3 --abs 1e-6; then
    fail=1
  fi
done
exit $fail
