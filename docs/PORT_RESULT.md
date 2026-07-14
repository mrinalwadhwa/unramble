# Linux Port Result

## Executive Summary

FreeFlow now has a usable experimental Linux application beside the unchanged
native macOS application. The installed Linux build launches from desktop
application menus and dmenu, starts hidden on login, registers `Ctrl+Win`,
captures a selected microphone, streams to the OpenAI Realtime transcription
API, optionally polishes the transcript, and inserts it into the field that was
focused when dictation started.

The complete native-Wayland path was exercised on Hyprland 0.55.2 with a
kernel-level Ctrl+Win press/release, deterministic PCM delivered through a
temporary PipeWire/PulseAudio microphone, the live OpenAI service, and an
isolated native-Wayland Chromium textarea. The generated transcript appeared in
the textarea automatically and remained on the clipboard for recovery.

The current user's persistent microphone is `Gaming Webcam [Kiyo] Analog
Stereo`. It is stored by stable PulseAudio ID. FreeFlow pre-opens the stream at
daemon startup, pauses it while idle, and measured about 200 ms from preview
request to ready capture afterward.

## What Works End-to-End

- The packaged Electron shell launches and supervises the bundled Rust daemon,
  authenticates a single loopback WebSocket client, restarts bounded failures,
  and shuts down without the destroyed-window crash seen in the earlier build.
- Secret Service stores the API credential. The credential was validated
  against the API and used for an opt-in live Realtime transcription test. It
  never enters JSON settings, process arguments, diagnostics, source, or logs.
- The main Flow view and Voice Input view both enumerate and select microphones.
  The selected device persists and automatically falls back if it disappears.
- CPAL captures low-latency mono audio, resamples it to 16 kHz PCM, publishes
  levels, measures ambient and peak RMS, applies bounded gain, and produces WAV
  for batch fallback.
- Realtime transcription uses the transcription WebSocket intent, sends 24 kHz
  PCM, collects partial/final events, preserves structured server errors, and
  falls back to batch transcription after setup, transport, or finalization
  failure.
- The pipeline retains every successful transcript before polish or delivery.
  Failed polish uses deterministic cleanup; failed delivery keeps copy and
  retry actions available.
- X11 supports passive global grabs and XTest paste. Hyprland supports the XDG
  Global Shortcuts portal, modifier-only Ctrl+Win in either key order, target
  restoration, and compositor-assisted clipboard paste. Other Wayland
  compositors retain tray controls and explicit failure recovery.
- The waveform-only HUD fits in a transparent 104×46 window and shows microphone
  level or processing motion without accepting pointer input. If the compositor
  temporarily activates it, the daemon restores the window captured before the
  HUD appeared.
- The user-local installer creates an AppImage installation, desktop entry,
  icon, `freeflow` command, and enabled XDG autostart entry without root access.

## How to Run It

The current user installation is ready:

```bash
freeflow
```

FreeFlow also appears as `FreeFlow` in desktop launchers. Hold `Ctrl+Win`, speak,
and release either key. To rebuild and reinstall:

```bash
make linux-package
make linux-install
freeflow
```

Development mode:

```bash
./scripts/bootstrap-linux.sh
make linux-dev
```

## Commands Executed

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
npm test --prefix desktop -- --run
npm run typecheck --prefix desktop
npm run build --prefix desktop
make linux-test
make linux-package
make linux-install
desktop-file-validate ~/.local/share/applications/com.freeflow.FreeFlow.Linux.desktop
desktop-file-validate ~/.config/autostart/com.freeflow.FreeFlow.Linux.desktop
```

The live API test used the opt-in `FREEFLOW_TEST_OPENAI` and
`FREEFLOW_TEST_OPENAI_PCM` gates. No test prints the credential or transcript.

## Tests Passing

- 61 Rust tests pass across core, OpenAI, settings, Linux platform, and RPC
  crates. One hardware/desktop interaction test remains ignored by default.
- Clippy passes across every Rust workspace target with warnings denied.
- Rust formatting passes for the complete workspace.
- Seven Electron main-process and utility tests pass, including daemon callback
  isolation, destroyed-window lifecycle guards, and autostart command handling.
- TypeScript checking and the production Electron renderer/main/preload build
  pass.
- The isolated user-installer test passes for AppImage copying, safe symlinking,
  icon and desktop entries, dmenu discovery, quoting, and hidden autostart.
- Deterministic OpenAI tests cover realtime partial/final delivery, preserved
  server errors, disconnect and batch fallback, authentication rejection,
  no-speech responses, cancellation, polish, rate limits, delays, and malformed
  responses.

The preserved Swift suite requires macOS and cannot run on this Arch Linux host.

## Manual Tests Performed

- Stored and read the API key through Secret Service, then received HTTP 200
  from the configured OpenAI-compatible service without logging the key.
- Ran the live Realtime provider test with prerecorded PCM and received a final
  transcript.
- Started the installed AppImage, verified its daemon connection, inspected the
  portal bindings, and confirmed all four Hyprland modifier-only bindings target
  the current FreeFlow process.
- Drove a physical-style Ctrl+Win chord through `/dev/uinput`, held it while a
  deterministic virtual microphone streamed PCM, and released it to finalize.
  The live cloud transcript was automatically pasted into an isolated
  native-Wayland Chromium textarea.
- Confirmed the target remained recoverable after the HUD temporarily became
  Hyprland's active surface, then verified captured-window restoration fixed the
  delivery race.
- Verified direct clipboard paste in native-Wayland Chrome and terminal-aware
  shortcut selection in unit tests.
