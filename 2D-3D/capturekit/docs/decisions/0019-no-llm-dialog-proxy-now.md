# 0019 State questions: fixed templates over a snapshot, no LLM client now
Date 2026-11-17. Status: accepted under ADR 0018 items 3, 13 and the human decision of 2026-11-15 (build nothing networked).
- "What is missing" and "how much is left" are answered by `StateAnswers` (Kotlin, JVM-tested) from `ScanStateSnapshot`, built from the last `overlay` event: completeness, tracking, wall/floor/ceiling flags, per-wall % seen, heading sectors, optional labels and gaps. No image, path, position or timestamp is in the snapshot.
- Unknown snapshot, no scan data yet, tracking not available or an unknown question gives one fixed abstain sentence; answers name only regions present in the snapshot; walls are "Wall N" (overlay wall id, ADR 0022).
- A dialog proxy (LLM Q&A) is NOT built: no client, no INTERNET use, no key. The contract for adding one later is capturekit/docs/dialog-proxy.md; `ScanStateSnapshot.toJson()` is the only payload it may send, behind its own consent line and ADR.
- Wall percent threshold 80 and finish completeness 0.9 are guesses until Gate 0 data.
