# jobs: minimal job service (CR-001, T-032)

Single worker, stdlib HTTP, no accounts, no auth. Trusted LAN only. Runs on the host (WSL Ubuntu), not
in docker compose, because `recon/openmvs.py` starts `docker run` with host bind mounts.

```sh
cd roomscan-recon
uv run --extra cpu python -m jobs.server --port 8090 --data runs/jobs --verifier-url http://localhost:8081
```

| Route | Meaning |
|---|---|
| `POST /jobs` `{"bundle_id"}` | 202 new job, 200 already known (idempotent). `"retry": true` re-queues a `failed` job |
| `GET /jobs/<id>` | the `roomscan.job/1` contract, see `spec/jobs/job_status.schema.json` and `example_job.json` |
| `GET /jobs/<id>/files/<rel>` | only files listed in the job's `files` (404 otherwise, `..` refused) |
| `GET /jobs/<id>/spatial_map.zip` | the SpatialMap for the GPU laptop |
| `POST /jobs/<id>/attach` | zip of a `recon.cli` output; 409 if built from another SpatialMap |
| `GET /healthz` | liveness |

State lives in `<data>/<bundle_id>/job.json` (atomic writes). On restart, `queued` and `running` jobs
are re-run from scratch; finished jobs are kept.

Pipeline per job: verifier check + download -> `spatial.cli run --dataset capturekit --prior device
--keyframes` -> `recon.cli` (`--splat auto`) -> `export.cli all` -> `qa.cli report`. A failed hard stage
(validate, spatial, export, qa) fails the job and skips the later stages with a reason. A recon failure
(for example no `room-openmvs` image) is recorded on the recon stage; export and qa still run. The splat
stages stay `pending` (`gpu_worker`) until a reconstruction is attached.

## Finishing the splat on the GPU laptop

1. Download the SpatialMap: `curl -o sm.zip http://<server>:8090/jobs/<id>/spatial_map.zip`, unzip it to a folder `spatial_map/`.
2. On the GPU machine: `uv run --extra cu126 python -m recon.cli --spatial-map spatial_map --out reconstruction --splat yes`
   (use `recon.cli run ...` once T-030 is fixed).
3. Zip the `reconstruction/` folder as `r.zip` (manifest.json at the top, or inside one folder).
4. Attach it, either way:
   - `uv run --extra cpu python -m jobs.cli attach <id> r.zip --server http://<server>:8090`
   - on the server machine, ONLY while the job server is stopped: `uv run --extra cpu python -m jobs.cli attach <id> r.zip --data runs/jobs`
   - or `curl --data-binary @r.zip -H 'Content-Type: application/zip' http://<server>:8090/jobs/<id>/attach`

The attach verifies every hash, requires the same SpatialMap (`manifest_sha256`), requires a trained
splat, re-runs the Job Report with the reconstruction, flips `splat` / `splat_eval` to `ok` (eval only
when the run reported held-out metrics) and adds `splat_ply` to the files. Earlier results are kept.
