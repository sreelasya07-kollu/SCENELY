# 0005: Verify the pixel-centre convention with a checkerboard, not the reprojection report
Status: accepted (2026-11-14). Refining only the principal point (poses fixed) in pycolmap recovers an injected
+0.5 px error relative to a clean run (≈0.47 px). But on the 8 synthetic bundles the absolute estimate
scatters by ±0.1–2.6 px (drift and conditioning), even with short tracks only, so it cannot confirm ADR 0003.
The report keeps `refined_principal_point_delta_px` and the ±0.5 sweep as information only. ADR 0003 is
checked on each device by OpenCV checkerboard calibration of recorded frames compared with the platform intrinsics.
