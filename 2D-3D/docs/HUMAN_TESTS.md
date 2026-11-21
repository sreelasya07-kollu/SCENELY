# Human tests

The list of tests only the human can run (phone, people, accounts, decisions). Updated by each batch of the unattended queue; tick items as done.

## Setup
Phone: phone CPH2381 with USB debugging, `adb devices` shows it; `adb shell getprop ro.build.version.sdk` (note it; < 31 means no voice commands); install `cd capturekit/android && ./gradlew :sample-app:installStandardDebug` (field build: `-PTUS_URL=http://<LAN-IP>:1080/files/ :sample-app:installFieldDebug`). Bundle path = the "Saved:" line on the Review screen, pull with `adb pull <path>`.

## Tests

### Phase 0-1 recordings (Gate 0)
- [ ] H1 record G1-G8 per docs/program-spec/recording-protocol.md in 10+ real rooms, folder `G<n>_<device>_<yyyymmdd>_<nn>` under capturekit/bench/golden/. Pass: `ckit inspect-raw` and `ckit import-raw` + `ckit validate --level quality` give 0 ERROR for each.
- [ ] H2 clock: `ckit inspect-raw <clock-session> --clock`; pass: offsets recorded in docs/program-spec/clock-notes.md, any > 1 ms applied.
- [ ] H3 checkerboard (ADR 0003/0005): `ckit reprojection-report`; pass: calibrated cx, cy within 0.5 px of platform intrinsics or ADR updated.

### Phase 5-6 capture/soak
- [ ] H4 follow capturekit/docs/capture-test-protocol.md and soak-test.md (10 min). Pass: no crash, thermal level logged, forced-kill then `ckit recover DIR` keeps data.

### Stability (docs/android-perf-baseline.md)
- [ ] H5 R1-R7 x3 (Back/Finish/Home/power/relaunch cases) with `adb logcat -d | tail -n 200` after each. Pass: 0 crashes in 21 runs or each crash logged; fill the "?" cells.
- [ ] H6 frame pacing A/B row, Activity.onPause timing (< 200 ms target as measured), 60 s walk table (keyframes/min, drops < 5 %, GC lines < 1/min).
- [ ] H7 only if crashes persist: allowNativeHeapPointerTagging A/B over 10 runs, then decide to code stability step 8.

### Guidance and UX
- [ ] H8 `adb logcat -s CK/Voice` over 20 prompts; pass: median instruction to TTS start < 500 ms.
- [ ] H9 walk 60 s: screenshots of HUD (no overlap at 59 s), RoomView walls filling and the yaw ring moving in a plain room, checklist read by TalkBack ("Walls: 2 done, 1 scanning"), finish glow + haptic, wall tick haptic at 80 %.
- [ ] H10 Review sheet screenshot with a weak wall; "Scan the gaps" resumes the same bundle; "Finish anyway" finalizes.
- [ ] H11 mini map moves as you walk (no lag > 1 s).

### Voice (needs API 31+ and an on-device speech pack)
- [ ] H12 airplane mode on, 20 spoken commands (pause, resume, repeat, what is missing, finish + confirm, louder, quieter); pass: median speech end to action < 1 s in `adb logcat -s CK/Voice`, mic hidden with a plain message when no pack; permission rationale shows before the first RECORD_AUDIO prompt.

### Privacy and consent
- [ ] H13 first launch shows consent; Start blocked until accepted; revoke in Home works; new bundle manifest has consent.version (`ckit validate <bundle>` OK).
- [ ] H14 redaction: 60 s walk with a consenting person in view; pull bundle, open 10 keyframes; pass: faces blurred, privacy/redaction.json present, keyframes/min within 10 % of baseline; record recall on a labelled face set (indicative) and open the BlazeFace PDF to confirm the weights licence (ADR 0021) before adopting it.
- [ ] H15 legal owner signs consent text and retention; until then uploads only to the team dev server from internal testers.

