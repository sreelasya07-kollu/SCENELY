#!/usr/bin/env bash
# Download the on-device models into the Android library assets (gitignored, never committed; ADR 0017).
# Each file is pinned to one Hugging Face commit and one sha256: a changed file is rejected and deleted. Re-running is a
# no-op for files already present and matching. Without a file the app builds and that feature stays off.
#   fetch_models.sh                      Phase 9 object detector (4.6 MB)
#   fetch_models.sh --with-segmentation  also the issue #8 SAM 2.1-tiny encoder + mask decoder + prompt constants (~97 MB)
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
  # Issue #8 segmentation overlay (feature flag `segmentation`, off by default). License apache-2.0 (facebook/sam2.1-hiera-tiny).
  fetch litert-community/SAM2.1-Hiera-Tiny-Image-Encoder d701df10082ef6bc9d5c47484070813578539df1 \
    sam2_tiny_image_encoder_v2_fp16.tflite 9f87693052c7c9bee2271f86d947420d7409ef0c2bec36c1885335afab90f6be
  fetch litert-community/SAM2.1-Hiera-Tiny-Mask-Decoder 049c2500a5f2c358f194dbc313eb20a68bc57222 \
    sam2_tiny_mask_decoder_v2_fp16.tflite 80d668b19156c548f31a8c8eb3cc1da2127de36e24e96ef923467a1e54c99e76
  fetch litert-community/SAM2.1-Hiera-Tiny-Mask-Decoder 049c2500a5f2c358f194dbc313eb20a68bc57222 \
    prompt_encode_const.bin c1ac798f0cc0bd5e4b0dc94efe26f2f9dfe4d1d4cec141ab0350580ce7a48588 sam2_tiny_prompt_encode_const.bin
fi
