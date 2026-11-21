# scripts

Repository automation: bootstrap, dependency fetching.

## WSL (no Windows C++ toolchain, no root): Python env, `_ckcore`, `.desc`

Checked on Ubuntu WSL with system Python 3.14 (no pip, venv or Python.h): use user-level `uv`, which
also supplies a Python 3.12 with headers. Keep the venv and build tree in the WSL home (the repo may
hold a Windows `tools/.venv`):

    curl -fsSL https://astral.sh/uv/install.sh -o ~/uv-install.sh && UV_NO_MODIFY_PATH=1 sh ~/uv-install.sh
    export PATH=$HOME/.local/bin:$HOME/tools/cmake-3.31.6-linux-x86_64/bin:$PATH
    export UV_PROJECT_ENVIRONMENT=$HOME/ck-venv CKIT_CORE_DIR=$HOME/ck-build-core-py/py
    cd capturekit/tools && uv sync --python 3.12 --extra dev         # ~4 min first time
    cd .. && PYTHON=$HOME/ck-venv/bin/python BUILD_DIR=$HOME/ck-build-core-py scripts/build_core_py.sh
    cd tools && uv run pytest -q && uv run ckit validate ../spec/scanbundle/examples/frozen-1.0.0 --level semantic

Regenerate `spec/scanbundle/messages/capturekit.desc` after editing `capturekit.proto` (no `protoc`
on the box; `grpcio-tools` bundles one and reproduces the committed file byte for byte at HEAD):

    cd capturekit/spec/scanbundle/messages
    uv tool run --python 3.12 --from grpcio-tools python -m grpc_tools.protoc -I. \
      --descriptor_set_out=capturekit.desc capturekit.proto
