"""Server-side bundle verification (stdlib only; storage behind a small interface).

A Scan Bundle arrives as one tus upload per file with metadata {bundle_id, path, sha256}; the manifest
is uploaded LAST. Status is always recomputed from what is actually in storage (never from hook events),
so a missed hook or a restart cannot leave a bundle stuck:

  PENDING     no completed manifest.json yet
  INCOMPLETE  manifest arrived, some listed files are not (completely) uploaded
  CORRUPT     a listed file is complete but its size/sha256 differs from the manifest, or an upload's own
              declared sha256 differs from its bytes. Takes priority over INCOMPLETE.
  COMPLETE    manifest arrived and every listed file matches sha256 and size

A bundle can also arrive as ONE upload with path ``bundle.zip`` (ADR 0040, the Android app after Finish).
When the latest complete ``bundle.zip`` is newer than any manifest upload it is checked as a whole: its own
sha256 against the uploader's value, then ckit's ``verify_archive`` (every entry against the manifest inside).
COMPLETE lists the zip's entries as received; CORRUPT names ``bundle.zip``; a zip that has not fully arrived is
PENDING. ``open_listed`` then serves the entries out of the zip, so GET /bundles/<id>/files/<path> is unchanged.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import shutil
import tempfile
import threading
import time
import urllib.request
import weakref
import zipfile
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import BinaryIO, Callable, Iterator, Protocol

MANIFEST = "manifest.json"
ARCHIVE = "bundle.zip"  # tus metadata `path` of a whole-bundle zip upload
MAX_ISSUES = 50  # cap on issues reported per bundle in the status JSON
log = logging.getLogger("verifier")

# A validator takes a local bundle folder and returns {"verdict": PASS|WARN|FAIL, "issues": [...]}.
Validator = Callable[[Path], dict]


def semantic_validator(bundle: Path) -> dict:
    """Server-side semantic check = ``ckit.bundle.validate.validate(bundle, "semantic")``.

    ckit is imported lazily (it needs only jsonschema, mcap, protobuf; see the Dockerfile) so this
    module stays importable with the standard library alone.
    """
    from ckit.bundle.validate import validate

    rep = validate(bundle, "semantic")
    issues = [
        {"code": i.code, "severity": i.severity, "message": i.message + (f" [{i.where}]" if i.where else "")}
        for i in rep.issues
        if i.severity in ("ERROR", "WARN")
    ]
    return {"verdict": rep.verdict, "issues": issues[:MAX_ISSUES]}


def safe_rel_path(path: str) -> bool:
    """True for a plain relative POSIX path with no '..', no backslash and no drive/absolute part."""
    if not path or "\\" in path or "\x00" in path:
        return False
    p = PurePosixPath(path)
    return bool(p.parts) and not p.is_absolute() and ".." not in p.parts and "." not in p.parts and ":" not in p.parts[0]


def post_job(jobs_url: str, bundle_id: str, timeout: float = 5.0) -> bool:
    """Ask the job service to process a bundle (POST {jobs_url}/jobs). Never raises."""
    try:
        req = urllib.request.Request(
            jobs_url.rstrip("/") + "/jobs",
            data=json.dumps({"bundle_id": bundle_id}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (dev URL from env)
            return 200 <= r.status < 300
    except Exception as e:  # noqa: BLE001 (the tus upload must never be affected)
        log.warning("job trigger for %s failed: %s", bundle_id, type(e).__name__)
        return False


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
    server_validation: dict | None = None  # {verdict, issues}; None until the hook thread finished validating
    # none: no validator or not COMPLETE; pending: COMPLETE, result not ready; done: server_validation is set
    server_validation_state: str = "none"

    def to_json(self) -> dict:
        return {
            "bundle_id": self.bundle_id, "status": self.status, "reason": self.reason,
            "received": sorted(self.received), "missing": sorted(self.missing),
            "corrupt": self.corrupt, "verdict": self.verdict,
            "server_validation": self.server_validation,
            "server_validation_state": self.server_validation_state,
        }  # fmt: skip


class _ZipEntry:
    """One entry of a local zip as a readable stream (what open_listed returns); close() releases the zip too."""

    def __init__(self, path: Path, name: str) -> None:
        self._zf = zipfile.ZipFile(path)
        try:
            self.size = self._zf.getinfo(name).file_size
            self._fh = self._zf.open(name)
        except BaseException:
            self._zf.close()
            raise

    def read(self, n: int = -1) -> bytes:
        return self._fh.read(n)

    def close(self) -> None:
        self._fh.close()
        self._zf.close()

    def __enter__(self) -> _ZipEntry:
        return self

    def __exit__(self, *exc) -> None:
        self.close()


class Verifier:
    LISTING_TTL_S = 10.0  # open_listed re-lists storage at most this often per bundle
    ZIP_COPIES_KEPT = 2  # local copies of uploaded zips kept for serving entries (the oldest is deleted)

    def __init__(self, store: Store, validator: Validator | None = None) -> None:
        self.store = store
        self.validator = validator
        # zipfile needs a seekable file and S3 bodies are not: an uploaded zip is copied to a temp dir once.
        # (key, size, mtime) -> (local path, sha256 of the zip). Removed with the Verifier (weakref.finalize).
        self._zip_copies: OrderedDict[tuple[str, int, float], tuple[Path, str]] = OrderedDict()
        self._zip_dir: str | None = None
        self._zlock = threading.Lock()
        # zip sha256 -> (problems, entry names, the manifest's "validation" block); verify_archive reads every byte
        self._archive_cache: dict[str, tuple[list[str], list[str], dict | None]] = {}
        self._hash_cache: dict[tuple[str, int, float], str] = {}
        # (bundle_id, manifest sha256) -> completed result. Crashes are NOT cached, so a retry re-validates.
        self._validation_cache: dict[tuple[str, str], dict] = {}
        # bundle_id -> (manifest sha256, manifest Upload, files, path -> Upload, checked at)
        self._listing: dict[str, tuple[str, Upload, list[dict], dict[str, Upload], float]] = {}
        self._vlock = threading.Lock()  # one validation at a time; never held by check()
        self._running: set[str] = set()  # bundles with a background validation in flight
        self._crashed_at: dict[str, float] = {}
        self._rlock = threading.Lock()

    def validate(self, bundle_id: str) -> None:
        """Run the server-side validation for the last COMPLETE listing, if not cached yet.

        Slow (downloads the bundle). Call it from the hook thread WITHOUT holding any lock that GET
        handlers use. check() never calls it: it only reports a finished result.
        """
        lst = self._listing.get(bundle_id)
        if lst is None or self.validator is None:
            return
        sha, man, files, done, _ = lst
        key = (bundle_id, sha)
        with self._vlock:
            if key in self._validation_cache:
                return
            result = self._run_validation(bundle_id, man, files, done)
            if any(i["code"] == "VALIDATION_CRASH" for i in result["issues"]):
                self._crashed_at[bundle_id] = time.monotonic()  # not cached: a retry re-validates
            else:
                self._validation_cache[key] = result

    RETRY_AFTER_CRASH_S = 60.0  # GET polling does not restart a crashing validation more often

    def start_validation(self, bundle_id: str) -> bool:
        """Start validate() in a daemon thread when the result is pending and none is running.

        Non-blocking; covers a verifier restart (the hook already fired). True if a thread started.
        """
        lst = self._listing.get(bundle_id)
        if lst is None or self.validator is None or (bundle_id, lst[0]) in self._validation_cache:
            return False
        with self._rlock:
            crashed = self._crashed_at.get(bundle_id)
            if bundle_id in self._running:
                return False
            if crashed is not None and time.monotonic() - crashed < self.RETRY_AFTER_CRASH_S:
                return False
            self._running.add(bundle_id)

        def work() -> None:
            try:
                self.validate(bundle_id)
            except Exception:  # noqa: BLE001
                log.exception("background validation failed for %s", bundle_id)
            finally:
                with self._rlock:
                    self._running.discard(bundle_id)

        threading.Thread(target=work, daemon=True, name=f"validate-{bundle_id}").start()
        return True

    def _run_validation(self, bundle_id: str, man: Upload, files: list[dict], done: dict[str, Upload]) -> dict:
        try:
            with tempfile.TemporaryDirectory(prefix="verify-") as tmp:
                root = Path(tmp)
                if man.meta.get("path") == ARCHIVE:  # an untrusted zip: extract_archive refuses unsafe names and bombs
                    from ckit.bundle.archive import extract_archive

                    local, _ = self._local_zip(man)
                    return self.validator(extract_archive(local, root / "bundle"))  # type: ignore[misc]
                for path in [MANIFEST] + [e["path"] for e in files]:
                    if not safe_rel_path(path):
                        raise ValueError(f"unsafe path in manifest: {path!r}")
                    dest = root / path
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    with self.store.open(done[path].key) as src, open(dest, "wb") as out:
                        for chunk in iter_chunks(src):
                            out.write(chunk)
                return self.validator(root)  # type: ignore[misc]
        except Exception as e:  # noqa: BLE001
            log.exception("server-side validation crashed for %s", bundle_id)
            return {"verdict": "FAIL", "issues": [{
                "code": "VALIDATION_CRASH", "severity": "ERROR",
                "message": f"server-side validation could not run: {type(e).__name__}"}]}  # fmt: skip

    def open_listed(self, bundle_id: str, path: str) -> tuple[BinaryIO, int] | None:
        """Open one file of a COMPLETE bundle (manifest.json or a manifest-listed path), else None.

        The listing is refreshed from storage when older than LISTING_TTL_S, and it is keyed by the
        manifest sha256, so a re-uploaded manifest replaces it.
        """
        if not safe_rel_path(path):
            return None
        lst = self._listing.get(bundle_id)
        if lst is None or time.monotonic() - lst[4] > self.LISTING_TTL_S:
            if self.check(bundle_id).status != "COMPLETE":
                self._listing.pop(bundle_id, None)
                return None
            lst = self._listing[bundle_id]
        u = lst[3].get(path)
        if u is None:
            return None
        if u.meta.get("path") == ARCHIVE:  # the entry lives inside an uploaded zip
            local, _ = self._local_zip(u)
            entry = _ZipEntry(local, path)
            return entry, entry.size
        return self.store.open(u.key), u.stored_size

    def _local_zip(self, u: Upload) -> tuple[Path, str]:
        """(local copy, sha256) of an uploaded zip; copied once, a few copies are kept (see ZIP_COPIES_KEPT)."""
        ck = (u.key, u.stored_size, u.mtime)
        with self._zlock:
            hit = self._zip_copies.get(ck)
            if hit is not None and hit[0].exists():
                self._zip_copies.move_to_end(ck)
                return hit
            if self._zip_dir is None:
                self._zip_dir = tempfile.mkdtemp(prefix="verifier-zip-")
                weakref.finalize(self, shutil.rmtree, self._zip_dir, True)
            fd, name = tempfile.mkstemp(dir=self._zip_dir, suffix=".zip")
            dest, h = Path(name), hashlib.sha256()
            try:
                with self.store.open(u.key) as src, os.fdopen(fd, "wb") as out:
                    for chunk in iter_chunks(src):
                        h.update(chunk)
                        out.write(chunk)
            except BaseException:
                dest.unlink(missing_ok=True)
                raise
            self._zip_copies[ck] = (dest, h.hexdigest())
            while len(self._zip_copies) > self.ZIP_COPIES_KEPT:
                _, (old, _sha) = self._zip_copies.popitem(last=False)
                try:
                    old.unlink(missing_ok=True)
                except OSError:  # still open (Windows): the finalizer removes the whole directory later
                    pass
            return self._zip_copies[ck]

    def _check_archive(self, st: Status, arc: Upload) -> Status:
        """Status of a bundle that arrived as one bundle.zip upload."""
        from ckit.bundle.archive import verify_archive

        local, sha = self._local_zip(arc)
        declared = arc.meta.get("sha256")
        if declared and sha != declared:
            problems: list[str] = ["sha256 differs from the uploader's value"]
            names: list[str] = []
            validation = None
        else:
            if sha not in self._archive_cache:
                found = verify_archive(local)
                names, validation = [], None
                if not found:
                    with zipfile.ZipFile(local) as zf:
                        names = zf.namelist()
                        validation = json.loads(zf.read(MANIFEST)).get("validation")
                self._archive_cache[sha] = (found, names, validation)
            problems, names, validation = self._archive_cache[sha]
        if problems:
            reason = "; ".join(problems[:5])
            self._listing.pop(st.bundle_id, None)  # a damaged zip serves nothing, also not from an earlier listing
            st.status, st.reason = "CORRUPT", f"{ARCHIVE}: {reason}"
            st.corrupt.append({"path": ARCHIVE, "reason": reason})
            return st
        st.status, st.reason = "COMPLETE", f"{len(names)} files verified ({ARCHIVE})"
        st.received, st.verdict = list(names), validation
        self._listing[st.bundle_id] = (sha, arc, [{"path": n} for n in names if n != MANIFEST], {n: arc for n in names}, time.monotonic())
        if self.validator is not None:  # a finished result only; check() never validates
            st.server_validation = self._validation_cache.get((st.bundle_id, sha))
            st.server_validation_state = "done" if st.server_validation else "pending"
        return st

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
        arc = done.get(ARCHIVE)
        if arc is not None and (man is None or arc.mtime >= man.mtime):  # a whole-bundle zip, newer than any manifest
            return self._check_archive(st, arc)
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
            msha = self._sha256(man)
            listing = {p: done[p] for p in [MANIFEST] + [e["path"] for e in files]}
            self._listing[bundle_id] = (msha, man, files, listing, time.monotonic())
            if self.validator is not None:  # a finished result only; check() never validates
                st.server_validation = self._validation_cache.get((bundle_id, msha))
                st.server_validation_state = "done" if st.server_validation else "pending"
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
