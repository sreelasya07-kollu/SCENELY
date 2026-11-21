# Upload test protocol (Phase 7, device work)

The server-side and client-protocol failure matrix runs automatically against the docker stack
(`dev-server/failure_test.sh`, 8 cases). These cases need real phones and cannot be automated here.
Use a finished bundle (>= 1 MB), the sample app's upload button, `dev-server` reachable on the LAN.
Check the result with `curl http://<host>:8081/bundles/<bundle_id>` (COMPLETE / INCOMPLETE / CORRUPT / PENDING).

| # | Case | Steps | Pass |
|---|---|---|---|
| 1 | Airplane mode | Start upload, toggle airplane mode on mid-file, wait 30 s, off | Resumes by itself; COMPLETE; no restart from 0 |
| 2 | App kill | Start upload, force-quit the app mid-file, relaunch | Resumes from the server offset; COMPLETE |
| 3 | Reboot | Start upload, reboot the phone | Android: WorkManager resumes by itself. iOS: resumes on next launch (TUSClient.start()). COMPLETE |
| 4 | Network switch | Wi-Fi -> cellular mid-upload (and back) | Resumes; COMPLETE; respects "Wi-Fi only" setting |
| 5 | Server restart | `docker compose restart tusd verifier` mid-upload | Client retries with backoff; COMPLETE |
| 6 | Disk full (device) | Fill storage, then upload a finished bundle | Upload works from the existing files; no new local writes fail |
| 7 | Disk full (server) | Fill the MinIO volume | Upload fails with a clear error; bundle shows INCOMPLETE; resumes after space is freed |
| 8 | Background | Start upload, lock screen / home for 5 min | iOS background URLSession and Android WorkManager continue; COMPLETE |
| 9 | No consent | Upload with consent off | Refused locally; nothing sent |
| 10 | Local retention | Upload with "delete after upload" on | Local files deleted only after COMPLETE |

Record results in `docs/reports/upload-results.md` (device, OS, network, pass/fail, notes).
