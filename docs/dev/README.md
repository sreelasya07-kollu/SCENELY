# Development notes: agent-assisted workflow

SCENELY was built with AI coding agents working from written briefs and phase files. The files that drive that
workflow are kept in the repository for transparency. They are developer notes, not product documentation.

| File | Role |
|---|---|
| [`2D-3D/AGENTS.md`](../../2D-3D/AGENTS.md) | Rules, frozen decisions and repo map for Part 1 agent sessions. Stays beside `2D-3D/CLAUDE.md`, which loads it by name |
| [`2D-3D/PROGRESS.md`](../../2D-3D/PROGRESS.md), [`roomscan-recon/PROGRESS.md`](../../roomscan-recon/PROGRESS.md) | Per-part memory between sessions: done, decisions, commands, gotchas, next step |
| [`2D-3D/docs/phases/`](../../2D-3D/docs/phases) | One file per Part 1 phase (0 to 12) |
| [`roomscan-recon/HANDOFF.md`](../../roomscan-recon/HANDOFF.md) | Historical build brief for Part 2; sections 2 and 5 (owner rules, thresholds) are still cited |
| [`NEXT_SESSION.md`](NEXT_SESSION.md) | Historical session start kit (superseded) |
| `.claude/` | Agent configuration and planning briefs; must stay where the tooling looks for it |

Current project state is in [`roomscan-recon/docs/FEATURE_STATUS.md`](../../roomscan-recon/docs/FEATURE_STATUS.md)
and [`2D-3D/docs/STATUS.md`](../../2D-3D/docs/STATUS.md), not in these files.