- Selected the Razer Kiyo by stable PulseAudio ID, persisted it to the private
  settings file, and captured real RMS data. After startup warm-up, preview
  became ready in roughly 200 ms and a 400 ms preview retained 440 ms of audio.
- Validated the 100×42 waveform-only HUD visually during live capture.
- Held and released Ctrl+Win without speaking and confirmed FreeFlow returned to
  idle without an error overlay.
- Validated the installed desktop and autostart entries and confirmed
  `~/.local/bin/freeflow` resolves to the installed AppImage.

## Packaging Output

- `desktop/dist/FreeFlow-Linux-0.2.0-x86_64.AppImage` — 132 MB,
  SHA-256 `d2a12c773b37d283c6f4e570b4110c85cb2e9a804855994453d4511d735e0d65`
- `desktop/dist/FreeFlow-Linux-0.2.0-amd64.deb` — 102 MB,
  SHA-256 `b22785b281faf96e1a9cd28d308d14317946035f1782dda792186b73156d4f8b`
- `rust/target/release/freeflow-daemon`, bundled into both artifacts
- `~/.local/share/freeflow/FreeFlow.AppImage`, installed for the current user
- `~/.local/share/applications/com.freeflow.FreeFlow.Linux.desktop`
- `~/.config/autostart/com.freeflow.FreeFlow.Linux.desktop`

Build outputs remain ignored and are not committed.

## Known Limitations

- Hyprland is the only Wayland compositor manually verified end to end. GNOME,
  KDE, and wlroots compositors vary in portal and virtual-keyboard support.
- Protected/password fields and applications that deliberately reject synthetic
  paste cannot be guaranteed. FreeFlow keeps the transcript in the clipboard
  and exposes retry/copy recovery for those cases.
- Direct AT-SPI insertion and paste-consumption-aware clipboard restoration are
  not implemented.
- X11 implementation tests pass, but the full VS Code, Firefox, terminal,
  GTK, and Qt manual matrix was not repeated in this session.
- The deterministic GUI smoke path is manual; standard CI does not create a
  portal session, `/dev/uinput` device, or paid OpenAI request.
- Packages are unsigned and automatic update delivery is not enabled.

## Wayland Status

Hyprland has a working vertical slice. FreeFlow finds the portal session action
owned by its process, expands Ctrl+Win into bindings that work regardless of
which modifier is pressed first, receives separate activation/deactivation
events, captures the original window before showing the HUD, and restores that
window before paste. Clipboard readiness is confirmed before synthetic input.

On other compositors, portal registration is attempted first and `wtype` is used
when the virtual-keyboard protocol is available. The tray and Flow button remain
usable when either capability is denied, and the UI reports the limitation.

## Security Review

- RPC binds only to `127.0.0.1:0`, generates a random token each launch, accepts
  one desktop client, and never exposes the token to the renderer.
- Electron uses context isolation, renderer sandboxing, no Node.js integration,
  an allow-listed preload bridge, and denied child windows.
- API credentials use Secret Service when available and memory-only storage
  otherwise. FreeFlow does not silently persist plaintext credentials.
- Configuration directories use mode 0700 and settings files use mode 0600.
- Logs and diagnostics exclude credentials, authorization headers, raw audio,
  full transcripts, clipboard contents, and focused application text.
- Audio, transcript, notification, retry, timeout, daemon restart, and RPC
  queues are bounded. Successful text is never discarded after delivery failure.
- The application sends audio and optional polish requests directly to the
  configured OpenAI-compatible endpoint. It adds no intermediary or telemetry.

## Files and Architecture Added

- `rust/crates/freeflow-core` contains the platform-independent state machine,
  audio algorithms, cleanup, recovery, configuration, events, and traits.
- `rust/crates/freeflow-openai` implements realtime, batch, and polish clients.
- `rust/crates/freeflow-platform-linux` implements CPAL capture, X11, portals,
  Hyprland context, clipboard delivery, and Secret Service.
- `rust/crates/freeflow-rpc` owns the authenticated transport and canonical
  contract used to generate TypeScript declarations.
- `rust/crates/freeflow-daemon` assembles and supervises the Linux services.
- `desktop` contains Electron main, preload, renderer, tray, settings,
  onboarding, compact HUD, daemon supervision, and package definitions.
- `scripts` contains Linux dependency checks, development, test, build,
  packaging, installation, and RPC generation commands.

## Existing macOS Behavior Affected

No source under `FreeFlowApp/` or `FreeFlowKit/` changed. Existing macOS build,
test, release, signing, and notarization commands remain intact. Linux commands
and CI are independent additions.

## Deferred Work

- Validate portals and automatic paste on GNOME and KDE.
- Add AT-SPI editable-field insertion and safe clipboard restoration.
- Automate the portal/uinput/virtual-microphone GUI smoke path without paid API
  calls.
- Add signed packages, update delivery, Flatpak, RPM, and Arch packaging.
- Add Windows platform implementations and offline Linux transcription models.

## Recommended Next Five Tasks

1. Run and record the full X11 and Hyprland application matrix across VS Code,
   Firefox, Chrome, common terminals, GTK, and Qt fields.
2. Turn the manual virtual-microphone test into an offline CI smoke test backed
   by the deterministic OpenAI service.
3. Validate and adapt the portal session on current GNOME and KDE releases.
4. Add AT-SPI direct insertion, then restore the prior clipboard only after
   confirmed consumption.
5. Add crash-restart and package-install smoke jobs for the AppImage and Debian
   artifacts on clean distribution images.
