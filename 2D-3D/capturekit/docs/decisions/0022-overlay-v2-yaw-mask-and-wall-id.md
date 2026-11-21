# 0022 — Overlay v2: yaw_mask and stable wall id

Room progress stayed at 0 in plain rooms (no plane coverage) and wall numbers followed list order, which changes
as planes merge. The `overlay` event (ADR 0013) gains two additive fields: `yaw_mask` (12 x 30 degree heading
sectors, bit i = a keyframe looked along [30i, 30i+30) deg, from the keyframe pose yaw; views within 20 degrees of
vertical are ignored) and a 6th `surfaces` field, the wall id (1-based, assigned in first-seen order in
`GuideEngine::on_plane`, never reused). Parsers accept 5 or 6 fields and a missing `yaw_mask` (= 0). Sector size
and the 70 degree pitch gate are guesses until Gate 0 data. No bundle or C API change; golden regenerated.
