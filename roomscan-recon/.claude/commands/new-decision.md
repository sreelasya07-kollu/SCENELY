---
description: Record a technical decision (ADR) in docs/decisions/
argument-hint: <short title of the decision>
---
Record a decision for: $ARGUMENTS

1. Find the highest number in `docs/decisions/` and copy `000-template.md` to `NNN-<kebab-title>.md` with the next number.
2. Fill in context, options considered, decision and consequences from what we discussed. Ask me only for facts you cannot find in the repo; do not invent them.
3. Status = Proposed until I say Accepted. Never rewrite an older decision; supersede it with a new one and mark the old one "Superseded by NNN".
4. When accepted, update the tool's block in `docs/01-TECH-STACK.md` (what / why / how) and link the record there.
5. Never touch `docs/00-PROJECT-CHARTER.md` or `docs/amendments/`.
