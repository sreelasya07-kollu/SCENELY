#!/usr/bin/env bash
# One-shot developer setup. Safe to re-run.
#   SKIP_REFERENCES=1  skip cloning reference repos
#   SKIP_OPENCV=1      skip downloading prebuilt OpenCV
#   CKIT_EXTRAS="dev"  extras to install into tools/.venv (e.g. "dev nerf")
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }

step "git submodules"
git submodule update --init --recursive -- third_party/

step "git lfs"
if command -v git-lfs >/dev/null 2>&1; then
  git lfs install --local >/dev/null
  if [ -n "$(git lfs ls-files 2>/dev/null)" ]; then
    git lfs pull
  else
    echo "no LFS objects tracked yet"
  fi
else
  echo "warning: git-lfs not installed; bench fixtures will be pointer files"
fi

if [ "${SKIP_OPENCV:-0}" != 1 ]; then
  step "prebuilt OpenCV"
  "$ROOT/scripts/fetch_opencv.sh"
fi

if [ "${SKIP_REFERENCES:-0}" != 1 ]; then
  step "reference repos"
  "$ROOT/scripts/fetch_references.sh"
fi

step "python tools (tools/.venv)"
extras=()
for e in ${CKIT_EXTRAS:-dev}; do extras+=(--extra "$e"); done
if command -v uv >/dev/null 2>&1; then
  # Installs ckit in editable mode from the committed uv.lock.
  (cd tools && uv sync --locked "${extras[@]}")
else
  echo "uv not found; falling back to venv + pip (unlocked)"
  python3 -m venv tools/.venv
  spec="-e tools"
  [ -n "${CKIT_EXTRAS:-dev}" ] && spec="-e tools[$(echo ${CKIT_EXTRAS:-dev} | tr ' ' ',')]"
  tools/.venv/bin/pip install -q --upgrade pip
  # shellcheck disable=SC2086
  tools/.venv/bin/pip install -q $spec
fi
tools/.venv/bin/ckit --version

step "done"
echo "Next: cmake -S core -B build/core && cmake --build build/core && ctest --test-dir build/core"
