# Brief: Repo polish for hackathon judging (docs, hygiene, CI)   slug: repo-polish-hackathon   base commit: 47a594e6fc4ac1478aa2ac821ee7356be3951aba
Domain: docs | infra
Contract: none (reads 2D-3D/capturekit/** and roomscan-recon/** read-only; no source edits)

## Goal
Make the monorepo `Hackathon/` (GitHub sreelasya07-kollu/SCENELY) read as one professional project to a judge or AI reviewer: a root entry point, accurate cross-links, working CI, clean ignores, no stale or contradictory status docs. Every number written must be reproducible from a command or file in the repo.

## Settled (do not re-research)
- Repo root is `Hackathon/`; GitHub runs workflows only from root `.github/workflows/`, so `2D-3D/.github/workflows/ci.yml` and `roomscan-recon/.github/workflows/charter-check.yml` never run (0 runs on SCENELY). | docs.github.com workflow-syntax (read 2026-11-22); `gh run list` empty
- Action tags in ci.yml exist: checkout v7.0.1, setup-uv v10.4.0, setup-java v6.3.0, gradle/actions v6.4.1. | GitHub releases API 2026-11-22
- No LICENSE anywhere (repo is public; GitHub license = null). Submodules eigen/mcap/nanobind/sophus carry their own.
- Android build outputs (.gradle, build, .cxx, local.properties) are already ignored by `2D-3D/capturekit/.gitignore`; only root `.idea/` is untracked; `.vscode/settings.json` is tracked with an absolute user path.
- Stale/contradictory: `2D-3D/README.md`, `capturekit/README.md`, `AGENTS.md`, `PROGRESS.md`, `docs/program-spec/README.md`, `part2-reconstruction.md`, `NEXT_SESSION.md`, `STATUS.md` call roomscan-recon a "separate repo" (RealKarthiksai/...); roomscan-recon README says "Parts 3 & 4" vs 2D-3D "Part 2"; `roomscan-recon/HANDOFF.md` (2026-11-12) describes a `reconstruction/` folder and skeleton capturekit; `NEXT_SESSION.md` cites `b3d39f0`, 184 tests, next ADR 0025; ADR index stops at 0037 (0038 untracked, 0027 absent); roomscan quickstart uses `data/sample_room` which is gitignored.
- `roomscan-recon/docs/FEATURE_STATUS.md` (2026-11-22) is the newest whole-program feature table: link to it, do not duplicate.

## Non-goals
App source (Kotlin/Swift/C++/Python logic), iOS phase work, rewriting ADRs, adding demo media, git history rewrite, push.

## Steps
1. [x] Root `README.md`: one-paragraph pitch, mermaid architecture (phone capture -> Scan Bundle MCAP+JPEG -> tus upload -> roomscan-recon spatial/recon -> outputs), repo map, per-platform quickstart copied from existing READMEs/PROGRESS Commands, "Status at a glance" linking FEATURE_STATUS.md and 2D-3D/docs/STATUS.md, Demo section with an explicit placeholder only (no invented content). | README.md | done when: every relative link resolves (check with Glob) and every command appears verbatim in an existing repo doc
2. [x] LICENSE at root (type per Question 1). | LICENSE | done when: file exists, README names it
3. [x] Move CI to root: `.github/workflows/capturekit-ci.yml` (working-directory prefixed `2D-3D/`, `paths:` filters) and `roomscan-ci.yml` (charter check + `uv run pytest`/ruff from roomscan-recon, only if commands exist in its pyproject/scripts/check.sh); mark macOS job `continue-on-error: true` (never green). Delete the nested workflow dirs. | .github/workflows/* | done when: `git ls-files .github` lists both and no nested `*/.github/workflows` remain
4. [x] Hygiene: root `.gitignore` add `.idea/`, `*.iml`, `.gradle/`, `local.properties`, `.cxx/`, `.serena/`, `.vscode/`; `git rm --cached .vscode/settings.json`. [parallel with 1] | .gitignore | done when: `git status --porcelain` shows no `.idea/`
5. [x] Unify naming and part numbering: SCENELY = program; CaptureKit = Part 1 phone SDK in 2D-3D; roomscan-recon = backend in same monorepo. Fix "separate repository" lines and RealKarthiksai URLs in the files listed under Settled (wording only, not ADR bodies). | listed files | done when: `git grep -n "separate repo"` returns nothing outside ADRs
6. [x] Stale session docs: move `2D-3D/docs/NEXT_SESSION.md` and `roomscan-recon/HANDOFF.md` to `docs/archive/` with a one-line "historical, superseded by FEATURE_STATUS.md" header; drop stale test counts from them; STATUS/PROGRESS keep numbers only with date + commit attribution. | | done when: no doc presents `184`/`b3d39f0` as current
7. [x] ADR index: add 0038 after the Android coder commits its file; note "0027 not used". | 2D-3D/capturekit/docs/decisions/README.md
8. [x] roomscan quickstart: replace `data/sample_room` with a path or fetch step that exists (`data/fetch.sh`, DATASETS.md). | roomscan-recon/README.md

## Acceptance
- `git grep -nE "separate repo|RealKarthiksai/(2D-3D|roomscan-recon)" -- ":!2D-3D/capturekit/docs/decisions"` -> no output
- `git ls-files | grep -E "/\.github/workflows/"` -> only `.github/workflows/...` at root
- `bash roomscan-recon/scripts/verify-charter.sh` -> exit 0
- No test-command exists for docs: links checked manually per Step 1; CI proof = first green run after the human pushes.

## Review focus
- Any number or claim in new docs without a source file/command.
- CI working-directory and `paths:` correctness after the move.
- Links from root README into 2D-3D and roomscan-recon.

## Risks and stop-and-report triggers
- Android coder is editing `2D-3D/capturekit/android/**` now: do not touch it; wait for ADR 0038 commit.
- iOS CI job never compiled: if it would block merges, keep it non-blocking and report.
- Agent-facing files (AGENTS.md, CLAUDE.md, .claude/) may look unprofessional to judges; do not delete without Question 3 answer.

## Questions for the human
1. Which license (MIT or Apache-2.0), and who is the copyright holder?
2. Is "SCENELY" the official project name, and should Part numbering be "Part 1 capture / Part 2 reconstruction" everywhere (roomscan-recon currently says Parts 3 & 4)?
3. Keep agent-workflow files (AGENTS.md, CLAUDE.md, .claude/, NEXT_SESSION.md, HANDOFF.md) visible, archive them under docs/archive, or remove them from the public repo? And can you supply a demo video/screenshots for the Demo section?
