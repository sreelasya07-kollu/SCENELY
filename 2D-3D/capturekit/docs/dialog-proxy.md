# Dialog proxy (design only, nothing networked is built; ADR 0019)

Today: spoken or typed state questions are answered on device by `StateAnswers` (`guidance/StateAnswers.kt`) from a
`ScanStateSnapshot` (`guidance/ScanStateSnapshot.kt`). Fixed templates, English, no model, no network.

## Snapshot (the only data a proxy may see)
`ScanStateSnapshot.toJson()`, flat, sorted keys, built from the latest `overlay` event (docs/guide.md):
`completeness` 0..1, `tracking` 1/2/3, `wall_found`, `floor_found`, `ceiling_found`, `walls` [{`id`,`pct`}],
`heading_sectors` 0..12, `labels` [], `gaps` []. Never: keyframes, pixels, file names, bundle ids, world
coordinates, timestamps, device ids, consent text.

## Request / response (if a proxy is ever added)
- Request: `{"v":1,"question":"<recogniser text, max 200 chars>","state":<snapshot>}`.
- Response: `{"v":1,"answer":"<=25 words","cites":["Wall 2","Floor"],"abstain":false}`.
- Client validation before speaking: every `cites` entry must be in `ScanStateSnapshot.regions`; every "Wall N" in
  `answer` must match a wall id in the snapshot; otherwise discard and use `StateAnswers`. Abstain or invalid = say
  the fixed abstain sentence ("I am not sure yet. Keep scanning.").
- Timeout 2 s, no retry, no queue; the template answer is the fallback and is spoken at once when offline. Never on
  the AR thread or the main thread. Never in the capture loop: guidance prompts stay templated (AGENTS.md C).
- Abstain rules apply on the client regardless of the server: no snapshot data yet, tracking = 3, unknown question.

## Gates before building it
Own ADR; consent line naming the endpoint and the snapshot fields; field flavour only (INTERNET); endpoint and key
via gradle properties, never committed; privacy review of the snapshot fields; latency measured on device.
