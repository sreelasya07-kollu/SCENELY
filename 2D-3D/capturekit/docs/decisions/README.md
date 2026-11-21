# docs/decisions

Architecture Decision Records (ADRs), one file per decision: NNNN-title.md.

## Index
- [0001](0001-jpeg-keyframes-not-video.md) JPEG keyframes + MCAP, not video.mp4
- [0002](0002-synthetic-golden-sessions.md) Synthetic stand-ins for golden sessions
- [0003](0003-intrinsics-pixel-centre.md) Platform intrinsics use the integer pixel-centre convention
- [0004](0004-ar-points-planes-channels.md) Bundle carries AR feature points and plane anchors
- [0005](0005-pixel-centre-check-by-calibration.md) Verify the pixel-centre convention with a checkerboard
- [0006](0006-sharpness-ratio-and-texture-gate.md) Sharpness is a fine/coarse Laplacian ratio, gated by coarse texture
- [0007](0007-thermal-state-mapping.md) Mapping OS thermal signals onto governor levels 0-3
- [0008](0008-shell-encodes-keyframe-jpegs.md) Core selects keyframes, shell encodes the JPEG (request/ack)
- [0009](0009-android-keyframes-from-arcore-cpu-image.md) Android keyframes from the ARCore CPU image; Camera2 stills deferred
- [0010](0010-guidance-coverage-and-free-space-model.md) Guidance coverage on planes, free space by carving, marginal-gain planning
- [0011](0011-guidance-evaluated-with-simulated-walker.md) Guidance evaluated with a simulated walker until real trials exist
- [0012](0012-jni-handle-map-not-raw-pointer.md) JNI handle map instead of raw pointer cast
- [0013](0013-overlay-snapshot-as-non-critical-event.md) Overlay snapshot ships as a non-critical event, not a C API accessor
- [0014](0014-speech-scheduler-in-kotlin-for-now.md) SpeechScheduler lives in Kotlin for now, not in the C++ core
- [0015](0015-sim-walker-hold-level-for-understanding-scenes.md) Sim walker hold_level mode for understanding scenes
- [0016](0016-detections-channel-schema-1-1-0.md) /ar/detections channel and schema 1.1.0
- [0017](0017-phase9-object-detector-efficientdet-lite0.md) Phase 9 object detector: EfficientDet-Lite0 (COCO), geometry-only fallback
- [0018](0018-delegated-decisions.md) Open human decisions settled by the planner while the user was away (revisit)
- [0019](0019-no-llm-dialog-proxy-now.md) State questions: fixed templates over a snapshot, no LLM client now
- [0020](0020-consent-privacy-schema-1-2-0.md) Consent and privacy in the manifest, schema 1.2.0
- [0021](0021-face-redaction-detector.md) Face redaction: android.media.FaceDetector now, BlazeFace gated on a licence read
- [0022](0022-overlay-v2-yaw-mask-and-wall-id.md) Overlay v2: yaw mask and wall id
- [0023](0023-guidance-defaults-sim-tuning-no-change.md) Guidance defaults after the C4 simulator sweep: no change (before/after table)
- [0024](0024-opening-detector-v1-parameters.md) OpeningDetector v1 parameters (sim-tuned hypotheses, revisit with real recordings)
- [0025](0025-device-bundle-fixes-time-zero-pause-redaction.md) Device-bundle fixes: t_ns <= 0 reject, pause-aware POSE_GAP, recovered redaction log, NO_KEYFRAMES
- [0026](0026-room-layout-model-overlay-v3.md) Room layout model (wall lines, blocked/missing spans), overlay v3, GuideParams gp2
- [0028](0028-guide-output-channels-schema-1-3-0.md) Derived /guide/labels, /guide/shell, /guide/gaps channels, schema 1.3.0
- [0029](0029-sim-arcore-plane-mode-furnished-rooms.md) Simulator "arcore" plane mode (fragments, re-ids, subsumption, jitter) and furnished4 / furnishedL rooms
- [0030](0030-object-classes-detector-default-on.md) More object classes (append-only ids), detector on by default, objects on the mini-map, camera boxes and review
- [0031](0031-tracking-recovery-recalibrate.md) Tracking recovery (issue #1): RECALIBRATE prompt, keyframe pause, TRACKING_LOST / TRACKING_RESET events
- [0032](0032-feature-flags-device-verified-only.md) Default build shows only device-verified features; FeatureFlags (guidance, detector, voice commands, recalibration card) off by default (issue #6; supersedes 0030 "detector default on")
- [0033](0033-keyframe-dedup-all-keyframes.md) Keyframe selection (issue #9): novelty against all saved keyframes, DUPLICATE reason, thresholds unchanged
- [0034](0034-lean-bundle-no-imu-archive.md) Lean bundle: IMU not recorded by default (schema 1.4.0), one compressed archive, keep/drop inventory (issue #10)
- [0035](0035-live-segmentation-and-object-memory.md) Live RF-DETR-Seg instance segmentation with per-scan object memory (Android green boxes)
- [0036](0036-still-calibration-and-imu-default.md) Pre-scan stillness calibration (contract C1), IMU recorded by default on Android
- [0037](0037-ios-parity-swift-ports.md) iOS parity with Android: Swift ports of the Kotlin app helpers (not moved into core), LiteRT-Swift in its own target
