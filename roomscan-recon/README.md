# roomscan-recon

**3D Room Reconstruction & Spatial Understanding**: Part 2 of SCENELY, the backend of the program. Part 1 is the phone capture app in [`../2D-3D`](../2D-3D/README.md); the two live in one monorepo.

`roomscan-recon` takes calibrated multi-view camera frames, sensor depth, and priors produced by mobile capture (Part 1 / `2D-3D`) and performs end-to-end spatial understanding, TSDF fusion, plane/room estimation, photogrammetric reconstruction, and 3D Gaussian Splatting (novel view synthesis).

---

## Architecture Overview

```
Input: Scan Bundle / Replica / ETH3D / TUM
   │
   ▼
[Part 2 spatial stage: spatial/]
   ├── Phase 1: Ingest & Keyframe Selection (spatial.io)
   ├── Phase 2: Pose Refinement & Metric Alignment (spatial.sfm)
   ├── Phase 3: Depth Alignment, Filtering & TSDF Fusion (spatial.depth, spatial.fusion)
   ├── Phase 5: Plane Fitting & Room Shell Extraction (spatial.room)
   └── Phase 6: SpatialMap Packaging (spatial.spatial_map)
   │
   ▼
[Part 2 recon stage: recon/]
   ├── Phase 7: Sparse Hand-over to OpenMVS (recon.sparse)
   ├── Phase 8: Dense Point Cloud, Mesh & Texture (recon.dense, recon.openmvs)
   ├── Phase 9: 3D Gaussian Splatting (gsplat) & Novel View Synthesis (recon.splat)
   └── Phase 10: Reconstruction Packaging & Held-out Evaluation (recon.package)
```

---

## Directory Structure

* `spatial/`: Spatial understanding pipeline (ingest, SfM refinement, depth fusion, room geometry).
* `recon/`: 3D reconstruction and radiance field pipeline (OpenMVS and `gsplat` workers).
* `formats/`: Canonical Pydantic schemas and serialization models (`SpatialMap`, `ScanBundle`, `ReconstructionManifest`).
* `eval/`: Synthetic room generation and benchmarking evaluations.
* `docs/`: Technical documentation, architecture specs, decisions, and phase reports (see [docs/README.md](docs/README.md)).
* `tests/`: Automated unit and acceptance test suite.

---

## Quick Start

### 1. Environment & Dependencies

```bash
# Using uv (recommended)
uv sync --extra cpu
```

### 2. Run Spatial Understanding (Part 2 spatial stage)

Fetch a benchmark scene first (datasets are never committed; see [data/DATASETS.md](data/DATASETS.md)):

```bash
bash data/fetch.sh replica        # -> data/replica/room0, data/replica/office0
```

```bash
uv run python -m spatial.cli run \
    --dataset replica \
    --src data/replica/room0 \
    --out runs/sample_run
```

To run on a real Scan Bundle from Part 1, use `--dataset scanbundle --src <bundle dir>` (contract: [docs/SCAN_BUNDLE.md](docs/SCAN_BUNDLE.md)).

### 3. Run 3D Reconstruction & Splatting (Part 2 recon stage)

```bash
uv run python -m recon.cli \
    --spatial-map runs/sample_run/spatial_map \
    --out runs/sample_run/reconstruction \
    --splat auto \
    --heldout-every 8
```

The `run` subcommand is not accepted by `recon.cli` (known issue T-030 in [docs/04-TASKS.md](docs/04-TASKS.md)), so the command above omits it. Splat training needs an NVIDIA GPU; see [docs/heavy-compute/GPU_RUNBOOK.md](docs/heavy-compute/GPU_RUNBOOK.md).

---

## Documentation Links

* [Tech Stack & Dependencies](docs/01-TECH-STACK.md)
* [System Architecture](docs/02-ARCHITECTURE.md)
* [Pipeline Phases](docs/03-PHASES.md)
* [Task Tracker](docs/04-TASKS.md)
* [Data Formats & Interfaces](docs/INTERFACES.md)
