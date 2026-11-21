# Scan Bundle v1.4.0

The Scan Bundle is the contract between capture and everything downstream. `ckit validate` is the executable definition of "valid". Conventions: [conventions.md](../../../docs/program-spec/conventions.md). This supersedes the `video.mp4` layout in older docs (ADR 0001).

## Layout
```
<bundle>/
  manifest.json        written LAST; lists every other file with sha256 + size
  camera.json          nominal camera (first intrinsics), image storage orientation, IMU extrinsic
  streams.mcap         MCAP, protobuf channels (below), chunked, uncompressed, summary on finalize
  keyframes/NNNNNN.jpg JPEG keyframes, sensor-native orientation, no EXIF orientation
  guidance_log.json    optional, GuideMind log (Phase 8)
  privacy/redaction.json  face-redaction log, role `redaction`, since 1.2.0 (ADR 0020, 0021); required when `privacy.redaction_mode` is `faces`
```

## Channels (`messages/capturekit.proto`, schema data = `messages/capturekit.desc` FileDescriptorSet)
| Topic | Message | Required | Rate |
|---|---|---|---|
| `/pose` | `capturekit.v1.Pose` | yes | AR frame rate |
| `/imu/gyro` | `capturekit.v1.ImuSample` | yes until 1.3.0; optional since 1.4.0 (ADR 0034: not recorded by default) | ≥100 Hz typical when present |
| `/imu/accel` | `capturekit.v1.ImuSample` | yes until 1.3.0; optional since 1.4.0 (ADR 0034: not recorded by default) | ≥100 Hz typical when present |
| `/intrinsics` | `capturekit.v1.Intrinsics` | yes (≥1 before first keyframe) | on change |
| `/frame_index` | `capturekit.v1.FrameIndex` | yes | per candidate frame |
| `/events` | `capturekit.v1.Event` | yes (may be empty) | sparse |
| `/ar/points` | `capturekit.v1.PointCloud` | optional (ADR 0004) | ≤ frame rate |
| `/ar/planes` | `capturekit.v1.PlaneAnchor` | optional (ADR 0004) | on update |
| `/ar/detections` | `capturekit.v1.Detections` | optional, since 1.1.0 (ADR 0016) | per keyframe |
| `/guide/labels` | `capturekit.v1.RoomLabels` | optional, since 1.3.0 (ADR 0028), derived | on change, <= 1 Hz |
| `/guide/shell` | `capturekit.v1.RoomShell` | optional, since 1.3.0, derived | on change, <= 1 Hz |
| `/guide/gaps` | `capturekit.v1.RoomGaps` | optional, since 1.3.0, derived | on change, <= 1 Hz |

`/events` tracking recovery records (ADR 0031, source `guide`, no schema change): `TRACKING_LOST` (attrs `tracking_state`, `reason`, `degraded_s`) when tracking has not been NORMAL for 2 s and keyframe capture pauses, and `TRACKING_RESET` (attrs `lost_s`, `drift_m`, `drift_deg`: the pose jump across the loss) when tracking is back and the session is re-anchored. `/frame_index` records between them carry the reason `RECALIBRATING` and are never keyframes.

The MCAP `log_time` and `publish_time` of each message equal its `t_ns`. Within a channel, `t_ns` is strictly increasing.

