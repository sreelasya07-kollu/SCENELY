# ios

iOS SDK (Swift + ARKit), distributed as a Swift Package.

## Linking the C++ core (Phase 6, unverified on the dev machine)
`CaptureSession` talks to the core through the C API (`CCaptureKit`). The target is only added when the core
library is available, so plain `swift build` keeps working:
```sh
scripts/build_core_ios.sh                       # macOS only: libcapturekit_core.a for device + simulator
cd ios && CAPTUREKIT_CORE_LIB_DIR=$PWD/../build/ios-core/device swift build
```

## Live segmentation models (SampleApp, ADR 0037)
`CaptureKitSegment` runs RF-DETR-Seg Nano through LiteRT-Swift 2.3.0, with the same two files as Android
(`litert-community/RF-DETR-Seg-Nano-LiteRT`, HF rev `125acbf8b7e45fa3a245ce099579f8d805daaeed`):

| File | sha256 |
|---|---|
| `rfdetrseg_graphA_fp16.tflite` | `1b85a919c19a1832b729f546c3f60ceca179b669258d7ab244fac96890bf630a` |
| `rfdetrseg_graphB_fp16.tflite` | `71ad26d20f3f5bc15b8fc73384a1ce3ad0ceb6b4f994bb042662641aea071ae7` |

```sh
scripts/fetch_models.sh --with-segmentation   # downloads and sha256-checks into android/capturekit/src/main/assets
cp ../android/capturekit/src/main/assets/rfdetrseg_graph{A,B}_fp16.tflite SampleApp/Resources/   # then listed as bundle resources in project.yml (phase P3)
```
The sha256 values are pinned in `scripts/fetch_models.sh` (the Android RF-DETR change replaces the SAM 2.1 entries there);
if the script still lists SAM 2.1 files, those hashes above are the source of truth. Not run: there is no Mac on the dev machine.
