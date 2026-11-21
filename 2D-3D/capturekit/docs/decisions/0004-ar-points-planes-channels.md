# 0004: Bundle carries AR feature points and plane anchors
Status: accepted (2026-11-14). GuideMind (Phase 8) uses sparse points and planes, and replay must reproduce it, so the
bundle gets optional channels `/ar/points` and `/ar/planes` beyond the list in Phase 1. They are optional (validator INFO when absent)
and come straight from ARKit rawFeaturePoints / ARPlaneAnchor and ARCore PointCloud / Plane.