## Versioning (semver on `manifest.schema_version`)
- **Major** changes break readers. Readers reject an unknown major with `UNSUPPORTED_MAJOR` (ERROR).
- **Minor** changes add fields, channels or optional files. Readers accept an unknown minor with `UNKNOWN_MINOR` (WARN) and ignore what they don't understand.
- **Patch** changes are documentation or validator-tolerance changes only.
- History: 1.0.0 first release; **1.1.0** adds `/ar/detections` and `manifest.counts.detections` (additive: a 1.0.0 bundle validates unchanged, readers ignore the channel).
- **1.2.0** adds manifest blocks `consent` and `privacy`, file role `redaction`, and the codes CONSENT_MISSING, REDACTION_MANIFEST_MISSING (ERROR, only when schema_version >= 1.2.0) and REDACTION_ENTRY_NO_FILE (INFO). Bundles of 1.0.0 and 1.1.0 carry neither block and validate unchanged. A writer stamps 1.2.0 only when it was given consent or redaction metadata, so research and synthetic bundles stay 1.1.0.
- **1.3.0** adds the derived channels `/guide/labels`, `/guide/shell`, `/guide/gaps`, `manifest.counts.guide_labels|guide_shell|guide_gaps` (written only when non-zero) and the codes GUIDE_OUTPUT_BAD_VALUE (WARN) and LABEL_WALL_UNKNOWN (INFO). Bundles of 1.0.0 to 1.2.0 carry none of it and validate unchanged; readers that do not know the channels ignore them. A writer stamps 1.3.0 only when it wrote at least one record on these channels (understanding on and something found), so every other bundle keeps 1.1.0 or 1.2.0. Because 1.3.0 >= 1.2.0, the consent and privacy rules apply to such bundles (ADR 0020).
- **1.4.0** (ADR 0034, issue #10) makes `/imu/gyro` and `/imu/accel` optional: the live capture no longer records the IMU unless `record_imu` is set (`capture_settings.record_imu` says which), because no downstream step reads it. The channels stay registered (empty) in streams written by our writer, and `counts.imu_gyro|imu_accel` stay required (0 when not recorded). A writer stamps 1.4.0 only when the IMU was not recorded, so research bundles with IMU keep their older version. Bundles of 1.0.0 to 1.3.0 validate unchanged. It also defines the archive form (below) and the code ARCHIVE_UNREADABLE.
- Protobuf field numbers are never reused. New fields are additive and belong to a minor bump.

## Archive form (since 1.4.0, ADR 0034)
A bundle may be sent as ONE zip, `<bundle folder name>.zip`, holding exactly the files of the layout above at the zip root (no wrapping folder): `manifest.json` first, then the files it lists, sorted; JPEGs stored, everything else deflated; fixed entry timestamps. Nothing outside `manifest.json` and its `files` list may be in it. `ckit pack <folder>` creates and verifies it (CRCs, then every listed size and sha256, then the validator); `ckit validate`, `verdict`, `replay` and `recon-bench` accept the `.zip` in place of the folder. Readers must refuse entries with absolute paths, `..`, backslashes or symlinks, and bound the entry count, the unpacked size and the free space needed (the reference limits are 20 000 entries and 4 GiB, with 10 % free-space margin; names that differ only in case, or contain `:`, count as unsafe); an archive they cannot open safely is ARCHIVE_UNREADABLE. The folder form stays valid.

## Validator (`ckit validate <bundle|bundle.zip> [--level structural|integrity|semantic|quality]`)
The levels are cumulative. Output is a JSON report (`{"verdict", "issues":[{"code","severity","level","message","where"}]}`) plus a human summary. Exit code 1 if any ERROR.

| Code | Severity | Level | Meaning |
|---|---|---|---|
| ARCHIVE_UNREADABLE | ERROR | structural | the `.zip` cannot be opened safely: not a zip, unsafe entry name, symlink, duplicate name, damaged entry, or over the entry / size limit |
| MISSING_MANIFEST | ERROR | structural | no manifest.json |
| MANIFEST_SCHEMA | ERROR | structural | manifest.json is not valid JSON or fails the schema |
| UNSUPPORTED_MAJOR | ERROR | structural | schema_version major is not 1 |
| UNKNOWN_MINOR | WARN | structural | schema_version minor is newer than the validator |
| CAMERA_SCHEMA | ERROR | structural | camera.json missing, unparsable or fails the schema |
| MISSING_FILE | ERROR | structural | a file listed in the manifest does not exist |
| MCAP_TRUNCATED | ERROR | structural | streams.mcap has no valid footer or summary (not finalized) |
| MCAP_UNREADABLE | ERROR | structural | streams.mcap cannot be parsed even by sequential scan |
| MISSING_CHANNEL | ERROR | structural | a required channel is absent |
| SHA256_MISMATCH | ERROR | integrity | file hash differs from the manifest |
| SIZE_MISMATCH | ERROR | integrity | file size differs from the manifest |
| CONSENT_MISSING | ERROR | structural | schema >= 1.2.0 and `manifest.consent` lacks a non-empty `version`, or `at` is empty or not an ISO 8601 time (`YYYY-MM-DDThh:mm:ss[.f]Z` or with `+hh:mm`) |
| REDACTION_MANIFEST_MISSING | ERROR | structural | schema >= 1.2.0 and `manifest.privacy.redaction_mode` is absent, or is `faces` while `privacy/redaction.json` is not listed |
| REDACTION_ENTRY_BAD_PATH | WARN | integrity | an entry of `privacy/redaction.json` names a file that does not resolve under `keyframes/` (`..`, absolute path); the entry is ignored |
| REDACTION_ENTRY_NO_FILE | INFO | integrity | a status `ok` entry of `privacy/redaction.json` names a keyframe that is not on disk (the log is flushed every 10 entries, so a forced kill can leave one) |
| UNLISTED_FILE | WARN | integrity | a file in the bundle is not listed in the manifest |
| NON_MONOTONIC_TIME | ERROR | semantic | t_ns not strictly increasing within a channel, or log_time ≠ t_ns |
| NAN_VALUE | ERROR | semantic | NaN or Inf in a pose, IMU sample or intrinsics |
| TIME_ZERO | ERROR | semantic | a `/pose` or `/intrinsics` record has `t_ns` <= 0 (unmapped platform clock; the core rejects such input since 2026-11-17, older recordings may carry it) |
| NON_UNIT_QUATERNION | ERROR | semantic | abs(norm(q) − 1) > 1e-3 |
| MISSING_INTRINSICS | ERROR | semantic | no /intrinsics at or before the first keyframe |
| KEYFRAME_WITHOUT_POSE | ERROR | semantic | no pose within ±50 ms bracketing the keyframe (interpolable) |
| KEYFRAME_FILE_MISSING | ERROR | semantic | frame_index keyframe references a file that is not in the bundle |
| COUNT_MISMATCH | WARN | semantic | manifest counts differ from the MCAP |
| KEYFRAME_TRACKING_LIMITED | WARN | semantic | keyframe captured while tracking is not NORMAL |
| POSE_GAP | WARN | semantic | gap > 500 ms in /pose, not counting time inside a pause recorded in `/events` (`SESSION_PAUSED` until `SESSION_RESUMED` or stop) |
| NO_KEYFRAMES | ERROR | semantic | no keyframes at all |
| FEW_KEYFRAMES | WARN | semantic | 1 to 9 keyframes |
| NO_AR_GEOMETRY | INFO | semantic | /ar/points and /ar/planes both absent |
| DETECTION_BAD_BOX | WARN | semantic | a `/ar/detections` box has a non-finite value, x1 <= x0, y1 <= y0 or score outside [0,1] |
| DETECTION_UNKNOWN_FRAME | INFO | semantic | a `/ar/detections` record names a frame_id absent from `/frame_index` |
| GUIDE_OUTPUT_BAD_VALUE | WARN | semantic | a `/guide/*` item has a non-finite number, a `conf`/`pri` outside [0,1], an object size <= 0, an opening kind other than 0/1, a gap type outside 0..5, an odd `corners` count or a `ceiling_h` <= 0 |
| LABEL_WALL_UNKNOWN | INFO | semantic | an opening in `/guide/labels` names a wall id that no `/guide/shell` record lists |
| PARTIAL_BUNDLE | WARN | semantic | completion.status is partial or recovered |
| QUALITY_NOT_EVALUATED | INFO | quality | quality level is a stub until Phase 4 metrics are present |

Verdict: any ERROR → `FAIL`, else any WARN → `WARN`, else `PASS`.

`/ar/detections` (1.1.0): one record per keyframe, `t_ns` = that keyframe's `t_ns`, `frame_id` as in `/frame_index`; `boxes[]` = {`cls` core object class id, `score` 0..1, `x0,y0,x1,y1` pixels of the stored JPEG, top-left origin}; empty `boxes` means the detector ran and found nothing. Core class ids: `capturekit/core/include/capturekit/guide/understanding.hpp`. Class ids are append-only (ADR 0030): 0 unknown, 1 chair, 2 couch, 3 bed, 4 dining_table, 5 tv, 6 potted_plant, 7 laptop, 8 bench, 9 toilet, 10 sink, 11 refrigerator, 12 oven, 13 desk, 14 shelf, 15 cabinet, 16 lamp (8..16 added without a schema bump: the field already meant "a core class id"; a reader treats an id it does not know as unknown). The same ids are used by `/guide/labels`.
Consent and privacy (1.2.0, ADR 0020): `manifest.consent` = {`version` consent-text version, `at` ISO 8601 UTC time of acceptance}; `manifest.privacy` = {`redaction_mode`: `none` | `faces`}. Both are supplied by the capture shell (the core never reads a clock). `faces` means keyframe JPEGs were blurred best-effort before being written (ADR 0021) and `privacy/redaction.json` (role `redaction`) logs each keyframe; a status `dropped_detector_failure` entry names a keyframe that was deliberately not written. Screens and view-consistent 3D masking are not covered by 1.2.0.

Note: several plane anchors updated in one AR frame share a timestamp. Writers add +1 ns to each later anchor in the same frame, which keeps `t_ns` strictly increasing on `/ar/planes`.

Derived guidance outputs (1.3.0, ADR 0028): what the capture core's guidance engine understood about the room, in the world frame (Y up, metres). Records are written when the published value changes (checked at most once per second of event time) plus one final check at finalize, so the last record of each channel is the end state; an empty record after a non-empty one means the content was withdrawn. They exist only when the engine's `understanding` switch was on. `/guide/labels` = `objects[]` ({`id`, `cls` core object class id, box centre `cx,cy,cz`, size `sx,sy,sz` = width, height, depth, `yaw` about +Y, `conf`, `n_obs`}) and `openings[]` ({`kind` 0 door / 1 window, `wall` shell wall id or empty, footprint `x0,z0,x1,z1`, heights `y0,y1` above the floor, `conf`}). `/guide/shell` = `walls[]` ({`id`, `x0,z0,x1,z1`, `inferred`}), packed `corners` x,z pairs, `closed`, `low_confidence`, `ceiling_h`, `ceiling_inferred`. `/guide/gaps` = `gaps[]` ({`type` 0 missing_wall, 1 unseen_corner, 2 unseen_ceiling, 3 unseen_floor, 4 occluded, 5 weak; `x0,z0,x1,z1`, `pri` 0..1, `why` templated phrase}). All values are estimates from sparse phone data, not ground truth; Part 2 may ignore these channels.
