# 0008: The core selects keyframes, the shell encodes the JPEG (request/ack handshake)
Status: accepted (2026-11-14). The core only receives luma, so it cannot produce JPEGs, and platform encoders
(Android YuvImage, iOS CIContext) are the only ones we should ship. `ck_ingest_frame` copies luma into one of
`frame_slots` fixed buffers; the selector decides; the core emits `keyframe_request{frame_id,file}`; the shell
encodes from a short ring of its own copies to `<file>.tmp`, renames, and calls `ck_keyframe_written`. A request
unacknowledged for `keyframe_ack_timeout_s` of frame time becomes a non-keyframe (`ENCODE_MISSING`), so
/frame_index never points to a missing file; unreferenced JPEGs are deleted at finalize. /frame_index records are
written in t_ns order through a reorder buffer.
