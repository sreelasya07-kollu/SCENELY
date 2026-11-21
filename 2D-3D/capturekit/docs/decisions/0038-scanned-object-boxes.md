# 0038 Scanned object boxes and the "unavailable" chip
Status: accepted. Extends 0035 (live segmentation and object memory). Display only, nothing is recorded.
- An object is "scanned" when its track has a 3D centre and was seen in at least `LiveObjectTracker.SCANNED_MIN_SIGHTINGS` (3) segmentation results. It is a derived property of the immutable `LiveObject`, copied into `DrawBox.scanned`.
- The overlay draws not-yet-scanned objects amber with a "label ..." tag and scanned ones green with a "check label" tag; solid vs dashed (visible vs remembered) is unchanged.
- Chosen over "counted by the core" because the core lifts objects late and only some classes; the sighting count is available immediately and is thread-safe.
- When the `segmentation` flag is on (and not the unguided arm) but the scheduler is null (model files missing, GPU cannot run them) or disables itself mid-scan, the HUD shows a grey "Object boxes unavailable" chip and logs once under CKCapture, instead of failing silently.
