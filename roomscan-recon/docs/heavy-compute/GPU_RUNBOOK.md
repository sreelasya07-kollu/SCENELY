# GPU runbook: run the GPU / heavy items on an NVIDIA laptop and send the results back

For a helper who has an NVIDIA machine and a terminal, and no project background. Work through the
sections in order. Nothing here was run on a GPU yet; every step that is still a guess is marked
**UNVERIFIED** and collected in "Verify first".

What each item is, its estimate and its pass criterion: [INVENTORY.md](INVENTORY.md) (generated from
[inventory.yaml](inventory.yaml); never edit the .md). Resource tiers: [MACHINE_SPEC.md](MACHINE_SPEC.md).
Thresholds: `HANDOFF.md` §5. Task: `docs/04-TASKS.md` T-024.

## 0. Fill in first

| Field | Value |
|---|---|
| Your name / date | |
| OS (Linux native, WSL2 Ubuntu, Windows native) | |
| GPU model | |
| VRAM (GB) | |
| `nvidia-smi` driver version / "CUDA Version" | |
| System RAM (GB) / free disk (GB) | |

What fits (the tests skip themselves and print the missing requirement, so a smaller GPU is not
harmful, it just skips more):

| Goal | Needs |
|---|---|
| Splat items only (E4/E5, `test_splat_training_eth3d_half_res`) | NVIDIA GPU with >= 4 GB VRAM, any OS in section 2 |
| Every implemented P0/P1 item | tier T1 in MACHINE_SPEC.md: 24 GB VRAM, 64 GB RAM, 16 cores, 500 GB free disk, Linux or WSL2 |
| 30k-step splat training (P8-01 estimate) | 16 GB VRAM, 32 GB RAM |
| OpenMVS full resolution (P7-02/P7-03) | 64 GB RAM (the same run was killed twice on a 15 GB machine) |

## 1. Prerequisites

1. **Driver.** `nvidia-smi` must work. The "CUDA Version" it prints must be >= the wheel you pick
   (12.6 for `cu126`, 13.0 for `cu130`). Minimum driver numbers per wheel: **UNVERIFIED**, see Verify first.
   On WSL2 install the NVIDIA driver on Windows only and do not install a Linux driver inside WSL.
2. **CUDA toolkit (`nvcc`).** gsplat 1.5.3 has no prebuilt wheel for torch 2.14 (**UNVERIFIED**), so it compiles its CUDA
   kernels on first use (JIT). `nvcc --version` must work and match the torch wheel's CUDA major
   version (12.x for `cu126`, 13.x for `cu130`).
