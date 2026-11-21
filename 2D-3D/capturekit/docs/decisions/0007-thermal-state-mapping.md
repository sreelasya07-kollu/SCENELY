# 0007: Mapping OS thermal signals onto governor levels 0–3
Status: accepted (2026-11-14). iOS ProcessInfo.ThermalState nominal/fair/serious/critical → 0/1/2/3.
Android PowerManager status NONE→0, LIGHT/MODERATE→1, SEVERE→2, CRITICAL/EMERGENCY/SHUTDOWN→3, and the
API 30+ 10 s thermal headroom forecast raises it early (≥0.85 → at least 1, ≥1.0 → at least 2), because
OEM status reporting is coarse and late. Governor ladder: 1→REDUCE_KEYFRAMES, 2→LOWER_RESOLUTION, 3→SAFE_PAUSE.
Tune with the Phase 5 soak test.
