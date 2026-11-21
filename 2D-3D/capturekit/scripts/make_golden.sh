#!/usr/bin/env bash
# Render the synthetic golden raw sessions (ADR 0002) into build/golden/raw/.
# Usage: scripts/make_golden.sh [--small]   (--small: 3 short sessions for CI)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/golden/raw
mkdir -p "$OUT"
CKIT="tools/.venv/bin/ckit"
if [[ "${1:-}" == "--small" ]]; then
  set -- G1:12 G4:12 G8:20
else
  set -- G1:60 G2:90 G3:40 G4:70 G5:45 G6:45 G7:30 G8:40
fi
for spec in "$@"; do
  id=${spec%%:*}; dur=${spec##*:}
  dir="$OUT/${id}_synth_${dur}s"
  [[ -f "$dir/device.json" ]] && { echo "skip $dir"; continue; }
  "$CKIT" synth "$id" "$dir" --seed 1 --duration "$dur" >/dev/null && echo "made $dir"
done
