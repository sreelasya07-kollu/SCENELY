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

## Server-side checks and the job service (phone scan -> results)

The verifier now also runs `ckit validate --level semantic` on a COMPLETE bundle (the image carries
`tools/ckit` and `spec/scanbundle`; build context is `capturekit/`). `GET /bundles/<id>` gains
`server_validation: {verdict, issues}` (PASS | WARN | FAIL; `status` keeps its old meaning) and `server_validation_state` (`none` = no validator or not COMPLETE, `pending` = result not ready, a GET starts the validation in the background, `done`). A job started while it is `pending` fails with "retry"; a validator crash is not cached and
`GET /bundles/<id>/files/<path>` streams one manifest-listed file. With `JOBS_URL` set, a COMPLETE
bundle whose verdict is not FAIL triggers `POST $JOBS_URL/jobs` (fire-and-forget, 5 s timeout, the tus
hook always answers 200).

End-to-end bring-up on this machine (Windows 11, WSL2 Ubuntu, Docker Desktop with WSL integration):

1. Install Docker Desktop, enable "Use WSL 2 based engine" and WSL integration for Ubuntu. Not installed yet at the time of writing.
2. In WSL, in `roomscan-recon`: `uv sync --extra cpu`, then build the OpenMVS image `room-openmvs:2.4.0` (see `roomscan-recon/docker/`).
3. Start the job service on the host: `uv run --extra cpu python -m jobs.server --port 8090 --data runs/jobs` (see `roomscan-recon/jobs/README.md`).
4. In WSL, in `dev-server`: `JOBS_URL=http://host.docker.internal:8090 docker compose up -d --build` (tusd 1080, verifier 8081, MinIO 9000/9001). `extra_hosts: host-gateway` makes `host.docker.internal` work on Linux Docker too.
5. Find the PC's LAN IP. Build the field APK with the upload URL `http://<ip>:1080/files/` and the verifier URL `http://<ip>:8081` (the Gradle properties of the field flavour); the job URL `http://<ip>:8090` is used by the results screen (phase P3). Allow ports 1080, 8081 and 8090 in the Windows firewall for the private network.
6. Upload with the app or `ckit upload <bundle> --consent`, then `curl localhost:8090/jobs/<bundle_id>`: `state` becomes `done`, the splat stages stay `pending`.
7. GPU laptop: follow "Finishing the splat on the GPU laptop" in `roomscan-recon/jobs/README.md`.

Cleartext HTTP, no auth, dev only.
