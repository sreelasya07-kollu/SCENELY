"""HTTP front of the job service (stdlib only): one worker thread, one job at a time.

  POST /jobs                    {"bundle_id": "..."}  -> 202 (new, queued) | 200 (already known)
  GET  /jobs/<id>               the roomscan.job/1 contract (spec/jobs/job_status.schema.json)
  GET  /jobs/<id>/files/<rel>   a file listed in the job's `files` (404 for anything else)
  GET  /jobs/<id>/spatial_map.zip
  POST /jobs/<id>/attach        zip of a `recon.cli` output (GPU laptop) -> updated job
  GET  /healthz

No accounts, no auth: a development service for a trusted LAN (CR-001).
Run: `python -m jobs.server --port 8090 --data runs/jobs`
"""

from __future__ import annotations

import argparse
import json
import logging
import mimetypes
import queue
import shutil
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

from jobs.attach import AttachError, attach
from jobs.runner import Runner
from jobs.store import JobStore, safe_rel, valid_bundle_id

log = logging.getLogger("jobs")
MAX_ATTACH_BYTES = 8 * 2**30


class JobService:
    """The store, the runner and the single worker thread; the HTTP handler talks to this."""

    def __init__(self, store: JobStore, runner: Runner) -> None:
        self.store, self.runner = store, runner
        self.queue: queue.Queue[str] = queue.Queue()
        self._worker = threading.Thread(target=self._loop, daemon=True, name="job-worker")

    def start(self) -> None:
        for bid in self.store.ids():  # restart: unfinished jobs are re-queued, finished ones kept
            job = self.store.load(bid)
            if job and job["state"] in ("queued", "running"):
                log.info("resuming job %s (was %s)", bid, job["state"])
                self.queue.put(bid)
        self._worker.start()

    def submit(self, bundle_id: str, retry: bool = False) -> tuple[dict, bool]:
        """Returns (job, accepted). Idempotent: a known bundle is returned as it is."""
        job, created = self.store.create(bundle_id)
        if not created and retry and job["state"] == "failed":
            job = self.store.update(bundle_id, lambda j: j.update(state="queued", error=None))
            created = True
        if created:
            self.queue.put(bundle_id)
        return job, created

    def _loop(self) -> None:
        while True:
            bid = self.queue.get()
            try:
                log.info("job %s: start", bid)
                job = self.runner.process(bid)
                log.info("job %s: %s %s", bid, job["state"], job.get("error") or "")
            except Exception:  # noqa: BLE001 - the worker must survive any one job
                log.exception("job %s crashed the runner", bid)


class Handler(BaseHTTPRequestHandler):
    service: JobService  # set by make_server

    def log_message(self, *a) -> None:  # quiet
        pass

    def _json(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _parts(self) -> list[str]:
        return [p for p in unquote(self.path.split("?")[0]).split("/") if p != ""]

    def _file(self, path: Path, ctype: str | None = None) -> None:
        size = path.stat().st_size
        self.send_response(200)
        self.send_header(
            "Content-Type",
            ctype or mimetypes.guess_type(path.name)[0] or "application/octet-stream",
        )
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(path, "rb") as f:
            shutil.copyfileobj(f, self.wfile, 1 << 20)

    def do_GET(self) -> None:  # noqa: N802
        p = self._parts()
        if p == ["healthz"]:
            return self._json(200, {"ok": True})
        if len(p) >= 2 and p[0] == "jobs" and valid_bundle_id(p[1]):
            job = self.service.store.load(p[1])
            if job is None:
                return self._json(404, {"error": "no such job"})
            if len(p) == 2:
                return self._json(200, job)
            d = self.service.store.dir(p[1])
            if p[2:] == ["spatial_map.zip"]:
                z = d / "spatial_map.zip"
                if any(f["kind"] == "spatial_map_zip" for f in job["files"]) and z.is_file():
                    return self._file(z, "application/zip")
            elif p[2] == "files" and len(p) > 3:
                rel = "/".join(p[3:])
                prefix = f"/jobs/{p[1]}/files/"
                listed = {
                    unquote(f["url"][len(prefix) :])
                    for f in job["files"]
                    if f["url"].startswith(prefix)
                }
                if safe_rel(rel) and rel in listed:
                    target = (d / rel).resolve()
                    if target.is_file() and d.resolve() in target.parents:
                        return self._file(target)
            return self._json(404, {"error": "not found"})
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        p = self._parts()
        n = int(self.headers.get("Content-Length") or 0)
        if p == ["jobs"]:
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
                bid = body.get("bundle_id") if isinstance(body, dict) else None
            except ValueError:
                bid = None
            if not valid_bundle_id(bid):
                return self._json(400, {"error": 'body must be {"bundle_id": "<id>"}'})
            job, accepted = self.service.submit(bid, retry=bool(body.get("retry")))
            return self._json(202 if accepted else 200, job)
        if len(p) == 3 and p[0] == "jobs" and p[2] == "attach" and valid_bundle_id(p[1]):
            return self._attach(p[1], n)
        self._json(404, {"error": "not found"})

    def _attach(self, bid: str, n: int) -> None:
        st = self.service.store
        if st.load(bid) is None:
            return self._json(404, {"error": "no such job"})
        if n <= 0:
            return self._json(411, {"error": "Content-Length is required"})
        if n > MAX_ATTACH_BYTES:
            return self._json(413, {"error": "body too large"})
        tmp = st.dir(bid) / f"attach-upload.{threading.get_ident()}.tmp"
        try:
            left = n
            with open(tmp, "wb") as f:
                while left > 0:
                    chunk = self.rfile.read(min(1 << 20, left))
                    if not chunk:
                        return self._json(400, {"error": "body ended early"})
                    f.write(chunk)
                    left -= len(chunk)
            try:
                job = attach(st, self.service.runner, bid, tmp)
            except AttachError as e:
                return self._json(e.code, {"error": e.message})
            except Exception as e:  # noqa: BLE001 - never leave the client without an answer
                log.exception("attach to %s crashed", bid)
                return self._json(500, {"error": f"attach failed: {type(e).__name__}: {e}"})
            return self._json(200, job)
        finally:
            tmp.unlink(missing_ok=True)


def make_server(service: JobService, host: str = "127.0.0.1", port: int = 0) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"service": service})
    return ThreadingHTTPServer((host, port), handler)


def main() -> None:
    ap = argparse.ArgumentParser(description="Room Scanner job service (single worker, no auth).")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument(
        "--host", default="0.0.0.0", help="0.0.0.0 so phones and containers can reach it"
    )
    ap.add_argument("--data", default="runs/jobs", help="job folders live here")
    ap.add_argument("--verifier-url", default="http://localhost:8081")
    ap.add_argument("--stage-timeout-s", type=float, default=6 * 3600)
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    store = JobStore(a.data)
    service = JobService(store, Runner(store, a.verifier_url, a.stage_timeout_s))
    service.start()
    srv = make_server(service, a.host, a.port)
    log.info(
        "job service on %s:%s, data=%s (no auth: trusted LAN only)", a.host, a.port, store.root
    )
    srv.serve_forever()


if __name__ == "__main__":
    main()
