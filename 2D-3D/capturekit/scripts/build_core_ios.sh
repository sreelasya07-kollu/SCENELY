#!/usr/bin/env bash
# Builds the C++ core as a static library for iOS (device + simulator) on a Mac.
# Output: build/ios-core/{device,simulator}/libcapturekit_core.a. Then:
#   CAPTUREKIT_CORE_LIB_DIR=$PWD/build/ios-core/device swift build   (from capturekit/ios)
# UNVERIFIED: written without access to a Mac; first run may need small toolchain fixes.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname)" = "Darwin" ] || { echo "needs macOS + Xcode"; exit 1; }
for target in "device:iphoneos:arm64" "simulator:iphonesimulator:arm64"; do
  IFS=: read -r name sdk arch <<<"$target"
  cmake -S core -B "build/ios-core/$name-cmake" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCAPTUREKIT_BUILD_TESTS=OFF >/dev/null
  cmake --build "build/ios-core/$name-cmake" --config Release --target capturekit_core >/dev/null
  mkdir -p "build/ios-core/$name"
  cp "build/ios-core/$name-cmake/Release-$sdk/libcapturekit_core.a" "build/ios-core/$name/"
  echo "built build/ios-core/$name/libcapturekit_core.a"
done
