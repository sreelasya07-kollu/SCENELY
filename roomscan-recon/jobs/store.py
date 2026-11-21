"""Job state on disk: `<data>/<bundle_id>/job.json` holds the `roomscan.job/1` contract itself.

Writes are atomic (tmp file + os.replace), so a crash or restart never leaves a half-written
job.json. Everything else a job owns (downloaded bundle, run folders, exports, attached
reconstructions) lives next to it in the same folder.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from urllib.parse import quote

SCHEMA = "roomscan.job/1"
# name, where
STAGES = (
    ("validate", "local"),
    ("spatial", "local"),
    ("recon", "local"),
    ("export", "local"),
    ("qa", "local"),
    ("splat", "gpu_worker"),
    ("splat_eval", "gpu_worker"),
)
FILE_KIND_ORDER = (
    "job_report",
    "measurements",
    "floorplan_svg",
    "floorplan_dxf",
    "room_shell_usda",
    "mesh_glb",
    "point_cloud_laz",
    "splat_ply",
    "spatial_map_zip",
)
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


def now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def valid_bundle_id(bid: object) -> bool:
    return isinstance(bid, str) and bool(_ID_RE.match(bid)) and ".." not in bid


def safe_rel(path: str) -> bool:
    """A plain relative POSIX path: no '..', no backslash, no drive letter, not absolute."""
    if not path or "\\" in path or "\x00" in path:
        return False
    p = PurePosixPath(path)
    return bool(p.parts) and not p.is_absolute() and ".." not in p.parts and ":" not in p.parts[0]


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def new_job(bundle_id: str) -> dict:
    t = now()
    return {
        "schema": SCHEMA,
        "bundle_id": bundle_id,
        "state": "queued",
        "created": t,
        "updated": t,
        "error": None,
        "validation": None,
        "stages": [{"name": n, "status": "pending", "reason": None, "where": w} for n, w in STAGES],
        "verdict": None,
        "rescan": [],
        "measurements": None,
        "files": [],
    }


def get_stage(job: dict, name: str) -> dict:
    return next(s for s in job["stages"] if s["name"] == name)


def set_stage(job: dict, name: str, status: str, reason: str | None = None) -> None:
    s = get_stage(job, name)
    s["status"], s["reason"] = status, reason


def file_entry(job_dir: Path, bundle_id: str, rel: str, kind: str, url: str | None = None) -> dict:
    p = job_dir / rel
    return {
        "name": p.name,
        "kind": kind,
        "url": url or f"/jobs/{bundle_id}/files/{quote(rel, safe='/')}",
        "size": p.stat().st_size,
        "sha256": sha256_of(p),
    }


def set_file(job: dict, entry: dict) -> None:
    """Add a file, replacing any earlier entry of the same kind (one result per kind)."""
    files = [f for f in job["files"] if f["kind"] != entry["kind"]] + [entry]
    files.sort(key=lambda f: FILE_KIND_ORDER.index(f["kind"]))
    job["files"] = files


class JobStore:
    def __init__(self, root: Path | str) -> None:
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._job_locks: dict[str, threading.Lock] = defaultdict(threading.Lock)

    def dir(self, bundle_id: str) -> Path:
        if not valid_bundle_id(bundle_id):
            raise ValueError(f"invalid bundle id: {bundle_id!r}")
        return self.root / bundle_id

    def op_lock(self, bundle_id: str) -> threading.Lock:
        """Serialises long operations on one job (attach), not the short job.json updates."""
        with self._lock:
            return self._job_locks[bundle_id]

    def load(self, bundle_id: str) -> dict | None:
        p = self.dir(bundle_id) / "job.json"
        for attempt in range(40):
            try:
                return json.loads(p.read_text(encoding="utf-8"))
            except FileNotFoundError:
                return None
            except (PermissionError, ValueError):  # mid-replace on Windows
                if attempt == 39:
                    raise
                time.sleep(0.025)
        return None

    def _write(self, job: dict) -> None:
        d = self.dir(job["bundle_id"])
        d.mkdir(parents=True, exist_ok=True)
        job["updated"] = now()
        tmp = d / f"job.json.{os.getpid()}.{threading.get_ident()}.tmp"
        tmp.write_text(json.dumps(job, indent=1), encoding="utf-8")
        for attempt in range(40):  # Windows refuses to replace a file a reader has open
            try:
                os.replace(tmp, d / "job.json")
                return
            except PermissionError:
                if attempt == 39:
                    raise
                time.sleep(0.025)

    def create(self, bundle_id: str) -> tuple[dict, bool]:
        """Idempotent: returns (job, created). One job per bundle id."""
        with self._lock:
            job = self.load(bundle_id)
            if job is not None:
                return job, False
            job = new_job(bundle_id)
            self._write(job)
            return job, True

    def update(self, bundle_id: str, fn) -> dict:
        with self._lock:
            job = self.load(bundle_id)
            if job is None:
                raise KeyError(bundle_id)
            fn(job)
            self._write(job)
            return job

    def ids(self) -> list[str]:
        return sorted(
            p.name for p in self.root.iterdir() if (p / "job.json").is_file() and p.is_dir()
        )
