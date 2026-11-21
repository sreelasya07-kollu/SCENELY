# 0037 iOS parity: Swift ports of the Kotlin app helpers, LiteRT-Swift runtime

Status: accepted (2026-11-22).

- The pure Kotlin app helpers (FeatureFlags, ConsentStore, StillnessCalibrator, voice tables, Completeness, TrackMemory, ObjectBoxes, JobStatus parse, ...) are ported to Swift in `ios/Sources/CaptureKit`, with test cases copied 1:1 from the Kotlin tests. AGENTS.md "one C++ implementation" covers the core; these are app-layer helpers, and moving them into the core is a large change outside this work (core/ is being changed by the Android work).
- Pure files import only Foundation (+simd), so the macOS host test target compiles them; iOS-only files sit under `#if os(iOS)`.
- Live segmentation runs RF-DETR-Seg Nano through LiteRT-Swift 2.3.0 (same .tflite files as Android) in a separate target `CaptureKitSegment`, so `CaptureKit` tests do not depend on LiteRT. Fallback only if a device spike fails: Core ML export behind the same Segmenter protocol.
- Contracts C1 to C4 and the job/verifier status keys are read as defined in the Android and backend briefs; nothing here changes them. Mac and iPhone checks are listed in docs/HUMAN_TESTS.md and have not been run.
