# Orientation (monorepo root = Hackathon/, remote sreelasya07-kollu/SCENELY)

Purpose: SCENELY room scanner. Part 1 phone capture (2D-3D/capturekit) produces a Scan Bundle; roomscan-recon reconstructs it (spatial understanding, OpenMVS, Gaussian splatting).

Stack: C++20 core (Eigen, Sophus, MCAP, nanobind submodules) · Android Kotlin/ARCore (2D-3D/capturekit/android, the only Android project) · iOS Swift pkg (never compiled) · Python ckit tools (uv) · roomscan-recon Python (uv, pyproject.toml).

Modules: 2D-3D/capturekit/{core,android,ios,tools,spec/scanbundle,dev-server,docs/decisions(ADRs)} · 2D-3D/docs/{STATUS,PROGRESS,phases,program-spec} · roomscan-recon/{spatial,recon,formats,eval,qa,jobs,export,router,benchmarks,tests,docs}.

Shared contract: Scan Bundle spec 2D-3D/capturekit/spec/scanbundle/SPEC.md; read by roomscan-recon/formats/scanbundle.py.

Build/test commands: 2D-3D/PROGRESS.md "Commands"; 2D-3D/.github/workflows/ci.yml jobs; roomscan-recon/scripts/check.sh.

Danger zones: CI workflows live in subfolder .github dirs and never run (0 runs). No LICENSE. Docs still call roomscan-recon a separate repo. AGENTS.md says Part 2 never in this repo (pre-monorepo rule).

Conventions: ADRs NNNN-title.md; PROGRESS.md <=40 lines; feature flags off unless device-verified (ADR 0032).

This PC (2026-11-22): WSL Ubuntu user karthik (cmake 3.31.6 in ~/tools, uv in ~/.local/bin, ck-venv); JDK 21 only (gradle auto-provisions 25 via gradle-daemon-jvm.properties); SDK build-tools 36.0.0 only; adb not on PATH; no Docker; no Mac. Top-level Hackathon/android/ was an old duplicate of 2D-3D/capturekit/android (deleted in working tree).

indexed_at: 47a594e6fc4ac1478aa2ac821ee7356be3951aba
