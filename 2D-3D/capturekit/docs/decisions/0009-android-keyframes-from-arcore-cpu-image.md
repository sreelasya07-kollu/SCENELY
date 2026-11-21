# 0009: Android keyframes come from the ARCore CPU image first; Camera2 stills deferred
Status: assumption (2026-11-14), to be measured on devices. ARCore owns the camera, so keyframes are encoded
from `Frame.acquireCameraImage()` (typically 640x480 to 1920x1080) and intrinsics from
`Camera.getImageIntrinsics()` refer to that same image. A parallel Camera2 still would give sharper, larger
images but contends for the camera and needs per-device pose-to-still alignment. Decision: ship option (a) and
add a device task (docs/capture-test-protocol.md, last section): record the CPU image resolution per device. If
it is below about 1280 px wide on the target tiers, prototype Camera2 stills alongside ARCore (scale_intrinsics
handles the resolution change) and supersede this ADR.
