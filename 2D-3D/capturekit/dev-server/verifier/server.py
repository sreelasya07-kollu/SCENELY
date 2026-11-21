"""HTTP front for the verifier: tusd post-finish hook + status API. S3/MinIO storage (boto3).

  POST /hook             tusd http hook (post-finish): logs, pre-verifies the bundle. Always 200.
  GET  /bundles/<id>     recomputed status JSON (PENDING/INCOMPLETE/CORRUPT/COMPLETE) plus
                         server_validation {verdict, issues} once COMPLETE
  GET  /bundles/<id>/files/<path>   one manifest-listed file of a COMPLETE bundle (404 otherwise)
  GET  /healthz
"""

from __future__ import annotations

import json
import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from bundle_verify import Store, Upload, Verifier, iter_chunks, post_job, semantic_validator

log = logging.getLogger("verifier")
BUCKET = os.environ.get("S3_BUCKET", "scanbundles")


class S3Store(Store):
    def __init__(self) -> None:
        self.s3 = boto3.client(
            "s3",
            endpoint_url=os.environ.get("S3_ENDPOINT", "http://minio:9000"),
            aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "capturekit"),
            aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "capturekit-dev-only"),
            region_name="us-east-1",
            config=Config(retries={"max_attempts": 5}, s3={"addressing_style": "path"}),
        )

    def uploads(self, bundle_id: str) -> list[Upload]:
        out = []
        for page in self.s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
            for o in page.get("Contents", []):
                if not o["Key"].endswith(".info"):
                    continue
                info = json.loads(self.s3.get_object(Bucket=BUCKET, Key=o["Key"])["Body"].read())
                meta = info.get("MetaData") or {}
                if meta.get("bundle_id") != bundle_id:
                    continue
                key = o["Key"][: -len(".info")]
                try:
                    stored = self.s3.head_object(Bucket=BUCKET, Key=key)["ContentLength"]
                    exists = True
                except ClientError:
                    stored, exists = 0, False
                out.append(Upload(key, info["Size"], meta, o["LastModified"].timestamp(),
                                  exists and stored == info["Size"], stored))  # fmt: skip
        return out

    def open(self, key: str):
        return self.s3.get_object(Bucket=BUCKET, Key=key)["Body"]


store = S3Store()
verifier = Verifier(store, validator=semantic_validator)
JOBS_URL = os.environ.get("JOBS_URL", "")
lock = threading.Lock()


def after_manifest(bid: str) -> None:
    """Pre-verify a bundle; when it is COMPLETE and passes the server checks, ask the job service to run."""
    try:
        with lock:
            st = verifier.check(bid)
        if st.status == "COMPLETE":
            verifier.validate(bid)  # slow: downloads the bundle; the lock is NOT held (GETs stay fast)
            with lock:
                st = verifier.check(bid)
        verdict = (st.server_validation or {}).get("verdict")
        log.info("bundle %s -> %s (server validation %s)", bid, st.status, verdict)
        if st.status == "COMPLETE" and st.server_validation_state != "pending" and verdict != "FAIL" and JOBS_URL:
            post_job(JOBS_URL, bid, timeout=5.0)
    except Exception:  # noqa: BLE001
        log.exception("post-manifest handling failed for %s", bid)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, indent=2, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self) -> None:
        """GET /bundles/<id>/files/<path>: stream one manifest-listed file (404 for anything else)."""
        rest = unquote(self.path.split("?")[0])[len("/bundles/") :]
        bid, _, rel = rest.partition("/files/")
        try:
            with lock:
                opened = verifier.open_listed(bid, rel)
        except Exception:  # noqa: BLE001
            log.exception("file lookup failed")
            return self._send(500, {"error": "lookup failed"})
        if opened is None:
            return self._send(404, {"error": "not found"})
        body, size = opened
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            for chunk in iter_chunks(body):
                self.wfile.write(chunk)
        finally:
            body.close()

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        if self.path.startswith("/bundles/") and "/files/" in self.path:
            return self._send_file()
        if self.path.startswith("/bundles/"):
            bid = self.path.split("/")[2].split("?")[0]
            with lock:
                try:
                    st = verifier.check(bid)
                    body = st.to_json()
                except Exception as e:  # noqa: BLE001
                    log.exception("check failed")
                    return self._send(500, {"error": type(e).__name__})
            if st.server_validation_state == "pending":
                verifier.start_validation(bid)  # non-blocking; the next GET sees the result
            return self._send(200, body)
        self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length", 0))
        try:
            ev = json.loads(self.rfile.read(n) or b"{}")
            meta = ev["Event"]["Upload"]["MetaData"]
            bid, path = meta.get("bundle_id"), meta.get("path")
            log.info("post-finish bundle=%s path=%s", bid, path)
            if bid and path == "manifest.json":
                # Off the request thread: validation may download the bundle, and the hook must answer at once.
                threading.Thread(target=after_manifest, args=(bid,), daemon=True).start()
        except Exception:  # noqa: BLE001
            log.exception("hook handling failed (status is recomputed on GET anyway)")
        self._send(200, {})  # never fail the upload because of the hook

    def log_message(self, *a):  # quiet
        pass


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
