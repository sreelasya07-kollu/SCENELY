"""HTTP front for the verifier: tusd post-finish hook + status API. S3/MinIO storage (boto3).

  POST /hook             tusd http hook (post-finish): logs, pre-verifies the bundle. Always 200.
  GET  /bundles/<id>     recomputed status JSON (PENDING/INCOMPLETE/CORRUPT/COMPLETE)
  GET  /healthz
"""

from __future__ import annotations

import json
import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

from bundle_verify import Store, Upload, Verifier

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
verifier = Verifier(store)
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, indent=2, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/healthz":
            return self._send(200, {"ok": True})
        if self.path.startswith("/bundles/"):
            bid = self.path.split("/")[2].split("?")[0]
            with lock:
                try:
                    return self._send(200, verifier.check(bid).to_json())
                except Exception as e:  # noqa: BLE001
                    log.exception("check failed")
                    return self._send(500, {"error": type(e).__name__})
        self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length", 0))
        try:
            ev = json.loads(self.rfile.read(n) or b"{}")
            meta = ev["Event"]["Upload"]["MetaData"]
            bid, path = meta.get("bundle_id"), meta.get("path")
            log.info("post-finish bundle=%s path=%s", bid, path)
            if bid and path == "manifest.json":
                with lock:
                    log.info("bundle %s -> %s", bid, verifier.check(bid).status)
        except Exception:  # noqa: BLE001
            log.exception("hook handling failed (status is recomputed on GET anyway)")
        self._send(200, {})  # never fail the upload because of the hook

    def log_message(self, *a):  # quiet
        pass


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
