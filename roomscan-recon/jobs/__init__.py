"""Minimal single-worker job service (CR-001): bundle id -> checks -> pipeline -> result contract.

Imports only the standard library and `formats`; the pipeline stages run as subprocesses of the
existing CLIs. The result contract is `spec/jobs/job_status.schema.json` (roomscan.job/1).
"""
