#!/usr/bin/env bash
# Smoke test against the local tusd: create an upload, send data, verify offset.
set -euo pipefail
TUSD="${TUSD:-http://localhost:1080/files/}"
DATA="hello capturekit"
LEN=${#DATA}

LOCATION=$(curl -fsS -i -X POST "$TUSD" \
  -H "Tus-Resumable: 1.0.0" -H "Upload-Length: $LEN" \
  -H "Upload-Metadata: filename $(printf 'smoke.txt' | base64)" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')
echo "created: $LOCATION"

curl -fsS -X PATCH "$LOCATION" \
  -H "Tus-Resumable: 1.0.0" -H "Upload-Offset: 0" \
  -H "Content-Type: application/offset+octet-stream" --data-binary "$DATA" -o /dev/null

OFFSET=$(curl -fsS -I "$LOCATION" -H "Tus-Resumable: 1.0.0" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="upload-offset"{print $2}')
echo "offset: $OFFSET / $LEN"
[ "$OFFSET" = "$LEN" ] && echo "SMOKE TEST OK"
