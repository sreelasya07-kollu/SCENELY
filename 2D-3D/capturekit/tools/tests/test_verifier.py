"""Phase 7: verifier logic against a local tusd-layout store (no docker), plus tus client units."""

import hashlib
import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[2] / "dev-server" / "verifier"))
from bundle_verify import DirStore, Verifier  # noqa: E402

from ckit.upload import UploadResult, _meta, delete_after_verify  # noqa: E402


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class Fake:
    """Writes tusd-style objects: <key> and <key>.info (MetaData, Size)."""

    def __init__(self, root: Path, bundle_id="b1"):
        self.root, self.bid, self.n = root, bundle_id, 0

    def put(self, path: str, data: bytes, declared: bytes | None = None, complete=True, cut=None):
        self.n += 1
        key = f"u{self.n:04d}"
        meta = {
            "bundle_id": self.bid,
            "path": path,
            "sha256": sha(declared if declared is not None else data),
        }
        (self.root / f"{key}.info").write_text(json.dumps({"Size": len(data), "MetaData": meta}))
        if complete or cut:
            (self.root / key).write_bytes(data[:cut] if cut else data)
        time.sleep(0.002)  # distinct mtimes: latest upload of a path wins

    def manifest(self, files: dict[str, bytes], **kw):
        m = {"files": [{"path": p, "size": len(d), "sha256": sha(d)} for p, d in files.items()]}
        m["validation"] = {"verdict": "PASS"}
        self.put("manifest.json", json.dumps(m).encode(), **kw)


@pytest.fixture
def env(tmp_path):
    return Fake(tmp_path), Verifier(DirStore(tmp_path))


FILES = {"streams.mcap": b"a" * 1000, "camera.json": b"{}", "keyframes/000000.jpg": b"jpeg" * 50}


def test_pending_until_manifest(env):
    f, v = env
    f.put("streams.mcap", FILES["streams.mcap"])
    s = v.check("b1")
    assert s.status == "PENDING" and "manifest.json has not arrived" in s.reason


def test_complete(env):
    f, v = env
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    s = v.check("b1")
    assert s.status == "COMPLETE" and s.verdict == {"verdict": "PASS"}


def test_incomplete_missing_file_then_resolves_when_it_arrives(env):
    f, v = env
    f.put("streams.mcap", FILES["streams.mcap"])
    f.put("camera.json", FILES["camera.json"])
    f.manifest(FILES)
    s = v.check("b1")
    assert s.status == "INCOMPLETE" and s.missing == ["keyframes/000000.jpg"]
    f.put("keyframes/000000.jpg", FILES["keyframes/000000.jpg"])
    assert v.check("b1").status == "COMPLETE"


def test_truncated_upload_is_incomplete_not_complete(env):
    f, v = env
    f.put("streams.mcap", FILES["streams.mcap"])
    f.put("camera.json", FILES["camera.json"])
    f.put("keyframes/000000.jpg", FILES["keyframes/000000.jpg"], cut=60)  # object shorter than Size
    f.manifest(FILES)
    s = v.check("b1")
    assert s.status == "INCOMPLETE" and "keyframes/000000.jpg" in s.missing


def test_corrupted_chunk_detected_and_repaired_by_reupload(env):
    f, v = env
    bad = bytearray(FILES["streams.mcap"])
    bad[10] ^= 0xFF
    f.put("streams.mcap", bytes(bad), declared=FILES["streams.mcap"])
    f.put("camera.json", FILES["camera.json"])
    f.put("keyframes/000000.jpg", FILES["keyframes/000000.jpg"])
    f.manifest(FILES)
    s = v.check("b1")
    assert s.status == "CORRUPT" and s.corrupt[0]["path"] == "streams.mcap"
    f.put("streams.mcap", FILES["streams.mcap"])
    f.manifest(FILES)
    assert v.check("b1").status == "COMPLETE"


def test_tampered_file_after_manifest_is_corrupt(env):
    f, v = env
    for p, d in FILES.items():
        f.put(p, d if p != "camera.json" else b'{"x":1}')  # same size class, different bytes
    f.manifest(FILES)
    s = v.check("b1")
    assert s.status == "CORRUPT" and "camera.json" in s.reason


def test_size_mismatch_and_unreadable_manifest(env):
    f, v = env
    f.put("camera.json", b"{}" * 3)
    f.put("manifest.json", b"not json")
    assert v.check("b1").status == "CORRUPT"
    f2 = Fake(f.root, "b2")
    f2.put("camera.json", b"{}" * 3)
    f2.manifest({"camera.json": b"{}"})
    assert v.check("b2").corrupt[0]["reason"].startswith("size ")


