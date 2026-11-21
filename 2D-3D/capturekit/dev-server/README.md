# dev-server

Local resumable-upload stack for SDK development: **tusd** (tus protocol, port 1080)
storing into **MinIO** (S3 API on 9000, console on 9001). The `scanbundles` bucket is
created on startup by the one-shot `minio-init` service. Dev credentials only
(`capturekit` / `capturekit-dev-only`; override via `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`).

```sh
cd dev-server
docker compose up -d          # start
docker compose ps -a          # minio + tusd running, minio-init exited (0)
docker compose logs -f tusd   # follow tusd
docker compose down           # stop (keeps data volume)
docker compose down -v        # stop and wipe stored uploads
```

## Smoke test

`./smoke_test.sh` creates an upload, PATCHes 16 bytes and checks `Upload-Offset`. Manually:

```sh
curl -i -X POST http://localhost:1080/files/ \
  -H "Tus-Resumable: 1.0.0" -H "Upload-Length: 5"
# -> 201 Created, Location: http://localhost:1080/files/<id>
curl -i -X PATCH http://localhost:1080/files/<id> \
  -H "Tus-Resumable: 1.0.0" -H "Upload-Offset: 0" \
  -H "Content-Type: application/offset+octet-stream" --data-binary "hello"
# -> 204 No Content, Upload-Offset: 5
```

Uploaded objects are visible in the MinIO console at http://localhost:9001 (bucket `scanbundles`).

Phones on the LAN: point the SDK at `http://<your-machine-ip>:1080/files/`.

## Verifier (Phase 7)

`verifier` (port 8081) marks a bundle by what is actually in the bucket (never by hook events, so a missed
hook or restart cannot strand it): `PENDING` (no manifest yet), `INCOMPLETE` (manifest in, files missing),
`CORRUPT` (size/sha256 differ from the manifest), `COMPLETE`. tusd calls it on `post-finish`.

```sh
curl localhost:8081/bundles/<bundle_id>       # status JSON incl. missing/corrupt files and the on-device verdict
./smoke.sh                                    # stack + `ckit upload` of a real synthetic bundle -> COMPLETE
./failure_test.sh                             # 8-case failure matrix (airplane mode, kill, restart, truncation, ...)
```

Clients upload one file per tus upload with metadata `bundle_id`, `path`, `sha256`, and `manifest.json` last
(`tools/ckit/upload.py` is the reference; Kotlin and Swift mirror it). `docs/upload-test-protocol.md` lists the
device-only cases.
