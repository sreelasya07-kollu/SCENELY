# 0036 Pre-scan stillness calibration (contract C1) and IMU recorded by default on Android

Status: accepted (2026-11-22).

- Android app default `record_imu=1` (core default stays 0, so import-raw, goldens and lean-bundle tests are unchanged). See the update line in ADR 0034.
- Before Start the app closes and resumes ARCore (fresh world origin), then collects a 2.0 s still window: gyro RMS <= 0.02 rad/s, |mean accel| within 9.80665 +- 0.25, accel norm std <= 0.05 (guesses). Start stays blocked until still and TRACKING; hold-still is never skippable; after 10 s not still the hint reads "Rest the phone on a table".
- No API resets the hardware gyro. The window's mean gyro (and uncalibrated drift estimate when the sensor exists) is recorded only, never subtracted: SensorBridge stays raw and Part 2 decides.
- Contract C1: session config keys `calib.gyro_bias_x|y|z`, optional `calib.drift_x|y|z`, `calib.duration_s`, `calib.gyro_rms`, `calib.accel_norm`, `calib.accel_std`; each triple whole or not at all. Manifest `capture_settings.stillness_calibration` (free object, no schema bump). Frame: device sensor frame, natural orientation. The iOS port reads this as read-only.
