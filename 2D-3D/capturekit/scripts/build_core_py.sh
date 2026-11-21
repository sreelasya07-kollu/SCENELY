#!/usr/bin/env bash
# Build the _ckcore Python module into $BUILD_DIR/py (default build/core-py; used by ckit, see tools/ckit/core.py).
# PYTHON: interpreter ckit runs under (default tools/.venv/bin/python). BUILD_DIR: override the build tree
# (point CKIT_CORE_DIR at $BUILD_DIR/py afterwards). WSL: see scripts/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-tools/.venv/bin/python}"
BUILD_DIR="${BUILD_DIR:-build/core-py}"
cmake -S core -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DCAPTUREKIT_BUILD_TESTS=OFF \
  -DCAPTUREKIT_BUILD_PYTHON=ON -DPython_EXECUTABLE="$(realpath "$PY")" >/dev/null
cmake --build "$BUILD_DIR" --target _ckcore capturekit_capi --parallel >/dev/null
echo "built $(ls "$BUILD_DIR"/py/_ckcore*.so) $(ls "$BUILD_DIR"/py/libcapturekit_capi.so)"
