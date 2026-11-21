# 0001 — JPEG keyframes + MCAP, not video.mp4
Status: accepted (2026-11-14).
A-CaptureKit.md and capturekit/README.md describe a bundle with video.mp4. The Part 1 master prompt
freezes MCAP (Protobuf channels) + separate indexed high-quality JPEG keyframes instead, because
frame-exact extraction and per-frame intrinsics from HEVC/H.264 are painful.
Follow the master prompt. Update README/spec wording when Phase 1 writes SPEC.md.
