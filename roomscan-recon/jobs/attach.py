"""Attach a GPU-laptop reconstruction (zip of a `recon.cli` output folder) to a finished job.

The zip is unpacked safely, verified with `formats.reconstruction.load_reconstruction`, and must
have been built from exactly this job's SpatialMap (manifest sha256 match, else 409). Then the
Job Report is re-run with the reconstruction, `splat` / `splat_eval` flip from pending to ok, and
`splat_ply` joins the files. Earlier results stay on disk and in the contract.
"""

from __future__ import annotations

import os
import shutil
import zipfile
from pathlib import Path

from formats.reconstruction import load_reconstruction
from jobs.runner import Runner, StageFailed, apply_report, metrics_text
from jobs.store import JobStore, file_entry, safe_rel, set_file, set_stage, sha256_of

MAX_UNPACKED_BYTES = 16 * 2**30


class AttachError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code, self.message = code, message


def _unpack(zip_path: Path, dest: Path) -> None:
    """Extract entry by entry; refuse absolute/`..`/backslash names, symlinks and huge archives."""
    try:
        z = zipfile.ZipFile(zip_path)
    except zipfile.BadZipFile as e:
        raise AttachError(422, "the body is not a zip file") from e
    with z:
        infos = z.infolist()
        if sum(i.file_size for i in infos) > MAX_UNPACKED_BYTES:
            raise AttachError(422, "zip is too large when unpacked")
        for i in infos:
            name = i.filename.rstrip("/")
            if not safe_rel(name):
                raise AttachError(422, f"unsafe path in zip: {i.filename!r}")
            if (i.external_attr >> 16) & 0o170000 == 0o120000:
                raise AttachError(422, f"symbolic link in zip: {i.filename!r}")
        for i in infos:
            target = dest / i.filename.rstrip("/")
            if i.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(i) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)


def _reconstruction_root(tmp: Path) -> Path:
    if (tmp / "manifest.json").is_file():
        return tmp
    kids = [p for p in tmp.iterdir() if p.is_dir() and (p / "manifest.json").is_file()]
    if len(kids) == 1:
        return kids[0]
    raise AttachError(422, "no manifest.json at the top of the zip (or in its one folder)")


def attach(store: JobStore, runner: Runner, bundle_id: str, zip_path: Path) -> dict:
    """Attach `zip_path` to the job; returns the updated job. Raises AttachError(code, message)."""
    with store.op_lock(bundle_id):
        job = store.load(bundle_id)
        if job is None:
            raise AttachError(404, "no such job")
        if job["state"] != "done":
            raise AttachError(409, f"job is {job['state']}; attach only to a finished job")
        d = store.dir(bundle_id)
        sm_manifest = d / "run" / "spatial_map" / "manifest.json"
        if not sm_manifest.is_file():
            raise AttachError(409, "the job has no SpatialMap to attach a reconstruction to")
        att = d / "attached"
        n = 1 + max(
            [int(p.name) for p in att.iterdir() if p.name.isdigit()] if att.is_dir() else [],
            default=0,
        )
        work, final = att / f"{n}.tmp", att / str(n)
        try:
            _unpack(zip_path, work)
            root = _reconstruction_root(work)
            final.mkdir(parents=True)
            os.replace(root, final / "reconstruction")
            shutil.rmtree(work, ignore_errors=True)
            rec = final / "reconstruction"
            try:
                man = load_reconstruction(rec, verify=True)
            except Exception as e:  # noqa: BLE001
                raise AttachError(422, f"not a valid reconstruction: {e}") from e
            if man.spatial_map.get("manifest_sha256") != sha256_of(sm_manifest):
                raise AttachError(
                    409,
                    "the reconstruction was not built from this job's SpatialMap (sha256 differs)",
                )
            splat = man.outputs.get("splat")
            ply = next((f for f in (splat.files if splat else []) if f.endswith(".ply")), None)
            if splat is None or splat.status != "ok" or ply is None or not safe_rel(ply):
                why = f"{splat.status}: {splat.reason}" if splat else "missing"
                raise AttachError(422, f"the reconstruction has no trained splat ({why})")
            try:
                rep = runner.qa_report(
                    d / "run" / "spatial_map",
                    final / "job_report.json",
                    rec,
                    d / "logs" / "qa_attach.log",
                )
            except StageFailed as e:
                raise AttachError(500, str(e)) from e
            ply_entry = file_entry(d, bundle_id, f"attached/{n}/reconstruction/{ply}", "splat_ply")
            report_entry = file_entry(d, bundle_id, f"attached/{n}/job_report.json", "job_report")
            metrics = splat.metrics
            has_eval = all(k in metrics for k in ("lpips", "ssim"))

            def f(j: dict) -> None:
                set_stage(
                    j, "splat", "ok", f"attached reconstruction {n} (trained on a GPU worker)"
                )
                if has_eval:
                    set_stage(j, "splat_eval", "ok", metrics_text(metrics))
                else:
                    set_stage(
                        j, "splat_eval", "skipped", "the attached run reported no held-out metrics"
                    )
                set_file(j, ply_entry)
                apply_report(j, rep, report_entry)

            return store.update(bundle_id, f)
        except BaseException:
            shutil.rmtree(work, ignore_errors=True)
            shutil.rmtree(final, ignore_errors=True)
            raise