3. **Python 3.11 or 3.12** (pinned by `pyproject.toml`: `requires-python >=3.11,<3.13`), and **uv**
   ([install](https://docs.astral.sh/uv/getting-started/installation/)).
4. **git, curl, unzip, 7z (p7zip)** for the dataset scripts (`data/fetch.sh` uses all four).
5. **Docker** with the Linux engine, for OpenMVS (P7-02/P7-03, and `recon.cli` meshing). The CUDA image
   (P0-01) additionally needs the NVIDIA Container Toolkit (`docker run --gpus all`).
6. **Disk and RAM:** see section 0. A full download of every dataset is about 57 GB
   (MACHINE_SPEC.md); the cheap path in section 3 needs about 2 GB.
7. **Native Windows only:** Visual Studio Build Tools with the MSVC v143 toolset (v142 if 143 fails),
   and `cl.exe` on PATH (run `vcvars64.bat` first; the example is `run_gpu.bat`, whose `F:\3d` paths
   are hard-coded to one machine, copy the pattern and fix the paths).

Build the OpenMVS image once (CPU, about 0.6 GB; needs network for Ubuntu 26.04 packages):

```bash
docker build -t room-openmvs:2.4.0 docker/openmvs
```

## 2. Setup per OS

Recommended: **Linux** (native Ubuntu, or WSL2 Ubuntu with the Windows NVIDIA driver). Reason:
`pycolmap-cuda12` 4.2.1 ships Linux wheels only, `run_heavy.py` runs every inventory
command through `bash -lc`, and the 448 MB Linux Open3D 0.19.0 wheel is CUDA-built.
**Native Windows is a fallback for the splat items only** (section 4 steps 1 to 4 and 8).

Linux / WSL2:

```bash
git clone <repo> && cd <repo>/roomscan-recon
uv sync --extra cu126        # or: uv sync --extra cu130 (pick the one your driver supports)
PY=.venv/bin/python
```

Native Windows (PowerShell, from a "x64 Native Tools Command Prompt" or after `vcvars64.bat`):

```powershell
uv sync --extra cu126
$PY = ".venv\Scripts\python.exe"
$env:PYTHONUTF8 = "1"        # the repo scripts read and write UTF-8; the Windows default (cp1252) breaks them
```

Rules that avoid breaking the environment:

- Always pass exactly one extra (`cpu`, `cu126` or `cu130`) to `uv sync`.
- After the sync, run things with `$PY ...` (or `uv run --no-sync ...`). A plain `uv run` resolves
  without an extra and can swap the CUDA torch for another build.
- `pip install pycolmap-cuda12==4.2.1` (P2-01) replaces `pycolmap`; the next `uv sync` undoes it. Do
  that item last, and only on Linux.

Sanity check (prints versions and whether CUDA is visible):

```bash
$PY -c "import torch, gsplat, open3d as o3d; print(torch.__version__, torch.version.cuda, torch.cuda.is_available(), gsplat.__version__, o3d._build_config['BUILD_CUDA_MODULE'])"
```

## 3. Data

`runs/` and `data/` are gitignored. Pick one option.

**Option A: the owner hands you a zipped `runs/`** (recommended; contains the SpatialMaps). Unzip it
into the repo root so `runs/dev_p10_eth3d/spatial_map/manifest.json` exists. Then you only need
datasets for the items that read `data/` (E6, P1-02, P3-xx).

**Option B: regenerate from downloads.**

```bash
data/fetch.sh eth3d                     # ETH3D office, about 0.44 GB, needs 7z; used by E6 and the SpatialMap below
data/fetch.sh replica tum nyu           # default set; REPLICA_STRIDE=5 by default; NYU download is 2.97 GB then deleted
scripts/heavy/fetch_datasets.sh -y replica_full eth3d_office   # full-size subsets with sizes, resumable, sha256 recorded
```

Download sizes (inventory.yaml `datasets`, HTTP HEAD 2026-11-13): ETH3D office 0.44 GB, TUM fr1 0.79 GB,
NYU test 2.97 GB, ETH3D all scenes 5.89 GB, Replica 8 scenes 12.44 GB, Mip-NeRF 360 12.54 GB,
ARKitScenes (2 scans) 23.64 GB. `scripts/heavy/fetch_datasets.sh` prints sizes and asks before
downloading (`-y` skips the question).

Regenerate the SpatialMap the splat test needs, if you did not get one (CPU; **UNVERIFIED**: the
original invocation was not recorded, this reuses the ingest arguments of
`tests/test_phase2.py::test_eth3d_sfm_only`):

```bash
$PY -m spatial.cli run --dataset eth3d --src data/eth3d/office --out runs/dev_p10_eth3d --downscale 4 --prior none
ls runs/dev_p10_eth3d/spatial_map/manifest.json     # must exist, else the splat test skips
```

## 4. Commands, in order

Create the results folder first (`test_splat_training_eth3d_half_res` writes into it without creating it):

```bash
mkdir -p runs/test_results
```

1. **Machine report.** Save it, it goes back with the results.

   ```bash
   $PY scripts/heavy/check_machine.py --json > machine.json
   $PY scripts/heavy/check_machine.py            # human table: RUNNABLE / BLOCKED per item
   ```

2. **Dry run of the plan** (shows which items would run; nothing is executed):

   ```bash
   $PY scripts/heavy/run_heavy.py --priority P0 P1 --dry-run
   ```

3. **P0-02: gsplat E4 + E5** (first run compiles the CUDA kernels; note how long it takes):

   ```bash
   $PY -m pytest -m gpu tests/test_env.py -k "e4 or e5" -rs --junitxml=runs/test_results/p0_02.xml
   ```

   Pass: E4 within 1 px of the analytic projection, E5 final PSNR > 25 dB (HANDOFF.md §3). Do this step
   by hand, not through `run_heavy.py`: the inventory command for P0-02 re-syncs to `cu126`.

4. **P8-01 (partial): splat training test** on the ETH3D SpatialMap (7000 steps, half resolution):

   ```bash
   $PY -m pytest -m gpu tests/test_phase9_splat.py -rs --junitxml=runs/test_results/p8_01.xml
   ```

   Pass: held-out PSNR >= 24 dB, SSIM >= 0.80, LPIPS <= 0.30. Writes `runs/test_results/phase9_splat_eth3d.json`.
   The 30k-step runs on the other scenes are not scripted yet (INVENTORY.md P8-01).

   Native Windows: do steps 1 to 4 and 8, then section 5; skip 5 to 7.

5. **All GPU-marked tests** (Linux/WSL2; includes the P3-12 CUDA fusion and inference parity test, which
   needs a CUDA-built Open3D):

   ```bash
   $PY -m pytest -m gpu -rs --junitxml=runs/test_results/gpu_all.xml
   ```

6. **End to end with the splat** (Linux/WSL2 with Docker and `room-openmvs:2.4.0`; OpenMVS runs first,
   then the splat; `--out` must not exist). Use `--resolution-level 0` and a higher `--memory-gb` only
   with 64 GB RAM:

   ```bash
   $PY -m recon.cli --spatial-map runs/dev_p10_eth3d/spatial_map --out runs/heavy/e2e_eth3d \
       --resolution-level 1 --splat yes --splat-steps 7000 --max-threads 4 --memory-gb 24
   ```

   Note: the command is `python -m recon.cli ...` **without** the word `run`; the `run` form that
   docs/INTERFACES.md §7 and the router recipes use is rejected today (T-030). Result:
   `runs/heavy/e2e_eth3d/` with `manifest.json`; the splat is `splat/point_cloud.ply`. If the splat
   fails the manifest says why.

7. **The inventory sweep** (Linux/WSL2). This runs every P0 and P1 item whose command is not `TODO`,
   in inventory order, and records wall time, peak VRAM / RAM and disk per item under
   `runs/heavy/<date>/<id>/`:

   ```bash
   $PY scripts/heavy/run_heavy.py --priority P0 P1 --no-deps
   ```

   Read before starting: it includes hours-long items (P2-05 is 4 to 10 h on CPU, P7-02/P7-03 need 64 GB
   RAM); `--no-deps` stops it from building the 40 GB CUDA image (P0-01) as a side effect, but P0-01 is
   itself a P0 item, so it still runs unless you use `--ids` instead of `--priority`; commands that
   contain `<placeholder>` (P1-01, P3-05, P7-02, P7-03) are not runnable as written, so they fail or
   need to be done by hand; P2-01 swaps in `pycolmap-cuda12`. To run a subset instead:
   `$PY scripts/heavy/run_heavy.py --ids P3-04 P3-12 --no-deps`. P0-01 on its own, if you want the CUDA
   image and have the disk: `docker build -f docker/cuda.Dockerfile -t roomscan-cuda:dev .`

8. **Fill the results table.** Copy [RESULTS_TEMPLATE.md](RESULTS_TEMPLATE.md) to `RESULTS_<yourname>.md`
   and fill only measured numbers; leave a cell empty if the item did not run. The numbers come from
   `runs/heavy/<date>/summary.md` and `runs/test_results/*.json`. Also fill in section 0 of this file.

## 5. Send the results back

Put these in one archive (everything is small except possibly splat checkpoints; delete `ckpt_last.pt`
files if the archive is over a few hundred MB):

- `runs/test_results/` (JSON numbers and the `--junitxml` files)
- `runs/heavy/<date>/` (every item's `cmd.txt`, `stdout.log`, `meta.json`, and `summary.md`)
- `runs/heavy/e2e_eth3d/manifest.json` and `runs/heavy/e2e_eth3d/splat/` if step 6 ran
- `machine.json` and the filled `RESULTS_<yourname>.md`

```bash
zip -r gpu_results_<yourname>_<date>.zip runs/test_results runs/heavy machine.json RESULTS_<yourname>.md
```

PowerShell: `Compress-Archive -Path runs\test_results, runs\heavy, machine.json, RESULTS_<yourname>.md -DestinationPath gpu_results_<yourname>_<date>.zip`

Send the zip to the owner by any file-sharing method you agree on. A job-API upload is planned:

<!-- TODO(backend-app-connection): result-attach endpoint -->

The upload contract will live in `roomscan-recon/spec/jobs/` (planned by the brief
`backend-app-connection`, not approved yet). Until it exists, send the zip by hand.

## Verify first

Each item below is a guess. Check it, write the answer in the results file, and tell the owner if it is
wrong:

1. **gsplat JIT.** **UNVERIFIED:** no prebuilt gsplat wheel is believed to exist for torch 2.14, so the first run compiles. Time the
   first run of step 3. If compiling fails, record the error text and `nvcc --version`.
2. **Open3D CUDA.** Run `$PY -c "import open3d as o3d;print(o3d._build_config['BUILD_CUDA_MODULE'])"`.
   Expected `True` on Linux. Checked on 2026-11-22 on a Windows x64 machine with the 0.19.0 wheel:
   `False`, so P3-08 / P3-12 cannot use the GPU path on native Windows.
3. **Driver minimums.** The minimum NVIDIA driver version for the `cu126` and `cu130` torch wheels is
   not recorded here. Rule used: the "CUDA Version" in `nvidia-smi` must be >= the wheel. Write down
   what worked.
4. **WSL2.** CUDA through WSL2 has not been tried on this project. If `torch.cuda.is_available()` is
   `False` inside WSL2, stop and report the `nvidia-smi` output.
5. **ETH3D SpatialMap recipe** (section 3): the command is a reconstruction of how `runs/dev_p10_eth3d`
   was likely made. If the splat test skips or fails on it, report the output.
6. **Item commands with a hard-coded extra.** The inventory command for P0-02 runs `uv sync --extra cu126`;
   on a `cu130` machine do step 3 by hand as written above.

## Known gaps in what you are running

- The splat trainer (`recon/splat/train.py`) has never run on a GPU; a failure is a result, report it
  with the log.
- `python -m recon.cli run` is rejected (T-030); use the form without `run`.
- The sweep (`run_heavy.py`) is Linux/WSL2 only because it runs every inventory command through
  `bash -lc` and because `pycolmap-cuda12` 4.2.1 has Linux wheels only. What is left of T-028:
  `run_heavy.sh` still calls `.venv/bin/python`, and `bash -lc` on native Windows.
- Maintainers regenerating INVENTORY.md / MACHINE_SPEC.md on Windows need `PYTHONUTF8=1`
  (`python scripts/heavy/render_docs.py` otherwise fails on a non-cp1252 character and leaves
  INVENTORY.md empty).
