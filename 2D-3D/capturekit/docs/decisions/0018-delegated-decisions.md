# 0018: Open human decisions settled by the planner (user away; revisit)


Status: accepted provisionally (2026-11-16), decided by the planner under delegation; each item is the recommended or most conservative option. Revisit when the human returns.
ADR numbers: 0016 Phase 9 detections contract, 0017 Phase 9 detector model; 0019 no-LLM dialog proxy (voice step 2), 0020 consent/redaction contract 1.2.0 (voice step 3), 0021 redaction detector spike (voice step 10), 0022 overlay v2 yaw_mask + wall id (room-progress step 6), 0023 guidance tuning values (guidance-pipeline C4).

Gate 0 (docs/STATUS.md section 6):
1. Depth: no depth in the v1 bundle. ARCore Depth stays disabled; the optional depth topic stays allowed by the spec but has no producer. No LiDAR.
2. Phones: Android = ARCore-supported phones, minSdk 26 as built (voice commands need API 31+); CPH2381 is the only reference device (one tier). iOS = ARKit iPhones on iOS 17+, LiDAR not required. Support tiers stay "TBD owner".
3. Voice locales: English first (en-IN, en-US fallback), phrase tables as locale data; Hindi/Telugu later, no code now.
4. Consent/retention legal owner: unassigned, "TBD owner". Consent text stays a placeholder marked "pending legal owner". Until an owner signs, uploads only go to the team's own dev server from internal consenting testers; no external participant trials.
5. Mac/iOS: assume no Mac and no green macOS CI job. The iOS track stays blocked; the human checks the Actions page.

Product and scope:
6. Phase 9 detector: COCO furniture/obstacle classes only; doors/windows/mirrors from geometry. If no model card shows Apache-2.0/MIT, ship geometry only and drop phase9 step 10.
7. Gaps steer the planner only behind a default-OFF flag until 3 real rooms are walked.
8. Part 2: assume a 1.0.0 reader may exist. Every minor bump is additive, 1.0.0 bundles must still validate, SPEC.md lists each change; the human tells roomscan-recon.
9. Schema minors fixed: Phase 9 detections (step 4a) = 1.1.0; consent/redaction (voice step 3) = 1.2.0 and lands after 4a; Phase 9 output channels (step 9) = the next free minor (1.3.0 expected). Never reuse a number.
10. Upload: INTERNET only in a `field` product flavour; `standard` stays offline.
11. Redaction: best-effort face blur in memory before the JPEG is written, stated in the manifest and the consent text; field uploads only under item 4.
12. Voice: push-to-talk, English first (item 3).
13. Wall naming: stable "Wall 1, 2, 3" from the core wall id (room-progress step 6), not relative names; map stays north-up (built that way).
14. Completion feedback: haptics only, no sound.
15. Camera image: keyframe CPU image resolution is not lowered until Part 2 states its need.
16. Speed: the stability brief's targets table replaces "10x".
17. Phase 12 targets (registered ratio, reprojection, coverage, crash-free, battery, APK size limit) and the device matrix: "TBD owner"; no invented numbers. The APK size script only reports until a limit is set.