def test_bundles_are_isolated(env):
    f, v = env
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    assert v.check("b1").status == "COMPLETE"
    assert v.check("other").status == "PENDING"


def test_status_recomputed_from_storage_after_restart(env):
    f, v = env
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    v2 = Verifier(DirStore(f.root))  # a fresh process: no memory of any hook event
    assert v2.check("b1").status == "COMPLETE"


def test_tus_metadata_encoding():
    assert _meta({"a": "x"}) == "a eA=="


def test_retention_requires_consent_and_complete(tmp_path):
    d = tmp_path / "b"
    d.mkdir()
    (d / "f").write_text("x")
    assert not delete_after_verify(d, UploadResult(status="COMPLETE"), consent=False) and d.exists()
    assert not delete_after_verify(d, UploadResult(status="CORRUPT"), consent=True) and d.exists()
    assert delete_after_verify(d, UploadResult(status="COMPLETE"), consent=True) and not d.exists()


# ---- server-side semantic validation, file route, job trigger ----------------------------

FROZEN = Path(__file__).parents[2] / "spec" / "scanbundle" / "examples" / "frozen-1.0.0"


def _upload_bundle(f: Fake, folder: Path) -> None:
    """Put every file of a real bundle folder into the fake tus store, manifest last."""
    for p in sorted(folder.rglob("*")):
        rel = p.relative_to(folder).as_posix()
        if p.is_file() and rel != "manifest.json":
            f.put(rel, p.read_bytes())
    f.put("manifest.json", (folder / "manifest.json").read_bytes())


def _tamper_nonmonotonic(folder: Path) -> None:
    """Swap two /pose messages in streams.mcap, re-hash the manifest (only the semantic error)."""
    from mcap.writer import Writer

    from ckit.bundle import DESC_PATH
    from ckit.bundle.streams import read_streams

    st = read_streams(folder / "streams.mcap")
    desc = DESC_PATH.read_bytes()
    with open(folder / "streams.mcap", "wb") as out:
        w = Writer(out)
        w.start("capturekit", "test")
        ids = {}
        for topic, msgs in st.messages.items():
            sid = w.register_schema(type(msgs[0]).DESCRIPTOR.full_name, "protobuf", desc)
            ids[topic] = w.register_channel(topic, "protobuf", sid)
        for topic, msgs in st.messages.items():
            msgs = list(msgs)
            if topic == "/pose":
                msgs[5], msgs[6] = msgs[6], msgs[5]
            for m in msgs:
                w.add_message(ids[topic], m.t_ns, m.SerializeToString(), m.t_ns)
        w.finish()
    man = json.loads((folder / "manifest.json").read_text())
    for e in man["files"]:
        data = (folder / e["path"]).read_bytes()
        e["size"], e["sha256"] = len(data), sha(data)
    (folder / "manifest.json").write_text(json.dumps(man, indent=2))


@pytest.fixture
def real_env(tmp_path):
    if not FROZEN.exists():
        pytest.skip("frozen-1.0.0 example not present")
    from bundle_verify import semantic_validator

    store = tmp_path / "store"
    store.mkdir()
    return Fake(store, "real"), Verifier(DirStore(store), validator=semantic_validator), tmp_path


def test_server_validation_passes_for_a_good_bundle(real_env):
    f, v, _ = real_env
    _upload_bundle(f, FROZEN)
    assert v.check("real").server_validation is None  # GET never validates
    v.validate("real")  # what the hook thread does
    s = v.check("real")
    assert s.status == "COMPLETE", s.reason
    assert s.server_validation["verdict"] in ("PASS", "WARN"), s.server_validation
    assert not [i for i in s.server_validation["issues"] if i["severity"] == "ERROR"]
    assert s.to_json()["server_validation"] == s.server_validation


def test_server_validation_fails_a_tampered_bundle_but_status_stays_complete(real_env):
    import shutil

    f, v, tmp = real_env
    bad = tmp / "bad"
    shutil.copytree(FROZEN, bad)
    _tamper_nonmonotonic(bad)
    _upload_bundle(f, bad)
    v.check("real")  # lists the bundle
    v.validate("real")
    s = v.check("real")
    assert s.status == "COMPLETE"  # uploaded intact: the verifier's status meaning is unchanged
    assert s.server_validation["verdict"] == "FAIL"
    assert "NON_MONOTONIC_TIME" in {i["code"] for i in s.server_validation["issues"]}


def test_server_validation_is_cached_per_manifest(tmp_path):
    calls = []
    f = Fake(tmp_path)
    v = Verifier(
        DirStore(tmp_path),
        validator=lambda root: (
            calls.append(sorted(p.name for p in root.iterdir()))
            or {"verdict": "PASS", "issues": []}
        ),
    )
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    assert v.check("b1").server_validation is None  # check() alone never runs the validator
    assert not calls
    v.validate("b1")
    v.validate("b1")
    assert v.check("b1").server_validation == {"verdict": "PASS", "issues": []}
    assert len(calls) == 1 and "manifest.json" in calls[0] and "camera.json" in calls[0]


