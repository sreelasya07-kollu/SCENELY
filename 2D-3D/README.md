# 2D-3D: Intelligent Room Capture (SCENELY Part 1, mobile app)

This repository contains **Part 1** of SCENELY (see the [root README](../README.md)): native mobile capture applications and SDKs with on-device spatial intelligence.

## Components
- [capturekit/](capturekit/README.md) — Cross-platform phone capture SDK (iOS Swift + ARKit, Android Kotlin + ARCore, C++20 core, Python ckit bundle tools).
- capturekit/android/ — Native Android capture application and UI components with live video segmentation and HUD guidance.
- capturekit/tools/ckit/ — CLI tools for scan validation, quality assessment, and reconstruction benchmarking.
- docs/program-spec/ — Part 1 specification (part1-room-capture.md), the two-part overview, frozen conventions, and the Part 2 contract reference.

## Part 2 (same monorepo)
* Downstream **Part 2** (Spatial Understanding & 3D Gaussian Splatting Reconstruction) lives in [../roomscan-recon](../roomscan-recon/README.md).

## Documentation & Status
- [CaptureKit Overview](capturekit/README.md)
- [Current Status & Feature Flags](docs/STATUS.md)
- [Testing Log](docs/DEVICE_TEST_LOG.md)
- [Agent Guidelines](AGENTS.md)