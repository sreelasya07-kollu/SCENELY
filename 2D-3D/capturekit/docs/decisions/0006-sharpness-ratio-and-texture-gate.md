# 0006: Sharpness is a fine/coarse Laplacian ratio, gated by coarse texture
Status: accepted (2026-11-14). Raw variance-of-Laplacian depends on scene content, and FAST corners vanish
under blur, so neither can tell "blurred" from "blank wall". The core computes Laplacian variance on the
~320 px image (`sharpness`) and on a further 4x downscale (`texture`, barely affected by blur). Frames with
texture < `texture_min` get LOW_TEXTURE (soft), never BLUR. Otherwise `sharpness_norm` = (sharpness/texture)
divided by a running upper-envelope baseline of that ratio; BLUR is a hard reject below `sharp_reject`.
