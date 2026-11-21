"""Server-side bundle verification (stdlib only; storage behind a small interface).

A Scan Bundle arrives as one tus upload per file with metadata {bundle_id, path, sha256}; the manifest
is uploaded LAST. Status is always recomputed from what is actually in storage (never from hook events),
so a missed hook or a restart cannot leave a bundle stuck:

  PENDING     no completed manifest.json yet
  INCOMPLETE  manifest arrived, some listed files are not (completely) uploaded
  CORRUPT     a listed file is complete but its size/sha256 differs from the manifest, or an upload's own
              declared sha256 differs from its bytes. Takes priority over INCOMPLETE.
  COMPLETE    manifest arrived and every listed file matches sha256 and size
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import BinaryIO, Iterator, Protocol

MANIFEST = "manifest.json"


@dataclass
class Upload:
    key: str  # storage key of the finished object
    size: int  # declared tus Upload-Length
    meta: dict  # tus metadata (bundle_id, path, sha256, ...)
    mtime: float  # creation/modification time, for "latest upload of a path wins"
    complete: bool  # finished object present with the declared size
    stored_size: int = 0


class Store(Protocol):
    def uploads(self, bundle_id: str) -> list[Upload]: ...
    def open(self, key: str) -> BinaryIO: ...


@dataclass
class Status:
    bundle_id: str
    status: str
    reason: str = ""
    received: list[str] = field(default_factory=list)
    missing: list[str] = field(default_factory=list)
    corrupt: list[dict] = field(default_factory=list)
    verdict: dict | None = None

    def to_json(self) -> dict:
        return {
            "bundle_id": self.bundle_id, "status": self.status, "reason": self.reason,
            "received": sorted(self.received), "missing": sorted(self.missing),
            "corrupt": self.corrupt, "verdict": self.verdict,
        }  # fmt: skip


class Verifier:
    def __init__(self, store: Store) -> None:
        self.store = store
        self._hash_cache: dict[tuple[str, int, float], str] = {}

    def _sha256(self, u: Upload) -> str:
        ck = (u.key, u.stored_size, u.mtime)
        if ck not in self._hash_cache:
            h = hashlib.sha256()
            with self.store.open(u.key) as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            self._hash_cache[ck] = h.hexdigest()
        return self._hash_cache[ck]

    @staticmethod
    def _latest_complete(ups: list[Upload]) -> dict[str, Upload]:
        out: dict[str, Upload] = {}
        for u in sorted(ups, key=lambda x: x.mtime):
            p = u.meta.get("path")
            if p and u.complete:
                out[p] = u
        return out

    def check(self, bundle_id: str) -> Status:
        ups = self.store.uploads(bundle_id)
        done = self._latest_complete(ups)
        st = Status(bundle_id, "PENDING", received=list(done))
        man = done.get(MANIFEST)
        if man is None:
            st.reason = "manifest.json has not arrived (it is uploaded last)"
            partial = sorted({u.meta.get("path", "?") for u in ups if not u.complete})
            if partial:
                st.reason += f"; incomplete uploads: {', '.join(partial)}"
            return st
        try:
            with self.store.open(man.key) as f:
                manifest = json.loads(f.read().decode())
            files = manifest["files"]
        except Exception as e:  # noqa: BLE001
            st.status, st.reason = "CORRUPT", f"manifest.json unreadable: {type(e).__name__}"
            st.corrupt.append({"path": MANIFEST, "reason": "unreadable"})
            return st
        st.verdict = manifest.get("validation")
        declared = man.meta.get("sha256")
        if declared and self._sha256(man) != declared:
            st.corrupt.append({"path": MANIFEST, "reason": "sha256 differs from the uploader's value"})
        for entry in files:
            path = entry["path"]
            u = done.get(path)
            if u is None:
                st.missing.append(path)
                continue
            if u.stored_size != entry.get("size", u.stored_size):
                st.corrupt.append({"path": path, "reason": f"size {u.stored_size} != manifest {entry['size']}"})
                continue
            actual = self._sha256(u)
            if "sha256" in entry and actual != entry["sha256"]:
                st.corrupt.append({"path": path, "reason": "sha256 differs from the manifest"})
            elif u.meta.get("sha256") and actual != u.meta["sha256"]:
                st.corrupt.append({"path": path, "reason": "sha256 differs from the uploader's value"})
        if st.corrupt:
            st.status = "CORRUPT"
            st.reason = "; ".join(f"{c['path']}: {c['reason']}" for c in st.corrupt)
        elif st.missing:
            st.status = "INCOMPLETE"
            st.reason = f"{len(st.missing)} listed file(s) not uploaded yet: " + ", ".join(sorted(st.missing)[:5])
        else:
            st.status, st.reason = "COMPLETE", f"{len(files)} files verified"
        return st


class DirStore:
    """Test/local store: <root>/<key> object files and <root>/<key>.info JSON (tusd layout)."""

    def __init__(self, root) -> None:
        from pathlib import Path

        self.root = Path(root)

    def uploads(self, bundle_id: str) -> list[Upload]:
        out = []
        for info in sorted(self.root.glob("*.info")):
            d = json.loads(info.read_text())
            if d.get("MetaData", {}).get("bundle_id") != bundle_id:
                continue
            key = info.name[: -len(".info")]
            obj = self.root / key
            stored = obj.stat().st_size if obj.exists() else 0
            out.append(Upload(key, d["Size"], d["MetaData"], info.stat().st_mtime_ns / 1e9,
                              obj.exists() and stored == d["Size"], stored))  # fmt: skip
        return out

    def open(self, key: str) -> BinaryIO:
        return open(self.root / key, "rb")


def iter_chunks(f: BinaryIO, n: int = 1 << 20) -> Iterator[bytes]:
    return iter(lambda: f.read(n), b"")
