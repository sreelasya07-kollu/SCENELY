"""`python -m jobs.cli attach <bundle_id> <results.zip>`: attach a GPU-laptop reconstruction.

Default (local mode): works on the job folders directly (`--data`, same value as the server's), ONLY
while the job server is stopped: the server does not see changes made behind its back. With
`--server http://host:8090` the zip is POSTed to a running service instead.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote

from jobs.attach import AttachError, attach
from jobs.runner import Runner
from jobs.store import JobStore, valid_bundle_id


def _summary(job: dict) -> str:
    stages = ", ".join(f"{s['name']}={s['status']}" for s in job["stages"])
    return f"job {job['bundle_id']}: state={job['state']} verdict={job['verdict']}\n  {stages}"


def main(argv: list[str] | None = None, runner: Runner | None = None) -> int:
    ap = argparse.ArgumentParser(prog="jobs.cli")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("attach", help="validate a recon.cli output zip and attach it to a job")
    a.add_argument("bundle_id")
    a.add_argument("zip", type=Path)
    a.add_argument(
        "--data",
        default="runs/jobs",
        help="job folders (local mode: ONLY while the job server is stopped; else use --server)",
    )
    a.add_argument("--server", help="POST to this job service instead of touching the folders")
    args = ap.parse_args(argv)

    if not valid_bundle_id(args.bundle_id):
        print("invalid bundle id", file=sys.stderr)
        return 2
    if not args.zip.is_file():
        print(f"no such file: {args.zip}", file=sys.stderr)
        return 2
    if args.server:
        url = f"{args.server.rstrip('/')}/jobs/{quote(args.bundle_id)}/attach"
        with open(args.zip, "rb") as f:
            req = urllib.request.Request(
                url,
                data=f,
                method="POST",
                headers={
                    "Content-Type": "application/zip",
                    "Content-Length": str(args.zip.stat().st_size),
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:  # noqa: S310
                    job = json.loads(r.read())
            except urllib.error.HTTPError as e:
                print(
                    f"attach refused ({e.code}): {e.read().decode(errors='replace')}",
                    file=sys.stderr,
                )
                return 1
    else:
        store = JobStore(args.data)
        try:
            job = attach(
                store, runner or Runner(store, verifier_url=None), args.bundle_id, args.zip
            )
        except AttachError as e:
            print(f"attach refused ({e.code}): {e.message}", file=sys.stderr)
            return 1
    print(_summary(job))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
