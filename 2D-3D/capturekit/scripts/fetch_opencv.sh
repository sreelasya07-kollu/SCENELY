#!/usr/bin/env bash
# Download slim prebuilt mobile OpenCV (nihui/opencv-mobile) for iOS and Android
# into third_party/opencv-prebuilt/ (gitignored). Re-running is a no-op when present.
set -euo pipefail

OPENCV_MOBILE_RELEASE="v38"      # nihui/opencv-mobile release tag
OPENCV_VERSION="5.1.0"          # OpenCV version inside that release
PLATFORMS="${PLATFORMS:-ios ios-simulator android}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/third_party/opencv-prebuilt"
BASE="https://github.com/nihui/opencv-mobile/releases/download/${OPENCV_MOBILE_RELEASE}"

mkdir -p "$DEST"
for p in $PLATFORMS; do
  name="opencv-mobile-${OPENCV_VERSION}-${p}"
  if [ -d "$DEST/$name" ]; then
    echo "opencv: $name already present"
    continue
  fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "opencv: downloading $name.zip"
  curl -fsSL --retry 3 -o "$tmp/$name.zip" "$BASE/$name.zip"
  unzip -q "$tmp/$name.zip" -d "$tmp/x"
  # Android zips wrap everything in "$name/"; iOS zips contain opencv2.framework directly.
  if [ -d "$tmp/x/$name" ]; then
    mv "$tmp/x/$name" "$DEST/$name"
  else
    mv "$tmp/x" "$DEST/$name"
  fi
  rm -rf "$tmp"
  trap - EXIT
done
printf '%s %s\n' "$OPENCV_MOBILE_RELEASE" "$OPENCV_VERSION" > "$DEST/VERSION"
echo "opencv: ready in $DEST"
