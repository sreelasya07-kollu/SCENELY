# 0024: OpeningDetector v1 parameters (sim-tuned hypotheses)

Status: accepted (2026-11-16, under ADR 0018 delegation; kept rather than reverted because that would need re-tuning). Beyond min_conf 0.5 -> 0.7 (ADR 0015) the detector changed from a component search to: maximal empty rectangles bounded by wall on the sides and top, overlap suppression (most confident wins), a 2-cell ring probe, and conf = 0.5 ring_fill + 0.3 seen_frac + 0.2 clamp(through_points / 3).
Parameters, all sim-tuned HYPOTHESES (not in GuideParams, config hash unchanged): on_plane_tol 0.06 -> 0.04 m, floor_band 0.04 m, despeckle of isolated solid cells, min_seen 0.6, min_ring_known 0.5, min_ring_fill 0.6, min_cell_views 3 (min_rect removed).
Risk: on_plane_tol 0.04 is about 2 sigma of the sim noise at 3.5-5 m (0.01 + 0.005 * (range - 2)) and may be too tight for real ARCore points, which would punch false holes into walls. Revisit with real recordings.
