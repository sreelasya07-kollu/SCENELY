---
description: Propose a change to the project scope without touching the locked charter
argument-hint: <what you want to change>
---
Draft a change request for: $ARGUMENTS

1. Read `docs/00-PROJECT-CHARTER.md` (or `docs/charter-draft.md`) and `docs/amendments/`; say which section this change conflicts with or extends.
2. Copy the template in `docs/change-requests/` to the next `CR-NNN-<kebab-title>.md` and fill it in: the change, the charter section it touches, why, and its impact on phases, tasks and the tech stack.
3. Status = Proposed. Do not edit the charter, amendments, phases or tasks.
4. If the owner approves, the owner (not Claude) adds `docs/amendments/NNN-<title>.md` linking the CR. The charter itself is never edited or re-locked.
5. End with: "Until this is approved, do not implement it."