### Upload (field flavour)
- [ ] H16 `cd capturekit/dev-server && docker compose up -d`, phone on the same LAN, scan, Upload; pass: bundle reaches COMPLETE (`./smoke.sh` equivalent on the server).
- [ ] H17 airplane mode mid-upload then off; pass: resumes, state goes retrying then verified; My scans list shows the state; FAIL verdict hides Upload.

### Phase 9 (after U8-A/U11-A)
- [ ] H18 `adb shell setprop debug.capturekit.understanding 1` (and `debug.capturekit.detector 1`) then walk a furnished room with a door and a window; pass: map shows objects/openings, manifest counts detections > 0, `ckit validate --level quality` no new ERROR; flag off behaves as before.
- [ ] H19 detector latency per device (one device = one tier, say so) and the ADR 0024 on_plane_tol 0.04 check: no false openings punched into walls in 3 real rooms.
- [ ] H20 walk 3 real rooms before enabling gap steering (planner flag stays OFF until then).
- [ ] H21 read COCO terms and confirm weights redistribution (ADR 0017), else drop detector.

### Guidance tuning
- [ ] H22 `ckit replay <real bundle> --sink guide` and `ckit guide-eval <bundle>`; pass: instruction rate and completeness sane vs sim (ADR 0023); retune knobs through extraConfig `guide.*`.

### Trials (Phase 12)
- [ ] H23 follow capturekit/docs/trial-protocol.md: 3+ rooms, guided vs unguided, then `ckit e2e BUNDLE --research JSON` and `ckit trial-report DIR`; pass: report produced, Phase 12 targets compared once the owner sets them.

### Part 2
- [ ] H24 send 3-5 real bundles to roomscan-recon, tell them schema 1.1.0/1.2.0/1.3.0 are additive; pass: their reader accepts them.

### Owner decisions
- [ ] H25 confirm or change ADR 0018 items 1-17 (depth, tiers, locales, legal owner, Mac, detector scope, gaps flag, schema order, flavour, redaction, voice, wall names, haptics, camera image size, speed targets, Phase 12 targets); set APK size limit in scripts/apk_size.sh; device matrix (docs/device-matrix.md); TUS_URL and SENTRY_DSN values as gradle properties (never committed). Owner decisions line: set the APK size limit in scripts/apk_size.sh knowing the detector adds ~6 MB (LiteRT runtime) to BOTH flavours (code is in the shared lib; the model file itself is fetched, not committed); the measured debug APKs were 124 MB standard and 150 MB field (debug, all ABIs, unstripped), so the limit must be set on a release build.

### CI/iOS
- [ ] H26 push is yours: check the Actions page for core, sanitizers, python, upload, android (both flavours), schema-compat, ios jobs;
- [ ] H27 iOS needs a Mac or a green macOS job: first session = compile-and-fix only, then Swift ports of overlay, guidance HUD, voice, review, consent.

## Added at the end of the unattended run (code for these is in the uncommitted tree on top of b3d39f0)

### Unblocked by code (you can run them once the tree is built and installed)
H8 and H12 (voice: VoiceController, repeatLast, mic hidden below API 31), H13 and H15 (consent screen, Start gate, revoke), H14 (redaction, with `consent`/`privacy` in manifest 1.2.0), H16 and H17 (My scans, upload states), H23 (research log in the field build). Still blocked on code: H18 and H19 (debug flags `debug.capturekit.understanding` / `.detector` and the room shell/gap wiring are U11-A, not done; the detector worker exists but nothing starts it), H20 (U10-C not done), H22 (ADR 0023 not written).

