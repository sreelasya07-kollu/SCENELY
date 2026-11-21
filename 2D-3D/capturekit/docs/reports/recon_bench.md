# Recon bench: device scans (issue #7)

`ckit recon-bench` on the two recorded bundles (pycolmap, CPU, 1 thread, seed 0). Key meanings:
`docs/quality.md` "Reconstruction bench".

| key | scan_20261117_215819 (walked) | scan_20261117_212703 (tap test) | delta (walked - tap) |
|---|---|---|---|
| package_bytes (manifest-listed files) | 17448086 | 1319474 | +16128612 |
| keyframes | 80 (sampled from the bundle's keyframes, cap 80) | 10 | +70 |
| reproj_images | 118 (all posed keyframes) | not recorded | |
| registered_pct | 98.75 | 20.0 | +78.75 |
| mean_reproj_px | 1.458 | 2.3035 | -0.8455 |
| sparse_points | 11341 | 57 | +11284 |
| coverage_yaw_pct | 88.89 | 22.22 | +66.67 |
| seconds (not in JSON) | 597.6 / 758.0 (two runs, final code) | 13.0 | |

Determinism: each scan was run twice and `cmp` reports the two JSON files identical (`seconds` is
printed only, never written to JSON).

Commands (WSL, env per `capturekit/scripts/README.md`, from `capturekit/tools`):

    uv run ckit recon-bench ../build/device/bundles/scan_20261117_215819 --json ../build/rb/a.json
    uv run ckit recon-bench ../build/device/bundles/scan_20261117_215819 --json ../build/rb/b.json
    cmp ../build/rb/a.json ../build/rb/b.json
    # same for scan_20261117_212703; side by side: add --baseline ../build/device/bundles/<other>

JSON goes under `capturekit/build/rb/` (git-ignored).

Notes:
- The tap test has only 10 keyframes, so its 20 % free-SfM registration is expected and not a quality
  verdict on the app.
- The issue asks for a second walked room. None exists: BLOCKED until a new device recording.
- The walked scan took about 10 to 13 minutes single-threaded (WSL, machine load varies) (below the 15 minute limit in the brief),
  so no switch to sequential matching was needed.
- `keyframes` and `registered_pct` use the sampled list (80); `reproj_images`, `mean_reproj_px` and
  `sparse_points` use all posed keyframes (118 for the walked scan).
