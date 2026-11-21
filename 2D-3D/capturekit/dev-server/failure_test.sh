#!/usr/bin/env bash
# Failure matrix against the real stack: airplane mode (server unreachable), app kill + resume,
# server restart, truncated upload, corrupted chunk, tampered file, consent/retention.
# Every case must end in a COMPLETE verified bundle or a clearly reported failure.
set -euo pipefail
cd "$(dirname "$0")"
COMPOSE=(docker compose -f "$PWD/docker-compose.yml")  # absolute: the trap may run from another directory
trap '"${COMPOSE[@]}" down -v >/dev/null 2>&1 || true' EXIT
"${COMPOSE[@]}" up -d --build >/dev/null
for i in $(seq 1 60); do
  curl -fsS localhost:8081/healthz >/dev/null 2>&1 && curl -fsS -o /dev/null -X OPTIONS localhost:1080/files/ -H 'Tus-Resumable: 1.0.0' && break
  sleep 1
done
cd ../tools
CKIT_DOCKER_TESTS=1 .venv/bin/pytest -q tests/test_upload_matrix.py "$@"
