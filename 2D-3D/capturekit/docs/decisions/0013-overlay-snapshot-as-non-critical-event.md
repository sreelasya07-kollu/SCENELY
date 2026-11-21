# 0013 — Overlay Snapshot Ships as a Non-Critical Event, Not a C API Accessor

Phase 11 build 1 says "C API accessors"; for the glanceable "what the app understands" UI we instead emit
`{"type":"overlay",...}` through the existing `ck_poll_events` every 500 ms of event time (non-critical:
dropped and counted when the outbound queue is full, never written to the bundle). Reason: no `capturekit.h`
change, no new JNI/Swift surface, shells already parse events. `ck_overlay_get` stays deferred; if a pull model
is needed later, write a new ADR. Event is flat JSON < 4 KB (walls are one delimited string); all `why` text
comes from the core catalog (`overlay.cpp`), at most 8 words.
