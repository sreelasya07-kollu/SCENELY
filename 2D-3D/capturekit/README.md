# CaptureKit

CaptureKit is Part 1 (Intelligent Room Capture) of the two-part SCENELY program: a cross-platform phone SDK
(iOS: Swift + ARKit, Android: Kotlin + ARCore, with a shared C++20 core) that records
keyframe images, camera poses, IMU and exposure metadata, packages them as a versioned **Scan Bundle**
(`manifest.json` + `streams.mcap` + indexed JPEG keyframes + `camera.json` + checksums; ADR 0001), and uploads
them with the tus resumable-upload protocol. Python tooling (`ckit`) validates, inspects
and converts bundles for downstream reconstruction.

## Folder map

| Path | Purpose |
|---|---|
| `spec/scanbundle/` | Scan Bundle format spec, MCAP message schemas, valid/invalid examples |
| `core/` | C++20 static library `capturekit_core` (geometry, bundle, quality, governor) + bindings + tests |
| `ios/` | Swift Package `CaptureKit` (ARKit/AVFoundation/CoreMotion), tests, sample app |
| `android/` | Gradle project: `:capturekit` library (compiles `core/` via NDK) and `:sample-app` |
| `tools/` | Python package `ckit` (CLI `ckit`), converters in `ckit/convert` |
| `bench/` | Fixtures (Git LFS), thermal logs, pose comparison, calibration |
| `dev-server/` | Local tusd + MinIO stack (`docker compose`) |
| `config/` | Shared config; `*.local.json` overrides are gitignored |
| `docs/` | ADRs (`decisions/`) and interface contracts (`interfaces/`) |
| `third_party/` | Pinned git submodules (mcap, eigen, sophus, nanobind) — see `VERSIONS.md` |
| `reference/` | Read-only upstream repos for study (gitignored; never copy code from here) |
| `scripts/` | `bootstrap.sh`, `fetch_opencv.sh`, `fetch_references.sh` |

## How to bootstrap

Prerequisites: git, git-lfs, CMake ≥ 3.22 and a C++20 compiler, [uv](https://docs.astral.sh/uv/)
(or Python ≥ 3.11), Docker. Android: JDK 17+ and the Android SDK (AGP fetches the NDK).
iOS: macOS with Xcode 16.3+.

```sh
git clone --recurse-submodules <repo-url> && cd 2D-3D/capturekit
./scripts/bootstrap.sh            # submodules, OpenCV prebuilt, reference repos, tools/.venv

# C++ core
cmake -S core -B build/core && cmake --build build/core && ctest --test-dir build/core

# Python tools
tools/.venv/bin/ckit --version

# Android (from android/)
./gradlew assembleDebug testDebugUnitTest

# iOS (from ios/, macOS only)
swift build && swift test

# Upload dev server (from dev-server/)
docker compose up -d && ./smoke_test.sh
```

Never commit secrets, keystores, signing profiles or real scan data.

## Related Packages
- [roomscan-recon](../../roomscan-recon/README.md): Part 2, backend spatial understanding and 3D Gaussian Splatting reconstruction for CaptureKit Scan Bundles (same monorepo).
