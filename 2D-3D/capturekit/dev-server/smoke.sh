#!/usr/bin/env bash
# End-to-end smoke: bring the stack up, push a real (synthetic) Scan Bundle through tus with the
# `ckit upload` client, and require the server to mark it COMPLETE. Used by CI (job "upload").
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE=(docker compose -f "$PWD/docker-compose.yml")  # absolute: the trap may run from another directory
CKIT="${CKIT:-../tools/.venv/bin/ckit}"
WORK="${WORK:-$(mktemp -d)}"
trap '"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true' EXIT

"${COMPOSE[@]}" up -d --build >/dev/null
for i in $(seq 1 60); do
  curl -fsS localhost:8081/healthz >/dev/null 2>&1 && curl -fsS -o /dev/null -X OPTIONS localhost:1080/files/ -H 'Tus-Resumable: 1.0.0' && break
  sleep 1
done
$CKIT synth G7 "$WORK/raw" --duration 3 --seed 0 >/dev/null
$CKIT import-raw "$WORK/raw" "$WORK/src" >/dev/null
$CKIT simulate-capture "$WORK/src" "$WORK/bundle" >/dev/null
$CKIT validate "$WORK/bundle" --level quality | tail -1
$CKIT upload "$WORK/bundle" --consent | tee "$WORK/result.json"
grep -q '"status": "COMPLETE"' "$WORK/result.json" && echo "SMOKE OK"
