"""Job service (CR-001): contract, routes, failure rules, restart, GPU attach.

The stage CLIs and the verifier are replaced by `StubRunner`, which writes fixture files; the real
CLIs are covered by their own tests. Everything else (store, server, runner flow, attach) is real.
"""

from __future__ import annotations

import hashlib
import http.client
import io
import json
import threading
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from formats.models import OutputEntry, ReconstructionManifest
from jobs import cli as jobs_cli
from jobs.runner import CmdResult, Runner, StageFailed
from jobs.server import JobService, make_server
from jobs.store import JobStore

pytestmark = pytest.mark.light

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / "spec" / "jobs" / "job_status.schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA)
MEAS = {"floor_area_m2": 12.5, "perimeter_m": 14.2, "ceiling_height_m": 2.55, "warnings": []}
REPORT = {
    "verdict": "needs_rescan",
    "rescan": [
        {"surface": "wall", "reason": "unseen", "priority": 0.2, "area_m2": 1.0, "instruction": "b",
         "corners": [], "wall_index": 1},
        {"surface": "ceiling", "reason": "few_views", "priority": 0.9, "area_m2": 2.0,
         "instruction": "a", "corners": []},
    ],
}  # fmt: skip


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class StubRunner(Runner):
    """No verifier, no subprocess: writes what each stage CLI would write."""

    def __init__(self, store, *, validation=None, fail=None, mesh="failed", recon_run_ok=False):
        super().__init__(store, verifier_url="http://unused")
        self.validation = validation
        self.fail = fail  # stage module name that exits 1, e.g. "spatial.cli"
        self.mesh = mesh
        self.recon_run_ok = recon_run_ok  # True: `recon.cli run` works (T-030 fixed)
        self.calls: list[list[str]] = []

    def fetch_bundle(self, bundle_id, dest):
        if self.validation == "not-complete":
            raise StageFailed("bundle is INCOMPLETE: 2 listed file(s) not uploaded yet")
        if self.validation and self.validation["verdict"] == "FAIL":
            return self.validation
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "manifest.json").write_text("{}")
        return self.validation

    def run(self, cmd, log, timeout=None):
        self.calls.append(cmd)
        mod = cmd[cmd.index("-m") + 1]
        args = {a: cmd[i + 1] for i, a in enumerate(cmd) if a.startswith("--") and i + 1 < len(cmd)}
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(f"stub {mod}\n")
        if self.fail == mod:
            return CmdResult(1, "boom", "boom", None)
        if mod == "spatial.cli":
            sm = Path(args["--out"]) / "spatial_map"
            sm.mkdir(parents=True)
            (sm / "manifest.json").write_text('{"stub": "spatial-map"}')
            return CmdResult(0, "", "", {"spatial_map": str(sm)})
        if mod == "recon.cli":
            if "run" in cmd and not self.recon_run_ok:
                return CmdResult(2, "", "Got unexpected extra argument (run)", None)
            out = Path(args["--spatial-map"]).parent.parent / "reconstruction"
            assert Path(args["--out"]) == out
            out.mkdir(parents=True)
            outs = {"sparse": {"status": "ok"}}
            if self.mesh == "ok":
                (out / "mesh").mkdir()
                (out / "mesh" / "mesh.glb").write_bytes(b"glb")
                outs["mesh"] = {"status": "ok", "files": ["mesh/mesh.glb"]}
            else:
                outs["mesh"] = {"status": "failed", "reason": "OpenMVS image missing"}
            outs["splat"] = {
                "status": "skipped",
                "reason": "no CUDA device: splat training runs on the GPU machine",
            }
            (out / "manifest.json").write_text(json.dumps({"outputs": outs}))
            return CmdResult(0, "", "", {"reconstruction": str(out)})
        if mod == "export.cli":
            out = Path(args["--out"])
            out.mkdir(parents=True)
            names = ["floorplan.svg", "floorplan.dxf", "room_shell.usda", "fused_cloud.laz"]
            for n in names:
                (out / n).write_bytes(n.encode())
            (out / "measurements.json").write_text(json.dumps(MEAS))
            written = {n: True for n in [*names, "measurements.json"]}
            return CmdResult(0, "", "", {"written": written, "skipped": {}})
        if mod == "qa.cli":
            Path(args["--out"]).write_text(json.dumps(REPORT))
            return CmdResult(0, "", "", {"verdict": REPORT["verdict"]})
        raise AssertionError(cmd)


