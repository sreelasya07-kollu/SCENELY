# 003: mcap and protobuf for reading CaptureKit Scan Bundles

- **Date:** 2026-11-22
- **Status:** Proposed
- **Decided by:** pending owner confirmation (brief `backend-app-connection`)
- **Task:** T-031
- **Related charter item:** Part 3 ingest (Scan Bundle input)

## Context
The Android app writes Scan Bundle v1.4.0 (`2D-3D/capturekit/spec/scanbundle/SPEC.md`): poses,
intrinsics and the frame index live in an MCAP file (`streams.mcap`) with Protobuf messages. The
v0.1 loader (`docs/SCAN_BUNDLE.md`) cannot read it. Neither `mcap` nor `protobuf` is in `uv.lock`.

## Options considered
1. `mcap` + `protobuf`, decoding with the FileDescriptorSet embedded in the file: no codegen, no
   copy of `capturekit.desc`; small pure-Python wheels (MIT, BSD-3).
2. Convert bundles to the v0.1 layout in `2D-3D` tooling: puts Part 2 format code into Part 1 and
   v0.1 has a single intrinsics block. Rejected.
3. Hand-written MCAP + protobuf parser: more code to get wrong. Rejected.

## Decision
Option 1. Pins in `pyproject.toml`: `mcap==1.6.0` (the version pinned by capturekit `tools/uv.lock`)
and `protobuf>=3.20.3,<6` (3.20.3 is the capturekit pin; the range lets uv resolve against the
recon lock).

## Consequences
- `uv.lock` gains `mcap`, `protobuf` (and `mcap`'s own dependencies).
- `docs/01-TECH-STACK.md` and `docs/MODELS.md` need no change (no model, no dataset); licences:
  mcap MIT, protobuf BSD-3-Clause.
- Only `spatial/io/capturekit.py` imports them.
