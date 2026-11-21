"""Runs one job: verifier check + bundle download -> spatial -> recon -> export -> qa.

Every pipeline stage is an existing CLI started with `sys.executable -m <module>`; this module
never imports spatial/recon/export/qa. Subclasses (tests) override `fetch_bundle` and `run`.

Failure rules (the contract in spec/jobs/job_status.schema.json):
- validate / spatial / export / qa are hard stages: a failure marks the later local stages
  skipped with a reason and the job `failed` (`rejected` when the server-side validation said FAIL).
- recon is soft: export and qa read only the SpatialMap, so a recon crash or a failed mesh (for
  example no OpenMVS image) is recorded on the recon stage and the job still finishes `done`.
- splat and splat_eval stay `pending` (where `gpu_worker`) while recon skipped the splat for lack
  of CUDA; they turn `ok` only through an attached reconstruction (jobs/attach.py).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

from jobs.store import JobStore, file_entry, get_stage, new_job, safe_rel, set_file, set_stage

PROJECT_ROOT = Path(__file__).resolve().parents[1]  # roomscan-recon/ (cwd of every stage)
DEFAULT_TIMEOUT_S = 6 * 3600
LATER = {  # stages that depend on a hard stage failing
    "validate": ["spatial", "recon", "export", "qa"],
    "spatial": ["recon", "export", "qa"],
    "export": ["qa"],
    "qa": [],
}
EXPORT_KINDS = {
    "floorplan.svg": "floorplan_svg",
    "floorplan.dxf": "floorplan_dxf",
    "room_shell.usda": "room_shell_usda",
    "fused_cloud.laz": "point_cloud_laz",
    "measurements.json": "measurements",
}


class StageFailed(Exception):
    pass


class Rejected(StageFailed):
    """The server-side semantic validation said FAIL: the bundle is not processed."""


@dataclass
class CmdResult:
    rc: int
    tail: str  # last lines of the combined output, for error messages
    text: str  # last ~4 kB of the combined output
    result: dict | None  # last JSON line the CLI printed


def _last_json(text: str) -> dict | None:
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                v = json.loads(line)
            except ValueError:
                continue
            if isinstance(v, dict):
                return v
    return None


class Runner:
    def __init__(
        self,
        store: JobStore,
        verifier_url: str | None = "http://localhost:8081",
        stage_timeout_s: float | None = DEFAULT_TIMEOUT_S,
    ) -> None:
        self.store = store
        self.verifier_url = (verifier_url or "").rstrip("/")
        self.timeout = stage_timeout_s

    # ---- overridable edges (tests replace these two) ----------------------------------------

    def fetch_bundle(self, bundle_id: str, dest: Path) -> dict | None:
        """Check the bundle at the verifier, download it to `dest`, return `server_validation`."""
        if not self.verifier_url:
            raise StageFailed("no verifier URL configured")
        base = f"{self.verifier_url}/bundles/{quote(bundle_id)}"
        st = self._get_json(base)
        if st.get("status") != "COMPLETE":
            raise StageFailed(f"bundle is {st.get('status')}: {st.get('reason')}")
        if (
            st.get("server_validation_state") == "pending"
        ):  # absent key = an older verifier: no validation
            raise StageFailed("server-side validation pending, retry shortly")
        sv = st.get("server_validation")
        if isinstance(sv, dict) and sv.get("verdict") == "FAIL":
            return sv  # the caller rejects; nothing is downloaded
        dest.mkdir(parents=True, exist_ok=True)
        self._download(f"{base}/files/manifest.json", dest / "manifest.json")
        manifest = json.loads((dest / "manifest.json").read_text(encoding="utf-8"))
        for e in manifest["files"]:
            rel = e["path"]
            if not safe_rel(rel):
                raise StageFailed(f"unsafe path in manifest: {rel!r}")
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            size, digest = self._download(f"{base}/files/{quote(rel, safe='/')}", target)
            if size != e.get("size", size) or digest != e.get("sha256", digest):
                raise StageFailed(f"downloaded {rel} differs from the manifest")
        return sv if isinstance(sv, dict) else None

    def run(self, cmd: list[str], log: Path, timeout: float | None = None) -> CmdResult:
        """Run a stage CLI with cwd = project root; output goes to `log`."""
        log.parent.mkdir(parents=True, exist_ok=True)
        env = {**os.environ, "PYTHONIOENCODING": "utf-8"}
        with open(log, "ab") as f:
            f.write(("$ " + " ".join(cmd) + "\n").encode())
            try:
                p = subprocess.run(  # noqa: S603 (argument list, no shell)
                    cmd,
                    cwd=PROJECT_ROOT,
                    env=env,
                    stdout=f,
                    stderr=subprocess.STDOUT,
                    timeout=timeout or self.timeout,
                )
                rc = p.returncode
            except subprocess.TimeoutExpired:
                rc = -9
                f.write(b"\n[job runner] stage timed out and was killed\n")
        raw = log.read_bytes()[-4000:].decode("utf-8", "replace")
        lines = [ln for ln in raw.splitlines() if ln.strip()]
        return CmdResult(rc, "\n".join(lines[-12:])[-700:], raw, _last_json(raw))

    # ---- http helpers -------------------------------------------------------------------------

    @staticmethod
    def _get_json(url: str) -> dict:
        try:
            with urllib.request.urlopen(url, timeout=30) as r:  # noqa: S310 (dev URL from config)
                return json.loads(r.read())
        except Exception as e:  # noqa: BLE001
            raise StageFailed(f"verifier request failed: {type(e).__name__}: {e}") from e

    @staticmethod
    def _download(url: str, dest: Path) -> tuple[int, str]:
        h, n = hashlib.sha256(), 0
        try:
            with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as out:  # noqa: S310
                while chunk := r.read(1 << 20):
                    out.write(chunk)
                    h.update(chunk)
                    n += len(chunk)
        except Exception as e:  # noqa: BLE001
            raise StageFailed(
                f"download failed ({url.rsplit('/', 1)[-1]}): {type(e).__name__}"
            ) from e
        return n, h.hexdigest()

    # ---- the job --------------------------------------------------------------------------------

    def process(self, bundle_id: str) -> dict:
        """Run (or re-run from scratch) one job to a final state; never raises."""
        d = self.store.dir(bundle_id)
        for child in d.iterdir():
            if child.name == "job.json" or child.name.endswith(".tmp"):
                continue
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink()
        self.store.update(bundle_id, lambda j: reset_job(j, bundle_id))
        try:
            self._pipeline(bundle_id, d)
        except Exception as e:  # noqa: BLE001 - a crash must end in a recorded state, not a hang
            job = self.store.load(bundle_id) or {"stages": []}
            running = [s["name"] for s in job["stages"] if s["status"] == "running"]
            pending = [s["name"] for s in job["stages"] if s["status"] == "pending"]
            stage = (running or pending or ["spatial"])[0]
            self._abort(bundle_id, stage, f"internal error: {type(e).__name__}: {e}", "failed")
        return self.store.load(bundle_id)  # type: ignore[return-value]

    def _stage(self, bundle_id: str, name: str, fn, *, soft: bool = False) -> bool:
        self.store.update(bundle_id, lambda j: set_stage(j, name, "running"))
        try:
            status, reason = fn()
        except Rejected:
            raise
        except StageFailed as e:
            status, reason = "failed", str(e)
        except Exception as e:  # noqa: BLE001 - recorded on the stage, never hidden
            status, reason = "failed", f"internal error: {type(e).__name__}: {e}"
        self.store.update(bundle_id, lambda j: set_stage(j, name, status, reason))
        if status == "failed" and not soft:
            raise StageFailed(f"{name}: {reason}")
        return status != "failed"

    def _abort(self, bundle_id: str, stage: str, msg: str, state: str) -> None:
        def f(j: dict) -> None:
            j["state"], j["error"] = state, f"{stage}: {msg}"
            if get_stage(j, stage)["status"] in ("pending", "running"):
                set_stage(j, stage, "failed", msg)
            for n in LATER.get(stage, ["recon", "export", "qa"]):
                if get_stage(j, n)["status"] in ("pending", "running"):
                    set_stage(
                        j,
                        n,
                        "skipped",
                        f"{stage} {'was rejected' if state == 'rejected' else 'failed'}",
                    )
            if get_stage(j, "spatial")["status"] != "ok":
                for n in ("splat", "splat_eval"):
                    set_stage(j, n, "skipped", "no SpatialMap was produced")

        self.store.update(bundle_id, f)

    def _pipeline(self, bid: str, d: Path) -> None:
        sm = d / "run" / "spatial_map"
        rec = d / "reconstruction"
        exp = d / "export"
        logs = d / "logs"
        try:
            self._stage(bid, "validate", lambda: self._validate(bid, d), soft=False)
            self._stage(bid, "spatial", lambda: self._spatial(bid, d, sm, logs))
            self._stage(bid, "recon", lambda: self._recon(bid, d, sm, rec, logs), soft=True)
            self._stage(bid, "export", lambda: self._export(bid, d, sm, exp, logs))
            self._stage(bid, "qa", lambda: self._qa(bid, d, sm, rec, logs))
        except Rejected as e:
            self._abort(bid, "validate", str(e), "rejected")
            return
        except StageFailed as e:
            stage, _, msg = str(e).partition(": ")
            self._abort(bid, stage, msg, "failed")
            return
        self.store.update(bid, lambda j: j.update(state="done", error=None))

    # ---- stages ---------------------------------------------------------------------------------

    def _validate(self, bid: str, d: Path) -> tuple[str, str | None]:
        sv = self.fetch_bundle(bid, d / "bundle")
        if sv:

            def put(j: dict) -> None:
                j["validation"] = {
                    "verdict": sv["verdict"],
                    "issues": [
                        {k: i[k] for k in ("code", "severity", "message")}
                        for i in sv.get("issues", [])
                    ],
                }

            self.store.update(bid, put)
            if sv["verdict"] == "FAIL" and any(
                i.get("code") == "VALIDATION_CRASH" for i in sv.get("issues", [])
            ):  # the verifier could not run its checks: not a verdict on the bundle, retryable
                raise StageFailed(
                    "server-side validation could not run (VALIDATION_CRASH); retry later"
                )
            if sv["verdict"] == "FAIL":
                codes = sorted(
                    {i["code"] for i in sv.get("issues", []) if i["severity"] == "ERROR"}
                )
                raise Rejected("server-side validation failed: " + ", ".join(codes))
            return "ok", None
        return "ok", "the verifier reported no server-side validation"

    def _spatial(self, bid: str, d: Path, sm: Path, logs: Path) -> tuple[str, str | None]:
        cmd = [sys.executable, "-m", "spatial.cli", "run", "--dataset", "capturekit"]
        cmd += ["--src", str(d / "bundle"), "--out", str(d / "run")]
        cmd += ["--prior", "device", "--keyframes"]
        r = self.run(cmd, logs / "spatial.log")
        if r.rc != 0:
            raise StageFailed(f"spatial.cli exited {r.rc}: {r.tail}")
        if not (sm / "manifest.json").is_file():
            raise StageFailed("spatial.cli finished but wrote no spatial_map/manifest.json")
        zpath = d / "spatial_map.zip"
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as z:
            for p in sorted(sm.rglob("*")):
                if p.is_file():
                    z.write(p, p.relative_to(sm).as_posix())
        entry = file_entry(
            d, bid, "spatial_map.zip", "spatial_map_zip", f"/jobs/{bid}/spatial_map.zip"
        )
        self.store.update(bid, lambda j: set_file(j, entry))
        return "ok", None

    def _recon_cmd(self, args: list[str]) -> list[str]:
        return [sys.executable, "-m", "recon.cli", *args]

    def _recon(self, bid: str, d: Path, sm: Path, rec: Path, logs: Path) -> tuple[str, str | None]:
        args = ["--spatial-map", str(sm), "--out", str(rec), "--splat", "auto"]
        r = self.run(self._recon_cmd(["run", *args]), logs / "recon.log")
        if r.rc != 0 and "unexpected extra argument" in r.text.lower():
            # T-030: recon.cli has one Typer command, so `run` is not a subcommand yet.
            shutil.rmtree(rec, ignore_errors=True)
            r = self.run(self._recon_cmd(args), logs / "recon.log")
        if r.rc != 0 or not (rec / "manifest.json").is_file():
            self._splat_pending(bid, "recon did not produce a reconstruction")
            raise StageFailed(f"recon.cli exited {r.rc}: {r.tail}")
        man = json.loads((rec / "manifest.json").read_text(encoding="utf-8"))
        outs = man.get("outputs", {})
        mesh = outs.get("mesh", {})
        for rel in mesh.get("files", []):
            if rel.endswith(".glb") and safe_rel(rel) and (rec / rel).is_file():
                entry = file_entry(d, bid, f"reconstruction/{rel}", "mesh_glb")
                self.store.update(bid, lambda j, e=entry: set_file(j, e))
                break
        self._splat_from_outputs(bid, outs.get("splat", {}))
        if mesh.get("status") != "ok":
            return "failed", f"mesh {mesh.get('status', 'missing')}: {mesh.get('reason')}"
        return "ok", None

    def _splat_pending(self, bid: str, why: str) -> None:
        def f(j: dict) -> None:
            set_stage(j, "splat", "pending", f"waiting for a GPU run ({why})")
            set_stage(j, "splat_eval", "pending", "waiting for the splat")

        self.store.update(bid, f)

    def _splat_from_outputs(self, bid: str, splat: dict) -> None:
        status, reason = splat.get("status"), splat.get("reason")
        if status == "ok":  # a local CUDA machine trained it
            m = splat.get("metrics", {})
            has_eval = all(k in m for k in ("lpips", "ssim"))

            def f(j: dict) -> None:
                set_stage(j, "splat", "ok", None)
                if has_eval:
                    set_stage(j, "splat_eval", "ok", metrics_text(m))
                else:
                    set_stage(j, "splat_eval", "skipped", "no held-out metrics were reported")

            self.store.update(bid, f)
        elif status == "failed":
            self.store.update(
                bid,
                lambda j: (
                    set_stage(j, "splat", "failed", reason),
                    set_stage(j, "splat_eval", "skipped", "splat failed"),
                ),
            )
        else:  # skipped for lack of CUDA (--splat auto): the GPU laptop does it
            self._splat_pending(bid, reason or "no CUDA device on this machine")

    def _export(self, bid: str, d: Path, sm: Path, exp: Path, logs: Path) -> tuple[str, str | None]:
        cmd = [
            sys.executable,
            "-m",
            "export.cli",
            "all",
            "--spatial-map",
            str(sm),
            "--out",
            str(exp),
        ]
        r = self.run(cmd, logs / "export.log")
        if r.rc != 0 or r.result is None:
            raise StageFailed(f"export.cli exited {r.rc}: {r.tail}")
        written, skipped = r.result.get("written", {}), r.result.get("skipped", {})
        entries = []
        for name in written:
            kind = EXPORT_KINDS.get(name)
            if kind and (exp / name).is_file():
                entries.append(file_entry(d, bid, f"export/{name}", kind))
        meas = None
        if (exp / "measurements.json").is_file():
            meas = json.loads((exp / "measurements.json").read_text(encoding="utf-8"))

        def f(j: dict) -> None:
            for e in entries:
                set_file(j, e)
            j["measurements"] = meas

        self.store.update(bid, f)
        note = "; ".join(f"{k}: {v}" for k, v in sorted(skipped.items())) or None
        return "ok", f"not exported: {note}" if note else None

    def qa_report(self, sm: Path, out: Path, rec: Path | None, log: Path) -> dict:
        cmd = [
            sys.executable,
            "-m",
            "qa.cli",
            "report",
            "--spatial-map",
            str(sm),
            "--out",
            str(out),
        ]
        if rec is not None:
            cmd += ["--reconstruction", str(rec)]
        r = self.run(cmd, log)
        if r.rc != 0 or not out.is_file():
            raise StageFailed(f"qa.cli exited {r.rc}: {r.tail}")
        return json.loads(out.read_text(encoding="utf-8"))

    def _qa(self, bid: str, d: Path, sm: Path, rec: Path, logs: Path) -> tuple[str, str | None]:
        rec_ok = (rec / "manifest.json").is_file()
        rep = self.qa_report(sm, d / "job_report.json", rec if rec_ok else None, logs / "qa.log")
        entry = file_entry(d, bid, "job_report.json", "job_report")
        self.store.update(bid, lambda j: apply_report(j, rep, entry))
        return "ok", None if rec_ok else "reconstruction missing: output gates were not evaluated"


def reset_job(job: dict, bundle_id: str) -> None:
    """Back to a clean running job (keeps `created`); used on a fresh run and on resume."""
    created = job["created"]
    job.clear()
    job.update(new_job(bundle_id))
    job["created"], job["state"] = created, "running"


def apply_report(job: dict, rep: dict, entry: dict) -> None:
    """Copy the capture verdict and rescan prompts from job_report.json into the contract."""
    job["verdict"] = rep.get("verdict")
    rescan = [
        {
            "surface": r["surface"],
            "reason": r["reason"],
            "priority": r["priority"],
            "area_m2": r["area_m2"],
            "instruction": r["instruction"],
        }
        for r in rep.get("rescan", [])
    ]
    job["rescan"] = sorted(rescan, key=lambda r: -r["priority"])
    set_file(job, entry)


def metrics_text(m: dict) -> str:
    parts = [f"{k.upper()} {m[k]:.4g}" for k in ("psnr", "ssim", "lpips") if k in m]
    return "held-out " + ", ".join(parts)
