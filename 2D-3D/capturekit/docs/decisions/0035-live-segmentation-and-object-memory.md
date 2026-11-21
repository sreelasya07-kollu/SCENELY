# 0035 Live instance segmentation with per-scan object memory (Android)

Status: accepted (2026-11-22). Supersedes the SAM2 prompt segmenter (surface prompts); EfficientDet-Lite0 is unchanged.

- Model: RF-DETR-Seg Nano on LiteRT `CompiledModel` GPU (litert-community/RF-DETR-Seg-Nano-LiteRT, Apache-2.0), two graphs plus four small host tensors, fetched by `scripts/fetch_models.sh --with-segmentation` and never committed. Rejected: EdgeTAM (NPU-only evidence), SAM2.1-tiny (seconds per CPU run), YOLO-seg (AGPL), MobileSAM (stills). If GPU creation fails segmentation is disabled; there is no CPU fallback.
- Video = tracking by detection: the model has no memory, so identity lives in `TrackMemory` (same label, box IoU >= 0.3 or 3D centre <= 0.5 m, LRU 48). Memory lasts one scan. A track returns when its 3D centre (from `Frame.hitTest` on the job's own camera ray) projects back inside the image.
- EfficientDet-Lite0 still labels keyframes for the core ObjectLifter and the recorded `/ar/detections`; RF-DETR feeds only the live display and memory. RF-DETR class = COCO category id = EfficientDet id + 1 (unit-test pinned).
- Masks are not drawn; green boxes (label + #id): solid when seen in the last result, dashed "seen" when remembered. Rate <= 5 Hz x governor `mlRateScale` (guess).
