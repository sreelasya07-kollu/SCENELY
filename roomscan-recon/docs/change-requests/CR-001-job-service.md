# CR-001: Minimal single-worker job service

- **Date:** 2026-11-22
- **Requested by:** owner (answer 1 in brief `backend-app-connection`)
- **Status:** Proposed
- **Approved by (owner):** pending: the owner stated the intent on 2026-11-22; an amendment is still to be written
- **Amendment (if approved):** AMD-NNN

## What is the change?
Add `roomscan-recon/jobs/`: a stdlib HTTP service with one worker thread. It takes a verified
bundle id from the CaptureKit dev-server verifier, runs the existing CLIs (spatial, recon, export,
qa) as subprocesses, keeps the state per job on disk, serves the results to the Android app, and
accepts a GPU-laptop reconstruction as a zip (`python -m jobs.cli attach`). Single worker, no
accounts, no auth, no multi-tenant queue, runs on the owner's machine (WSL).

## Which charter section does it touch?
§7 Non-goals: "Backend platform: accounts and queues (Project G)". The CR lifts only the queue
part, for this minimal service. Accounts, auth and multi-tenancy stay non-goals.

## Why is it needed?
Phone scans must reach the pipeline and show results in the app (verdict, rescan prompts,
measurements, floor plan, exports). Without a service, results can only be produced by hand.

## Impact
- Phases affected: P11
- Tasks to add or remove: T-032
- Tech stack impact (ADR needed?): none beyond ADR 003; stdlib `http.server`, no web framework
- Time / compute impact: one job at a time; GPU stages stay pending until a GPU run is attached

## If approved
The owner writes `docs/amendments/AMD-NNN-job-service.md` and links this CR. The charter is not
edited or relocked.
