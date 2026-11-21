# CLAUDE.md: roomscan-recon (Room Scanner Part 3 `spatial/` + Part 4 `recon/`)
Files in `docs/` are the source of truth; each fact has one owner (`docs/README.md`). Link, never copy.

## Rules
1. Never edit `docs/00-PROJECT-CHARTER.md` or `docs/.charter.sha256`. Scope conflict: stop, tell the owner, suggest `/change-request`.
2. Build only what the charter (draft: `docs/charter-draft.md`) + `docs/amendments/` and the current phase in `docs/03-PHASES.md` cover.
3. Work only on a task in `docs/04-TASKS.md`; each brief names its T-ID. New work = new TODO row.
4. New, removed or re-pinned dependency: ADR in `docs/decisions/` first (`/new-decision`).
5. Owner rules in HANDOFF.md §2: no fake algorithms or fabricated metrics; measured tests only; `spatial/` and `recon/` never import each other.
6. Commit only when the owner asks; conventional messages (`feat(scope): ...`). Never push.

## Commands
- Env: `uv sync --extra cpu` (or `cu126` / `cu130`; always pass one)
- Fast gate: `uv run pytest -m light` and `uv run ruff check`
- Charter: `bash scripts/verify-charter.sh` must exit 0 before finishing

## Workflow
`/start-session` first, `/end-session` last (updates docs, writes `docs/handoff/` file).

## Read on demand (do NOT preload)
| When you need... | Read |
|---|---|
| Phase status, evidence, past decisions | `PROGRESS.md` |
| Acceptance thresholds, owner rules | `HANDOFF.md` §5, §2 |
| On-disk formats, CLI flags, conventions | `docs/INTERFACES.md`, `docs/SCAN_BUNDLE.md` |
| Why a tool is used / versions | `docs/01-TECH-STACK.md`, `pyproject.toml` |
| How modules fit together, boundaries | `docs/02-ARCHITECTURE.md` |
| Git, code style, definition of done | `docs/05-CONVENTIONS.md` |
| Licences (models, tools, datasets) | `docs/MODELS.md` |
| GPU / heavy work items | `docs/heavy-compute/INVENTORY.md` |
| Why a decision was made | `docs/decisions/` |
| Who owns which fact | `docs/README.md` |
