#!/usr/bin/env bash
# Shallow-clone READ-ONLY reference repositories into reference/ (gitignored).
# Nothing from reference/ may be copied into this repository. See reference/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$ROOT/reference"
mkdir -p "$REF"

# <github owner/repo> <local dir>
REPOS=(
  "strayrobots/scanner                  stray-scanner"
  "prime-slam/OpenCamera-Sensors        opencamera-sensors"
  "DavidGillsjo/VideoIMUCapture-Android videoimucapture"
  "google-ar/arcore-android-sdk         arcore-samples"
  "nerfstudio-project/nerfstudio        nerfstudio"
)

for entry in "${REPOS[@]}"; do
  read -r repo dir <<<"$entry"
  if [ -d "$REF/$dir/.git" ]; then
    echo "reference: $dir already present"
    continue
  fi
  echo "reference: cloning $repo -> reference/$dir"
  git clone --quiet --depth 1 --single-branch "https://github.com/$repo.git" "$REF/$dir"
done
