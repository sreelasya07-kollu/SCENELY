---
description: Load project context and summarise where we are before doing any work
---
Start a work session. Read only these, nothing else up front:

1. `docs/00-PROJECT-CHARTER.md` (or `docs/charter-draft.md` if the charter is not locked yet) plus any files in `docs/amendments/`.
2. `docs/04-TASKS.md`.
3. The "Current phase" line of `docs/03-PHASES.md` and that phase's section only.
4. The newest 2 handoff files: the last 2 of `docs/handoff/2*.md` sorted by name (README and _TEMPLATE don't match).

Then run `bash scripts/verify-charter.sh` and report its result.

Reply with a SHORT summary (8 lines max): the project idea in one line, the current phase, tasks IN PROGRESS with their owners, the next 3 TODO tasks, anything BLOCKED, the charter check result.

Read `01-TECH-STACK.md`, `02-ARCHITECTURE.md`, `05-CONVENTIONS.md`, `PROGRESS.md` or `HANDOFF.md` only when the chosen task needs them. If I already named a task, go ahead with it; otherwise ask which one.