def test_validator_crash_is_not_cached_so_a_retry_revalidates(tmp_path):
    f = Fake(tmp_path)

    def boom(root):
        raise RuntimeError("x")

    v = Verifier(DirStore(tmp_path), validator=boom)
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    v.check("b1")
    v.validate("b1")
    st = v.check("b1")
    assert st.server_validation is None and st.server_validation_state == "pending"  # not cached
    v.validator = lambda root: {"verdict": "PASS", "issues": []}
    v.validate("b1")  # the retry re-validates
    st = v.check("b1")
    assert st.server_validation["verdict"] == "PASS" and st.server_validation_state == "done"


def test_no_validator_leaves_server_validation_empty(env):
    f, v = env
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    assert v.check("b1").server_validation is None


def test_open_listed_serves_only_manifest_listed_files_of_complete_bundles(env):
    f, v = env
    for p, d in FILES.items():
        f.put(p, d)
    f.put("extra.bin", b"not listed")  # uploaded but not in the manifest
    assert v.open_listed("b1", "camera.json") is None  # no manifest yet: not COMPLETE
    f.manifest(FILES)
    body, size = v.open_listed("b1", "keyframes/000000.jpg")
    assert (
        size == len(FILES["keyframes/000000.jpg"]) and body.read() == FILES["keyframes/000000.jpg"]
    )
    body.close()
    assert v.open_listed("b1", "manifest.json") is not None
    for bad in ("extra.bin", "../x", "/etc/passwd", "keyframes\000000.jpg", "", "nope.json"):
        assert v.open_listed("b1", bad) is None, bad
    assert v.open_listed("other", "camera.json") is None


def test_post_job_posts_bundle_id_and_never_raises():
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    from bundle_verify import post_job

    got = []

    class H(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            got.append(
                (self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
            )
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert post_job(f"http://127.0.0.1:{srv.server_port}/", "bid-1", timeout=2)
    finally:
        srv.shutdown()
    assert got == [("/jobs", {"bundle_id": "bid-1"})]
    assert (
        post_job("http://127.0.0.1:9", "bid-1", timeout=1) is False
    )  # nothing listening: no exception


def test_open_listed_follows_a_reuploaded_manifest(env):
    f, v = env
    v.LISTING_TTL_S = 0.0  # always re-list
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    assert v.open_listed("b1", "camera.json") is not None
    new = dict(FILES, **{"extra.bin": b"new file"})
    f.put("extra.bin", new["extra.bin"])
    assert v.open_listed("b1", "extra.bin") is None  # old manifest does not list it
    f.manifest(new)
    body, _ = v.open_listed("b1", "extra.bin")
    assert body.read() == b"new file"
    body.close()


def test_server_validation_state_none_pending_done(tmp_path):
    f = Fake(tmp_path)
    plain = Verifier(DirStore(tmp_path))  # no validator configured
    v = Verifier(DirStore(tmp_path), validator=lambda root: {"verdict": "PASS", "issues": []})
    assert v.check("b1").server_validation_state == "none"  # not COMPLETE yet
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    assert plain.check("b1").server_validation_state == "none"
    assert v.check("b1").server_validation_state == "pending"  # COMPLETE, not validated yet
    v.validate("b1")
    s = v.check("b1")
    assert s.server_validation_state == "done" and s.to_json()["server_validation_state"] == "done"


def test_pending_validation_is_started_in_the_background_once(tmp_path):
    import threading

    f = Fake(tmp_path)
    gate, started, calls = threading.Event(), threading.Event(), []

    def slow(root):
        calls.append(1)
        started.set()
        gate.wait(5)
        return {"verdict": "PASS", "issues": []}

    v = Verifier(DirStore(tmp_path), validator=slow)
    for p, d in FILES.items():
        f.put(p, d)
    f.manifest(FILES)
    assert v.check("b1").server_validation_state == "pending"  # e.g. after a verifier restart
    assert v.start_validation("b1") is True  # returns at once
    assert started.wait(5)
    assert v.start_validation("b1") is False  # one already running
    assert v.check("b1").server_validation_state == "pending"
    gate.set()
    for _ in range(100):
        if v.check("b1").server_validation_state == "done":
            break
        time.sleep(0.05)
    assert v.check("b1").server_validation["verdict"] == "PASS" and len(calls) == 1
    assert v.start_validation("b1") is False  # result cached: nothing to start
