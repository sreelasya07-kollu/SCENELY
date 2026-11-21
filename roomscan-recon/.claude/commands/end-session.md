---
description: Close the session: update the task board and docs, write a handoff file, verify the charter
---
Wrap up this session. This is the one place where docs get updated:

1. `docs/04-TASKS.md`: move finished tasks to DONE (date + commit hash, or "uncommitted"); leave unfinished ones IN PROGRESS with a one-line note; add newly found work as TODO with a Phase. Never edit rows owned by someone else.
2. Update `docs/01-TECH-STACK.md` or `docs/02-ARCHITECTURE.md` only if this session changed a tool, a version policy or a module boundary. Link versions to `pyproject.toml`; never copy them.
3. Create a NEW file `docs/handoff/YYYY-MM-DD-HHMM-<name>.md` from `docs/handoff/_TEMPLATE.md`: worked on, done, left over, decisions (links), gotchas, suggested next task. Never edit an older handoff file.
4. Run `bash scripts/verify-charter.sh`; it must pass.
5. Show a short list of the doc files you changed. Do not commit unless I ask.