### New device checks
- [ ] H28 Consent flow: fresh install shows the consent screen (placeholder text, "pending legal owner"); Start is blocked until accepted; "Withdraw consent" in Home returns to the blocked state. Pass: new bundle manifest has `consent.version`, `consent.at` and `privacy.redaction_mode = faces`; `ckit validate <bundle>` has no CONSENT_MISSING.
- [ ] H29 My scans and upload states: finish 3 scans (one weak enough for a FAIL verdict). Pass: list shows waiting/uploading/retrying/verified/failed; FAIL hides Upload; the unmetered-only toggle holds uploads on mobile data. Revoke consent while an upload is queued: pass = the queued upload does not start (check `adb logcat` and the dev server).
- [ ] H30 Sentry (field flavour only): build with `-PSENTRY_DSN=<dsn>` and accept telemetry consent; trigger a handled test error; pass: event arrives with no file paths or bundle names. Empty DSN or no telemetry consent: nothing sent. Standard flavour: no Sentry classes (`apk_size.sh`/merged manifest has no INTERNET).
- [ ] H31 Voice on API 31-32: these need the on-device English speech pack downloaded in system settings; note the SDK level and whether the pack was present; without the pack the mic must hide with a plain message. (Also see H12.)
- [ ] H32 Research log (field flavour): participant code, optional room label and arm at setup; after a scan `<bundle>.research.json` sits next to the bundle directory, is not inside it, and is not uploaded (check the server copy). Standard flavour shows no trial setup.
- [ ] H33 Detector flag and model: `capturekit/scripts/fetch_models.sh` (sha256 pinned) then rebuild; app runs identically with the model absent. The detector is OFF by default (ADR 0032): on a debug build run `adb shell setprop debug.capturekit.detector 1` and force-stop the app, then test model loading and latency per tier (H19).
- [ ] H34 AIM_TEXTURED prompt: scan a blank or low-texture wall (G8-like, tracking reason INSUFFICIENT_FEATURES). Pass: "Aim at a textured wall" is spoken and shown once, not repeated within the speech budget; EXCESSIVE_MOTION says slow down, INSUFFICIENT_LIGHT says more light.
- [ ] H35 Verdict text: `ckit verdict-export` output equals `sample-app/src/main/assets/verdict_messages.json`; read three verdict messages on the Review screen for wording.
- [ ] H36 Recalibration card (issue #1, ADR 0031; OFF by default, ADR 0032): debug build, `adb shell setprop debug.capturekit.recalibrate_card 1`, force-stop, start a scan, cover the lens for 3+ s, then uncover and turn slowly. Pass: the "Recalibrating" card appears within ~2 s of covering, no keyframe is saved meanwhile, the card dismisses within ~4 s of tracking returning, no crash. Then log it in DEVICE_TEST_LOG.md and flip the default in `FeatureFlags.Flags`.
- [ ] H37 Live object boxes: model and speed (ADR 0035, replaces the SAM 2.1 masks): `capturekit/scripts/fetch_models.sh --with-segmentation` (sha256 pinned, ~62 MB, RF-DETR-Seg Nano on the LiteRT GPU), rebuild, scan a furnished room. Pass: logcat tag CK/Segment says `segmenter ready: rf-detr-seg-nano gpu` (if GPU creation fails the boxes stay off and the scan still works: report the phone and the log line); the camera view stays at its normal frame rate (note FPS with the boxes on and off, and the per-run time); chairs, sofas and the TV get green boxes with a label and #number; the chip "Boxes on/off" hides and shows them. Check the labels are right (the COCO id shift is UNVERIFIED): a chair must not be labelled couch or bed.
- [ ] H38 Live object boxes: stability and return (ADR 0035): walk slowly past a chair at 2 m, then turn away for 10 s and look back. Pass: the box follows the chair at frame rate without jumping; turned away the box disappears; looking back shows the same #number (dashed with `seen`, solid again after the next result); two chairs keep two numbers. Note a wrong number or a box that drifts off the object by more than a hand-width.
- [ ] H39 Hold-still calibration (ADR 0036): open the capture screen. Pass: first "Getting ready", then "Hold the phone still" with a percentage; shaking the phone restarts the count; Start stays disabled until it says Ready AND tracking is on; held in the hand for more than 10 s the line says "Rest the phone on a table"; after Start the bundle's manifest has `capture_settings.stillness_calibration` with a small gyro bias (below 0.02 rad/s) and accel norm near 9.8, and `/imu/gyro` is present (IMU is recorded by default).
- [ ] H40 Completeness, action buttons and Settings (ADR 0035/0036): while scanning the "Complete NN%" chip rises as walls and objects are seen and names the weakest zone; the buttons Repeat, What's missing, Volume - and Volume + do what the matching voice commands do; Finish shows the % and a few weak zones; Settings (Home > Settings) switches each of: object boxes, motion sensors, navigation prompts, voice commands, tracking recovery card, and a change shows at the next scan.
- Feature switches (ADR 0032): guidance, detector, voice commands and the recalibration card are OFF in the default build. Before H9-H12, H18-H22, H31, H33 set the matching property (`debug.capturekit.guidance`, `.detector`, `.voice_commands`) to 1 on a debug build and force-stop the app; docs/STATUS.md section 0 maps each feature to its tests.

## Mac/iPhone verification

Nothing in this section has been run: the iOS code was written on a machine without a Mac or Xcode, so none of it has been compiled yet. Every line starts as NOT RUN. When you run one, change `NOT RUN` to the result and the date, and paste the failing output into docs/DEVICE_TEST_LOG.md if it fails. Paths are relative to the repo root (SCENELY monorepo root, the folder that holds `2D-3D/`).

### Build and unit tests (Mac)
- [ ] M1 NOT RUN: `cd 2D-3D/capturekit/ios && swift build && swift test`. Expect: every test passes (includes the results and upload tests: ResultsGateTests, JobStatusTests, UploadPolicyTests, HomeSettingsTests and the capture-screen tests).
- [ ] M2 NOT RUN: `cd 2D-3D/capturekit/ios && xcodebuild build -scheme CaptureKit -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO`. Expect: BUILD SUCCEEDED.
- [ ] M3 NOT RUN: `cd 2D-3D/capturekit && scripts/build_core_ios.sh && cd ios && CAPTUREKIT_CORE_LIB_DIR=$PWD/../build/ios-core/device swift build`. Expect: the package builds with the C++ core linked.
- [ ] M4 NOT RUN: `cd 2D-3D/capturekit/ios/SampleApp && xcodegen && xcodebuild -scheme SampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`. Expect: BUILD SUCCEEDED. First Mac session = compile-and-fix only (see H27).
- [ ] M5 NOT RUN: `xcodebuild -scheme SampleApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CK_TUS_URL=http://<pc-ip>:1080/files/ CK_VERIFIER_URL=http://<pc-ip>:8081 CK_JOBS_URL=http://<pc-ip>:8090 build` (run in `2D-3D/capturekit/ios/SampleApp`; the PC runs the dev server and job service of 2D-3D/capturekit/dev-server/README.md, "Server-side checks and the job service"). Expect: BUILD SUCCEEDED; without these three settings the app shows no upload buttons and no results screen.

### iPhone checks (device, ARKit needs a real phone)
- [ ] M6 NOT RUN: LiteRT Metal latency and box stability: with models fetched (`capturekit/scripts/fetch_models.sh --with-segmentation`), scan a room with chairs. Expect: segmentation runs on Metal at the speed target of ADR 0037, boxes do not flicker, solid when seen and dashed when remembered; scanned objects turn green with a check, not-yet-scanned stay amber; if the model is missing a grey "Object boxes unavailable" chip shows.
- [ ] M7 NOT RUN: raycast centres: object boxes sit on the object, and the scanned/not-scanned colour changes after the object has been seen from enough sightings.
- [ ] M8 NOT RUN: on-device speech: Settings > voice on, hold the mic button and say "what is missing". Expect: the answer is spoken, recognition works with airplane mode on, and a missing speech pack gives a spoken/printed notice instead of a crash.
- [ ] M9 NOT RUN: face redaction: scan with a person (or a photo of a face) in view, finish, then open a keyframe from the bundle (Files app > CaptureKit > bundles > scan_...). Expect: the face is blurred in the saved JPEG and `manifest.json` records the redaction mode `faces`.
- [ ] M10 NOT RUN: calibration thresholds: open the capture screen. Expect: "Getting ready", then "Hold the phone still" with a percentage; shaking the phone resets it; walking with the phone in the hand and then holding it still ends the card. Note the observed stillness numbers in DEVICE_TEST_LOG.md so the thresholds can be tuned.
- [ ] M11 NOT RUN: CoreMotion axes: record a bundle, then check the `/imu/*` channels in it (M14 validates their presence). Expect: gravity reads about +9.8 m/s² on the axis the spec names (docs/program-spec/conventions.md) with the phone upright and flat, no axis flipped against the Android recording.
- [ ] M12 NOT RUN: capture screen: haptics on tracking loss and finish, Pause/Resume, Finish asks for confirmation, Repeat, What's missing, Volume -/+, then the Review screen opens with the verdict in words.
- [ ] M13 NOT RUN: recalibration card appears after a tracking drift (cover the camera for 3 s while scanning) and the scan continues after it.

### Bundle and server (iPhone plus a computer)
- [ ] M14 NOT RUN: validate an iPhone bundle: copy `bundles/scan_...` from the Files app to the computer, then `cd 2D-3D/capturekit/tools && uv run ckit validate <bundle> --level semantic`. Expect: no ERROR; `manifest.json` has `stillness_calibration`; the bundle has `/imu/*` channels.
- [ ] M15 NOT RUN: upload blocked without consent: Home > Withdraw consent (or accept consent with upload off), open My scans. Expect: the banner "Uploading is off", no Upload button, and nothing uploads.
- [ ] M16 NOT RUN: upload with consent: start the dev server (2D-3D/capturekit/dev-server/README.md), accept consent with upload on, open My scans on a PASS or WARN scan, tap Upload. Expect: "Uploading", then "Uploaded and verified", then a line "Server check: passed" or "usable, with notes"; a FAIL scan shows "A failed scan is never uploaded." and no button.
- [ ] M17 NOT RUN: upload survives a kill: tap Upload on a large scan, force-quit the app, reopen and tap Retry upload. Expect: it finishes without duplicating files on the server (compare `GET <verifier>/bundles/<bundle_id>`: status COMPLETE).
- [ ] M18 NOT RUN: upload reaches job done: after M16, tap View results. Expect: stages move from queued to running to done (poll every 5 s), the verdict banner is the server's, measurements, floor plan (WebView), rescan cards and Downloads show only what the server returned.
- [ ] M19 NOT RUN: rescan from results: on a scan with a "needs_rescan" verdict tap "Rescan this area". Expect: the capture screen opens.
- [ ] M20 NOT RUN: results hidden without servers: install a build with empty CK_JOBS_URL. Expect: no View results button anywhere; with empty CK_TUS_URL or CK_VERIFIER_URL no upload status or buttons in My scans.
- [ ] M21 NOT RUN: download links: in Results tap a file under Downloads. Expect: it opens in Safari or a viewer; a link on another host is refused with "This link is not from the results server."

### From the p3a review fixes and p5 (unverified points)
- [ ] M22 NOT RUN: launch recovery build and run-once: Recovery.swift is guarded by `#if os(iOS) && canImport(CCaptureKit)`. Check that the SampleApp target can import CCaptureKit (the build of M4 plus M3's core lib), then kill the app mid-scan, relaunch and open My scans immediately while launch recovery is still running. Expect: the interrupted scan is recovered exactly once (one bundle, no duplicate or double-finalized folder) and the "recovered" note shows once.
- [ ] M23 NOT RUN: consent screen: Accept unlocks only when the end marker of the consent text is actually on screen (GeometryReader/PreferenceKey check): it stays disabled until you scroll to the end, and also on a short text that fits without scrolling. With VoiceOver on, the consent text is read aloud in full and Accept is announced as disabled until the end is reached.
- [ ] M24 NOT RUN (known follow-up, parity gap from p5, not a check): Android LiveObjectTracker.apply anchors on the remembered centre when the hit test misses, while iOS still uses the centroid pixel. Expect on iPhone: a remembered box may drift or jump slightly when the raycast misses; fix by porting the Android anchoring, then re-run M6 and M7.
