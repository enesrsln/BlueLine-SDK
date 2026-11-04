# Changelog

## 1.0.0 — 2026-11-03

First release, for BlueLine devices with firmware 0.3.0 and newer (BlueLine-4).

- SDKs for iOS / macOS (Swift), Android (Kotlin), Flutter (Dart) and
  Python (Windows, macOS, Linux).
- Scan, connect, device information, serial number and firmware revision.
- Multi-channel EEG at 250 Hz and 3-axis accelerometer at 100 Hz, as raw counts or
  physical units.
- Gain control, LED identify, battery and status with loss counters.
- Session tracking and lost-sample detection.
- Signal processing: Butterworth filters, notch, power spectrum and EEG band
  powers, identical on every platform.
- Python: CSV recording.
- Shared protocol and processing test vectors.