class Svc:
    def __init__(self, root: Path, runner_factory=StubRunner, **kw):
        self.store = JobStore(root)
        self.runner = runner_factory(self.store, **kw)
        self.service = JobService(self.store, self.runner)
        self.service.start()
        self.srv = make_server(self.service, "127.0.0.1", 0)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_port}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()

    def req(self, method, path, body=None, headers=None):
        data = json.dumps(body).encode() if isinstance(body, dict) else body
        r = urllib.request.Request(
            self.base + path, data=data, method=method, headers=headers or {}
        )
        try:
            with urllib.request.urlopen(r, timeout=20) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def get_job(self, bid):
        code, body = self.req("GET", f"/jobs/{bid}")
        return code, json.loads(body)

    def wait(self, bid, states=("done", "failed", "rejected"), timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            code, job = self.get_job(bid)
            if code == 200 and job["state"] in states:
                return job
            time.sleep(0.05)
        raise AssertionError(f"job {bid} did not finish: {job}")


@pytest.fixture
def svc(tmp_path):
    s = Svc(tmp_path / "jobs")
    yield s
    s.close()


def stage(job, name):
    return next(s for s in job["stages"] if s["name"] == name)


def valid(job):
    errs = sorted(VALIDATOR.iter_errors(job), key=lambda e: list(e.path))
    assert not errs, [f"{list(e.path)}: {e.message}" for e in errs[:3]]


def test_example_job_matches_the_schema():
    valid(json.loads((ROOT / "spec" / "jobs" / "example_job.json").read_text(encoding="utf-8")))


def test_post_is_idempotent_and_get_matches_the_schema(svc):
    code, body = svc.req("POST", "/jobs", {"bundle_id": "b-1"})
    assert code == 202 and json.loads(body)["state"] in ("queued", "running", "done")
    job = svc.wait("b-1")
    code2, body2 = svc.req("POST", "/jobs", {"bundle_id": "b-1"})
    assert code2 == 200 and json.loads(body2)["created"] == job["created"]
    assert svc.store.ids() == ["b-1"]
    assert sum(c[c.index("-m") + 1] == "spatial.cli" for c in svc.runner.calls) == 1  # ran once
    valid(job)
    assert job["state"] == "done" and job["error"] is None
    assert job["verdict"] == "needs_rescan"
    assert [r["instruction"] for r in job["rescan"]] == ["a", "b"]  # priority order, 5 keys only
    assert set(job["rescan"][0]) == {"surface", "reason", "priority", "area_m2", "instruction"}
    assert job["measurements"] == MEAS
    kinds = {f["kind"] for f in job["files"]}
    assert kinds == {"job_report", "measurements", "floorplan_svg", "floorplan_dxf",
                     "room_shell_usda", "point_cloud_laz", "spatial_map_zip"}  # fmt: skip


def test_bad_requests(svc):
    assert svc.req("POST", "/jobs", {"bundle_id": "../x"})[0] == 400
    assert svc.req("POST", "/jobs", b"not json")[0] == 400
    assert svc.req("GET", "/jobs/nope")[0] == 404
    assert svc.req("GET", "/jobs/..%2Fx")[0] == 404
    assert svc.req("GET", "/healthz")[0] == 200


def test_splat_stays_pending_and_failed_mesh_does_not_fail_the_job(svc):
    svc.req("POST", "/jobs", {"bundle_id": "b-2"})
    job = svc.wait("b-2")
    assert job["state"] == "done", job["error"]  # export and qa need only the SpatialMap
    assert stage(job, "recon")["status"] == "failed" and "OpenMVS" in stage(job, "recon")["reason"]
    for n in ("splat", "splat_eval"):
        s = stage(job, n)
        assert s["status"] == "pending" and s["where"] == "gpu_worker"
    assert stage(job, "export")["status"] == stage(job, "qa")["status"] == "ok"
    # T-030: `recon.cli run` was refused, then the plain form ran (and `run` was tried first)
    recon_calls = [c for c in svc.runner.calls if "recon.cli" in c]
    assert "run" in recon_calls[0] and "run" not in recon_calls[1]


def test_recon_run_subcommand_is_used_when_available(tmp_path):
    s = Svc(tmp_path / "jobs", recon_run_ok=True, mesh="ok")
    try:
        s.req("POST", "/jobs", {"bundle_id": "b-3"})
        job = s.wait("b-3")
        assert stage(job, "recon")["status"] == "ok"
        assert "mesh_glb" in {f["kind"] for f in job["files"]}
        assert len([c for c in s.runner.calls if "recon.cli" in c]) == 1
    finally:
        s.close()


def test_hard_stage_failure_skips_the_rest_and_fails_the_job(tmp_path):
    s = Svc(tmp_path / "jobs", fail="spatial.cli")
    try:
        s.req("POST", "/jobs", {"bundle_id": "b-4"})
        job = s.wait("b-4")
        valid(job)
        assert job["state"] == "failed" and job["error"].startswith("spatial: ")
        assert stage(job, "spatial")["status"] == "failed"
        for n in ("recon", "export", "qa", "splat", "splat_eval"):
            assert stage(job, n)["status"] == "skipped" and stage(job, n)["reason"], n
        assert job["verdict"] is None and job["files"] == []
    finally:
        s.close()


def test_server_validation_fail_rejects_the_bundle(tmp_path):
    v = {"verdict": "FAIL", "issues": [{"code": "NON_MONOTONIC_TIME", "severity": "ERROR",
                                         "message": "t goes back", "extra": 1}]}  # fmt: skip
    s = Svc(tmp_path / "jobs", validation=v)
    try:
        s.req("POST", "/jobs", {"bundle_id": "b-5"})
        job = s.wait("b-5")
        valid(job)
        assert job["state"] == "rejected" and "NON_MONOTONIC_TIME" in job["error"]
        assert job["validation"]["verdict"] == "FAIL"
        assert stage(job, "validate")["status"] == "failed"
        assert stage(job, "spatial")["status"] == "skipped"
        assert not any("spatial.cli" in c for c in s.runner.calls)
        assert s.req("POST", "/jobs", {"bundle_id": "b-5", "retry": True})[0] == 200  # not re-run
    finally:
        s.close()


def test_incomplete_bundle_fails_and_retry_requeues(tmp_path):
    s = Svc(tmp_path / "jobs", validation="not-complete")
    try:
        s.req("POST", "/jobs", {"bundle_id": "b-6"})
        job = s.wait("b-6")
        assert job["state"] == "failed" and "INCOMPLETE" in job["error"]
        s.runner.validation = None  # the upload finished meanwhile
        assert s.req("POST", "/jobs", {"bundle_id": "b-6"})[0] == 200  # plain POST: no re-run
        assert s.wait("b-6")["state"] == "failed"
        assert s.req("POST", "/jobs", {"bundle_id": "b-6", "retry": True})[0] == 202
        assert s.wait("b-6")["state"] == "done"
    finally:
        s.close()


def test_files_route_serves_listed_files_only_and_refuses_traversal(svc):
    svc.req("POST", "/jobs", {"bundle_id": "b-7"})
    job = svc.wait("b-7")
    svg = next(f for f in job["files"] if f["kind"] == "floorplan_svg")
    code, body = svc.req("GET", svg["url"])
    assert code == 200 and body == b"floorplan.svg" and sha(body) == svg["sha256"]
    assert len(body) == svg["size"]
    code, body = svc.req(
        "GET", next(f for f in job["files"] if f["kind"] == "spatial_map_zip")["url"]
    )
    assert code == 200 and zipfile.ZipFile(io.BytesIO(body)).namelist() == ["manifest.json"]
    for bad in (
        "/jobs/b-7/files/job.json",  # exists, not listed
        "/jobs/b-7/files/logs/spatial.log",
        "/jobs/b-7/files/export/nothing.txt",
        "/jobs/b-7/files/%2e%2e/job.json",
        "/jobs/b-7/files/export/%2e%2e/job.json",
        "/jobs/b-7/files/export%5Cfloorplan.svg",
    ):
        assert svc.req("GET", bad)[0] == 404, bad
    conn = http.client.HTTPConnection("127.0.0.1", svc.srv.server_port)
    conn.request("GET", "/jobs/b-7/files/../job.json")  # http.client sends the dots as they are
    assert conn.getresponse().status == 404
    conn.close()


def test_restart_reloads_state_and_resumes_unfinished_jobs(tmp_path):
    a = Svc(tmp_path / "jobs")
    a.req("POST", "/jobs", {"bundle_id": "done-1"})
    before = a.wait("done-1")
    # a job a crashed process left half way
    a.store.create("half-1")
    a.store.update("half-1", lambda j: j.update(state="running"))
    a.close()

    b = Svc(tmp_path / "jobs")  # new process, same folder
    try:
        assert b.get_job("done-1")[1] == before  # kept as is, not re-run
        assert not any("done-1" in " ".join(c) for c in b.runner.calls)
        assert b.wait("half-1")["state"] == "done"  # resumed from scratch
    finally:
        b.close()


# ---- GPU attach -------------------------------------------------------------------


def make_reconstruction(root: Path, sm_sha: str, *, splat_ok=True) -> Path:
    (root / "splat").mkdir(parents=True)
    ply = b"ply\nstub gaussian splat"
    (root / "splat" / "point_cloud.ply").write_bytes(ply)
    splat = (
        OutputEntry(status="ok", files=["splat/point_cloud.ply"],
                    metrics={"psnr": 24.1, "ssim": 0.88, "lpips": 0.21})
        if splat_ok else OutputEntry(status="skipped", reason="no CUDA")
    )  # fmt: skip
    man = ReconstructionManifest(
        created="2026-11-22T00:00:00Z",
        spatial_map={"path": "x", "manifest_sha256": sm_sha, "quality_warnings": []},
        outputs={"sparse": OutputEntry(status="ok"), "splat": splat},
        files={"splat/point_cloud.ply": sha(ply)},
        timings_s={}, peak_ram_mb=1.0, params={}, versions={},
    )  # fmt: skip
    (root / "manifest.json").write_text(man.model_dump_json(indent=1))
    return root


def zip_dir(src: Path, dest: Path, prefix: str = "") -> Path:
    with zipfile.ZipFile(dest, "w") as z:
        for p in sorted(src.rglob("*")):
            if p.is_file():
                z.write(p, prefix + p.relative_to(src).as_posix())
    return dest


def sm_sha(s: Svc, bid: str) -> str:
    return sha((s.store.dir(bid) / "run" / "spatial_map" / "manifest.json").read_bytes())


def test_attach_with_the_wrong_spatial_map_is_409(svc, tmp_path):
    svc.req("POST", "/jobs", {"bundle_id": "g-1"})
    svc.wait("g-1")
    rec = make_reconstruction(tmp_path / "rec", "0" * 64)
    z = zip_dir(rec, tmp_path / "r.zip")
    code, body = svc.req(
        "POST", "/jobs/g-1/attach", z.read_bytes(), {"Content-Type": "application/zip"}
    )
    assert code == 409 and b"SpatialMap" in body
    _, job = svc.get_job("g-1")
    assert stage(job, "splat")["status"] == "pending"
    assert not (svc.store.dir("g-1") / "attached" / "1").exists()  # nothing left behind


def test_attach_flips_the_splat_stages_and_keeps_earlier_results(svc, tmp_path):
    svc.req("POST", "/jobs", {"bundle_id": "g-2"})
    before = svc.wait("g-2")
    rec = make_reconstruction(tmp_path / "rec", sm_sha(svc, "g-2"))
    z = zip_dir(rec, tmp_path / "r.zip", prefix="reconstruction/")  # a folder inside the zip
    code, body = svc.req("POST", "/jobs/g-2/attach", z.read_bytes())
    assert code == 200, body
    job = json.loads(body)
    valid(job)
    assert stage(job, "splat")["status"] == "ok" and stage(job, "splat")["where"] == "gpu_worker"
    ev = stage(job, "splat_eval")
    assert ev["status"] == "ok" and "LPIPS" in ev["reason"] and "SSIM" in ev["reason"]
    assert job["state"] == "done" and job["measurements"] == before["measurements"]
    ply = next(f for f in job["files"] if f["kind"] == "splat_ply")
    assert svc.req("GET", ply["url"])[1] == b"ply\nstub gaussian splat"
    assert {f["kind"] for f in before["files"]} <= {f["kind"] for f in job["files"]}
    qa_calls = [c for c in svc.runner.calls if "qa.cli" in c]
    last = qa_calls[-1]
    assert "attached" in last[last.index("--reconstruction") + 1]  # re-run on the attached folder


def test_attach_refuses_bad_zips_and_unfinished_jobs(svc, tmp_path):
    svc.req("POST", "/jobs", {"bundle_id": "g-3"})
    svc.wait("g-3")
    assert svc.req("POST", "/jobs/g-3/attach", b"not a zip")[0] == 422
    evil = tmp_path / "evil.zip"
    with zipfile.ZipFile(evil, "w") as z:
        z.writestr("../escape.txt", "x")
    code, body = svc.req("POST", "/jobs/g-3/attach", evil.read_bytes())
    assert code == 422 and b"unsafe" in body
    assert not (svc.store.dir("g-3").parent / "escape.txt").exists()
    nosplat = make_reconstruction(tmp_path / "rec", sm_sha(svc, "g-3"), splat_ok=False)
    code, body = svc.req(
        "POST", "/jobs/g-3/attach", zip_dir(nosplat, tmp_path / "n.zip").read_bytes()
    )
    assert code == 422 and b"no trained splat" in body
    assert svc.req("POST", "/jobs/missing/attach", b"x")[0] == 404
    svc.store.create("g-4")  # queued, never run
    assert svc.req("POST", "/jobs/g-4/attach", b"x")[0] == 409


def test_jobs_cli_attach_in_local_mode(svc, tmp_path):
    svc.req("POST", "/jobs", {"bundle_id": "g-5"})
    svc.wait("g-5")
    rec = make_reconstruction(tmp_path / "rec", sm_sha(svc, "g-5"))
    z = zip_dir(rec, tmp_path / "r.zip")
    assert (
        jobs_cli.main(["attach", "g-5", str(z), "--data", str(svc.store.root)], runner=svc.runner)
        == 0
    )
    assert stage(svc.store.load("g-5"), "splat")["status"] == "ok"
    bad = make_reconstruction(tmp_path / "rec2", "1" * 64)
    assert jobs_cli.main(["attach", "g-5", str(zip_dir(bad, tmp_path / "b.zip")),
                          "--data", str(svc.store.root)], runner=svc.runner) == 1  # fmt: skip


def test_attach_409_then_good_attach_succeeds(svc, tmp_path):
    svc.req("POST", "/jobs", {"bundle_id": "g-6"})
    svc.wait("g-6")
    bad = zip_dir(make_reconstruction(tmp_path / "bad", "0" * 64), tmp_path / "bad.zip")
    assert svc.req("POST", "/jobs/g-6/attach", bad.read_bytes())[0] == 409
    good = zip_dir(make_reconstruction(tmp_path / "good", sm_sha(svc, "g-6")), tmp_path / "g.zip")
    code, body = svc.req("POST", "/jobs/g-6/attach", good.read_bytes())
    assert code == 200, body
    assert (svc.store.dir("g-6") / "attached" / "1" / "reconstruction").is_dir()
    assert stage(json.loads(body), "splat")["status"] == "ok"


def test_validation_crash_fails_the_job_instead_of_rejecting_it(tmp_path):
    v = {
        "verdict": "FAIL",
        "issues": [{"code": "VALIDATION_CRASH", "severity": "ERROR", "message": "could not run"}],
    }
    s = Svc(tmp_path / "jobs", validation=v)
    try:
        s.req("POST", "/jobs", {"bundle_id": "c-1"})
        job = s.wait("c-1")
        valid(job)
        assert job["state"] == "failed" and "VALIDATION_CRASH" in job["error"]
        assert stage(job, "validate")["status"] == "failed"
        assert s.req("POST", "/jobs", {"bundle_id": "c-1", "retry": True})[0] == 202  # retryable
    finally:
        s.close()


def test_internal_crash_is_reported_against_the_running_stage(tmp_path):
    class Boom(StubRunner):
        def _export(self, *a, **k):
            raise RuntimeError("kaboom")

        def _stage(self, bundle_id, name, fn, *, soft=False):
            if name == "qa":  # an error outside any stage function
                raise RuntimeError("outside")
            return super()._stage(bundle_id, name, fn, soft=soft)

    s = Svc(tmp_path / "jobs", Boom)
    try:
        s.req("POST", "/jobs", {"bundle_id": "c-2"})
        job = s.wait("c-2")
        assert job["state"] == "failed"
        assert job["error"].startswith("export: internal error: RuntimeError: kaboom")
        assert (
            stage(job, "export")["status"] == "failed" and stage(job, "qa")["status"] == "skipped"
        )
    finally:
        s.close()


def test_attach_crash_answers_500_json(svc, tmp_path, monkeypatch):
    svc.req("POST", "/jobs", {"bundle_id": "g-7"})
    svc.wait("g-7")

    def boom(*a, **k):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr("jobs.server.attach", boom)
    code, body = svc.req("POST", "/jobs/g-7/attach", b"zip")
    assert code == 500 and "disk on fire" in json.loads(body)["error"]


class PendingVerifierRunner(Runner):
    """Real fetch_bundle against a canned verifier answer; nothing may be downloaded."""

    def __init__(self, store, answer):
        super().__init__(store, verifier_url="http://verifier")
        self.answer = answer

    def _get_json(self, url):
        return self.answer

    def _download(self, url, dest):
        raise AssertionError("must not download while validation is pending")


def test_pending_server_validation_does_not_pass_the_job(tmp_path):
    answer = {"status": "COMPLETE", "server_validation": None, "server_validation_state": "pending"}
    s = Svc(tmp_path / "jobs", PendingVerifierRunner, answer=answer)
    try:
        s.req("POST", "/jobs", {"bundle_id": "p-1"})
        job = s.wait("p-1")
        assert job["state"] == "failed" and "pending" in job["error"]
        assert stage(job, "validate")["status"] == "failed"
        assert stage(job, "spatial")["status"] == "skipped"
        assert s.req("POST", "/jobs", {"bundle_id": "p-1", "retry": True})[0] == 202  # retryable
    finally:
        s.close()
