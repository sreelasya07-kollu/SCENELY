#!/usr/bin/env bash
# Download the on-device models into the Android library assets (gitignored, never committed; ADR 0017).
# Each file is pinned to one Hugging Face commit and one sha256: a changed file is rejected and deleted. Re-running is a
# no-op for files already present and matching. Without a file the app builds and that feature stays off.
#   fetch_models.sh                      Phase 9 object detector (4.6 MB)
#   fetch_models.sh --with-segmentation  also the RF-DETR-Seg Nano live object boxes (ADR 0035): two GPU graphs + four host constants (~62 MB)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT/android/capturekit/src/main/assets"
TMP=""   # the download in progress; removed on exit or interrupt
trap 'rm -f "${TMP:-}"' EXIT
trap 'rm -f "${TMP:-}"; exit 130' INT TERM

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch REPO COMMIT FILE SHA256 [ASSET_NAME]
fetch() {
  local repo="$1" commit="$2" file="$3" sha="$4" name="${5:-$3}"
  local dest="$DEST_DIR/$name"
  if [ -f "$dest" ] && [ "$(sha_of "$dest")" = "$sha" ]; then
    echo "models: $name already present and verified"
    return 0
  fi
  mkdir -p "$DEST_DIR"
  TMP="$(mktemp)"
  echo "models: downloading $name"
  if ! curl -fsSL --retry 3 -o "$TMP" "https://huggingface.co/${repo}/resolve/${commit}/${file}"; then
    echo "models: download failed for $name" >&2; return 1
  fi
  local got
  got="$(sha_of "$TMP")"
  if [ "$got" != "$sha" ]; then
    rm -f "$TMP"; TMP=""
    echo "models: sha256 mismatch for $name (expected $sha, got $got); not installed" >&2
    return 1
  fi
  mv "$TMP" "$dest"; TMP=""
  echo "models: ready in $dest"
}

# Phase 9 detector: litert-community/efficientdet, license apache-2.0.
fetch litert-community/efficientdet 360eea05e7de8f0d0f5602b548b5bbee6f7b65c7 \
  efficientdet_lite0_detection.tflite 33a3b622c7cac0762f96089353cd61495f3e993968d133af7871bfc2d5396704

if [ "${1:-}" = "--with-segmentation" ]; then
  # Live object boxes (feature flag `segmentation`, on by default but only active with these files). RF-DETR-Seg Nano,
  # litert-community/RF-DETR-Seg-Nano-LiteRT (Apache-2.0 card; base weights roboflow/rf-detr Apache-2.0).
  RFDETR=litert-community/RF-DETR-Seg-Nano-LiteRT
  RFDETR_REV=125acbf8b7e45fa3a245ce099579f8d805daaeed
  fetch $RFDETR $RFDETR_REV rfdetrseg_graphA_fp16.tflite 1b85a919c19a1832b729f546c3f60ceca179b669258d7ab244fac96890bf630a
  fetch $RFDETR $RFDETR_REV rfdetrseg_graphB_fp16.tflite 71ad26d20f3f5bc15b8fc73384a1ce3ad0ceb6b4f994bb042662641aea071ae7
  fetch $RFDETR $RFDETR_REV clspos.bin 11371e5ccb86a769f96e5eeb658f303715da8f26c4ff6158fef726a2ebd69bd8
  fetch $RFDETR $RFDETR_REV pospatch.bin f7e9ba735aa5b820ed4eb4604bea7c2082873815381b5ef069f67d881beb1d81
  fetch $RFDETR $RFDETR_REV query_feat.bin 936babdfe6f5f52c246d9b4453d879cb2743339868a99d23b90e7c88f34adec2
  fetch $RFDETR $RFDETR_REV refpoint_embed.bin e5713e5fe84a3df26598af65ce29e3a513097b20071849019b3e1f3a8c156c26
fi
