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
| AVFoundation microphone capture | CPAL with PulseAudio and ALSA/PipeWire bridges | Implemented |
| Carbon event hotkey | X11 passive key grab | Implemented for modifier-plus-key shortcuts |
| Accessibility and paste injection | Desktop clipboard and XTest paste | Implemented with manual-paste fallback |
| NSWorkspace application context | X11 active-window metadata | Implemented for X11 targets |
| Keychain credential storage | Secret Service | Implemented with session-only fallback |
| SwiftUI menu bar and overlay | Electron tray, settings, and HUD | Not implemented |

## Implementation Status

| Subsystem | Status | Notes |
| --- | --- | --- |
| Rust workspace | Complete | Six bounded application crates and a deterministic mock-service crate build together. |
| Core state machine | Complete | Explicit transitions, cancellation, duplicate-start protection, timeout behavior, and transcript recovery have unit coverage. |
| OpenAI realtime | Complete | The client streams 24 kHz PCM over the current transcription session protocol and collects partial and final events; the deterministic service verifies the wire flow. Live-service validation remains opt-in. |
| Batch fallback | Complete | Multipart WAV transcription is cancellable, bounded by a deadline, and covered against the local service. |
| Audio capture | Complete | CPAL enumerates PulseAudio and ALSA inputs, downmixes and resamples callbacks, bounds recordings, publishes levels, and falls back when a selected device disappears. A live PipeWire-backed preview completed on the development host. |
| X11 shortcut | Partial | XGrabKey registers ordinary combinations, handles lock modifiers, distinguishes press/release, filters auto-repeat, and unregisters cleanly. Modifier-only XInput2 support and Xvfb verification remain. |
| Wayland shortcut | Partial | The daemon detects Wayland, refuses misleading XWayland-only registration, and exposes window/tray controls with an actionable limitation. Portal registration remains. |
| X11 injection | Partial | Clipboard plus XTest selects Ctrl+V or terminal-safe Ctrl+Shift+V and retains the transcript on fallback. X11 target-matrix verification remains. |
| AT-SPI injection | Deferred | Clipboard delivery has priority. |
| Application context | Partial | Active window, PID, process, class, title, desktop, and terminal hints are collected over X11. Toolkit editability remains deferred. |
| Credential storage | Complete | Secret Service holds persistent keys; environment and explicit session-only keys remain in memory. Ordinary JSON settings contain no credential fields and use mode 0600. |
| Local RPC | Complete | JSON-RPC WebSockets bind to an ephemeral loopback port, authenticate a random launch token, admit one shell, carry notifications, and pass auth/request/error tests. |
| Rust daemon | Complete | The daemon supervises the pipeline, hotkey, previews, settings, diagnostics, signals, and authenticated RPC; its ready record is machine-readable. |
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
