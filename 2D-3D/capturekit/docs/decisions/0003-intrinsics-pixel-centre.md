# 0003: Platform intrinsics use the integer pixel-centre convention
Status: assumption (2026-11-14). We assume ARKit `ARCamera.intrinsics` and ARCore `getImageIntrinsics()` put the
centre of the top-left pixel at (0,0), like OpenCV. COLMAP export adds +0.5 to cx, cy. The Phase 2 reprojection report on
device recordings must confirm this: a consistent ±0.5 px residual bias would mean the assumption is wrong.
