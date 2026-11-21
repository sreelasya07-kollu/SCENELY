# roomscan-recon

**3D Room Reconstruction & Spatial Understanding** (Part 3 & Part 4 of the 2D-3D Room Scanner Program).

`roomscan-recon` takes calibrated multi-view camera frames, sensor depth, and priors produced by mobile capture (Part 1 / `2D-3D`) and performs end-to-end spatial understanding, TSDF fusion, plane/room estimation, photogrammetric reconstruction, and 3D Gaussian Splatting (novel view synthesis).

---

## Architecture Overview

```
Input: Scan Bundle / Replica / ETH3D / TUM
   │
   ▼
[Part 3: spatial/]
   ├── Phase 1: Ingest & Keyframe Selection (spatial.io)
   ├── Phase 2: Pose Refinement & Metric Alignment (spatial.sfm)
   ├── Phase 3: Depth Alignment, Filtering & TSDF Fusion (spatial.depth, spatial.fusion)
   ├── Phase 5: Plane Fitting & Room Shell Extraction (spatial.room)
   └── Phase 6: SpatialMap Packaging (spatial.spatial_map)
   │
   ▼
[Part 4: recon/]
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
uv sync
```

### 2. Run Spatial Understanding (Part 3)

```bash
python -m spatial.cli run \
    --dataset scanbundle \
    --src data/sample_room \
    --out runs/sample_run \
    --keyframes
```

### 3. Run 3D Reconstruction & Splatting (Part 4)

```bash
python -m recon.cli run \
    --spatial-map runs/sample_run/spatial_map \
    --out runs/sample_run/reconstruction \
    --splat auto \
    --heldout-every 8
```

---

## Documentation Links

* [Tech Stack & Dependencies](docs/01-TECH-STACK.md)
* [System Architecture](docs/02-ARCHITECTURE.md)
* [Pipeline Phases](docs/03-PHASES.md)
* [Task Tracker](docs/04-TASKS.md)
* [Data Formats & Interfaces](docs/INTERFACES.md)
