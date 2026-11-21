# 0002: Synthetic stand-ins for golden sessions
Status: accepted (2026-11-14). No phones are attached to the build machine, so the 8 golden device recordings
(recording-protocol.md) cannot be made yet. `ckit synth G1..G8` renders deterministic textured-room sessions in the
exact raw layout, in ARKit pose convention, with IMU, AR points/planes, drift, blur, low light and tracking loss.
They drive Phases 1–9 tooling and CI. They do NOT satisfy device-acceptance items, which stay open in PROGRESS.md
until real recordings replace them under `bench/golden/` with the same names.
