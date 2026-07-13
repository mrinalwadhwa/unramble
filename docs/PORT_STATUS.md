# Linux Port Status

This document records the implemented behavior of the experimental Linux
application. The native macOS application remains the production build.

## Behavioral Baseline

The Linux implementation preserves the macOS workflow: hold a global shortcut
to record, release it to finish, transcribe speech, optionally clean the result,
and insert it without losing a successful transcript when delivery fails.

The native implementation establishes these concrete rules:

- Ignore activation unless the recorder is idle, and ignore release unless a
  recording is active.
- Capture 16 kHz mono signed 16-bit PCM and wrap the same samples in a standard
  44-byte RIFF/WAV header for request-response transcription.
- Reject captures shorter than 100 ms. Use a fixed RMS silence threshold of
  `0.005` when calibration is unavailable; use
  `clamp(ambient RMS * 1.2, 0.0005, 0.01)` for near-field microphones and
  `0.001` for far-field microphones.
- Calibrate ambient RMS from roughly the first 500 ms. Far-field software gain
  targets RMS `0.02`, clamps gain to `1...16`, and clamps amplified samples to
  the signed 16-bit range.
- Scale the end-to-end processing deadline as
  `min(recording duration + 45 seconds, 300 seconds)`. Realtime transcript
  waiting uses `min(15 seconds + audio duration / 2, 300 seconds)`.
- Capture application context while audio starts, stream PCM during recording,
  and fall back to complete-file transcription when streaming fails.
- Store every successful non-empty transcript before attempting insertion.
  Keep it available after insertion failure and expose retry, copy, and paste
  recovery actions.
- Apply deterministic dictated-punctuation and filler cleanup before optional
  model-based polish. Keep the original language and wording, preserve explicit
  symbols, reject aggressively truncated polish output, and fall back to the
  deterministic result when polish fails.
- Prefer direct editable-field insertion where it is dependable. Prefer
  clipboard paste for terminals, browsers, and Electron applications. Do not
  restore the prior clipboard before the application has consumed the paste.
- Read active-application context within a 200 ms total budget and limit an
  individual accessibility field read to 50 ms.

## Platform Replacements

| macOS capability | Linux replacement | Current state |
| --- | --- | --- |
| AVFoundation microphone capture | Native Linux audio backend | Not implemented |
| Carbon event hotkey | X11 global key handling | Not implemented |
| Accessibility and paste injection | X11 clipboard and synthetic paste | Not implemented |
| NSWorkspace application context | X11 active-window metadata | Not implemented |
| Keychain credential storage | Secret Service | Not implemented |
| SwiftUI menu bar and overlay | Electron tray, settings, and HUD | Not implemented |

## Implementation Status

| Subsystem | Status | Notes |
| --- | --- | --- |
| Rust workspace | Complete | Six bounded application crates and a deterministic mock-service crate build together. |
| Core state machine | Complete | Explicit transitions, cancellation, duplicate-start protection, timeout behavior, and transcript recovery have unit coverage. |
| OpenAI realtime | Complete | The client streams 24 kHz PCM over the current transcription session protocol and collects partial and final events; the deterministic service verifies the wire flow. Live-service validation remains opt-in. |
| Batch fallback | Complete | Multipart WAV transcription is cancellable, bounded by a deadline, and covered against the local service. |
| Audio capture | Not started | Linux backend has not been selected. |
| X11 shortcut | Not started | Push-to-talk must distinguish press and release. |
| Wayland shortcut | Deferred | Portal feasibility will follow the X11 path. |
| X11 injection | Not started | Transcript retention is required on failure. |
| AT-SPI injection | Deferred | Clipboard delivery has priority. |
| Application context | Not started | X11 metadata is sufficient for the first build. |
| Credential storage | Not started | Plaintext persistent secrets are prohibited. |
| Local RPC | Not started | The listener will bind only to loopback. |
| Electron tray | Not started | Business logic will stay in the daemon. |
| HUD | Not started | It must never take focus. |
| Settings and onboarding | Not started | API key, microphone, shortcut, and polish settings are required. |
| Diagnostics | Not started | Exports must redact secrets and transcript content. |
| Transcript polish | Complete | The deterministic cleanup, clean-input bypass, restrained prompt, safe-output check, and API failure fallback have coverage. |
| Mock service and smoke test | Partial | The service scripts realtime, batch, polish, authentication, rate-limit, delay, malformed-response, and disconnect behaviors. Provider integration tests pass; the desktop smoke path remains. |
| Linux packaging | Not started | A reproducible development build comes first. |

## Intentionally Deferred

- Offline speech models and Apple-specific model runtimes.
- Full Windows support.
- Direct AT-SPI editing unless the clipboard path is complete and reliable.
- Broad Wayland compositor support beyond honest detection and safe fallback.
- Release signing and automatic updates.

## Algorithms Suitable for Direct Porting

- Explicit recording transitions and immediate state publication.
- RIFF/WAV encoding, linear 16-to-24 kHz resampling, RMS measurement, adaptive
  silence gating, far-field gain, and clipping prevention.
- Transcript buffering before insertion and recovery after failure.
- Dictated punctuation substitution, filler-sound removal, formatting cleanup,
  prompt-injection sanitization, and destructive-output detection.
- Duration-scaled network deadlines and bounded fallback behavior.
- Smart leading-space behavior when editable-field cursor context is known.

## Unclear Behavior

- Modifier-only shortcut behavior needs a different X11 event mechanism from
  ordinary passive key grabs and varies under XWayland.
- Clipboard restoration stays disabled until paste consumption can be detected
  without risking transcript loss.
- X11 does not expose toolkit-neutral editable-field contents, so smart spacing
  requires AT-SPI and is deferred from the first clipboard implementation.
