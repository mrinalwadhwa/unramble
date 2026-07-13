# Linux Port Result

## Executive Summary

FreeFlow now has an experimental Linux application beside the unchanged native
macOS source. A Rust daemon owns audio capture, cloud dictation, polish, X11
shortcut and paste integration, Secret Service credentials, settings, recovery,
diagnostics, and authenticated localhost RPC. An Electron shell owns the tray,
onboarding, settings, recovery controls, and non-focusable recording HUD.

The implementation builds, passes its Linux test suite, captures a real
PipeWire/PulseAudio microphone, responds to a real X11 global key grab, launches
from its packaged AppImage, and produces AppImage and Debian artifacts. The
OpenAI wire paths pass against the deterministic local service. A paid live API
request and a complete automatic paste target matrix were not run in this
environment, so those remain the most important manual release checks.

## What Works End-to-End

- Electron launches the bundled or development daemon, reads its ephemeral
  loopback port and launch token, authenticates one WebSocket client, receives
  notifications, and shuts the daemon down with the application.
- The UI stores ordinary settings in the XDG configuration directory and stores
  persistent API credentials in Secret Service. It offers an explicit
  memory-only credential when Secret Service is unavailable.
- CPAL enumerates real PulseAudio and ALSA devices, selects or falls back to the
  default, captures PCM, publishes levels, and returns 16 kHz mono signed
  16-bit audio with calibrated RMS, bounded gain, and silence metadata.
- Realtime transcription streams 24 kHz PCM and collects partial and final
  text. Disconnects and empty realtime results use cancellable batch WAV
  transcription. The local service verifies both paths without paid requests.
- Deterministic cleanup and optional model polish preserve a safe fallback.
  Successful text enters the recovery buffer before injection.
- X11 registers `Ctrl+Alt+Space`, distinguishes press and release, and drives
  the recording lifecycle. XTest pastes the retained clipboard text with a
  terminal-aware shortcut. Wayland keeps the result on the clipboard and tells
  the user when manual paste is required.
- Tray and window actions start, stop, cancel, copy, and retry-paste dictation.
  The HUD displays recording level and processing state without accepting focus.

## How to Run It

Install the distribution packages from `docs/LINUX.md`, then run:

```bash
./scripts/bootstrap-linux.sh
make linux-dev
```

Build and launch a portable package:

```bash
make linux-package
./desktop/dist/FreeFlow-Linux-0.2.0-x86_64.AppImage
```

Run live microphone dictation from the terminal:

```bash
OPENAI_API_KEY='…' cargo run --manifest-path rust/Cargo.toml \
  -p freeflow-daemon -- record
```

## Commands Executed

```bash
./scripts/bootstrap-linux.sh
./scripts/generate-rpc-types.sh
./scripts/test-linux.sh
./scripts/package-linux.sh
cargo test --manifest-path rust/Cargo.toml -p freeflow-core \
  cancel_waits_for_microphone_startup_to_release_audio
npm run typecheck --prefix desktop
npm test --prefix desktop
npm run build --prefix desktop
npm run package --prefix desktop
make test
```

`make test` could not run the preserved macOS Swift suite because this Linux
host does not have the Swift toolchain (`swift: command not found`). No Swift
source or macOS build command changed.

## Tests Passing

- 45 Rust tests pass: 26 core, 3 OpenAI client, 6 OpenAI provider integration,
  3 platform settings, 3 Linux platform, and 4 RPC tests.
- Rust formatting passes for the workspace.
- Clippy passes for all workspace targets with warnings denied.
- TypeScript checking passes for the Electron main, preload, shared contract,
  and renderer projects.
- Two desktop renderer utility tests pass.
- The production Electron bundle builds after regenerating its RPC contract
  from the canonical Rust declaration.
- Deterministic service tests cover realtime partial/final delivery, realtime
  disconnect, batch fallback, cancellation, polish, authentication rejection,
  rate limits, delays, and malformed responses.

## Manual Tests Performed

- Launched the daemon under Wayland and connected with its random per-launch
  token over `127.0.0.1`.
- Called status, diagnostics, microphone enumeration, preview start, preview
  stop, and shutdown through RPC.
- Captured 1.024 seconds from a Razer Kiyo through the PipeWire PulseAudio
  bridge at 16 kHz, received level events, and measured RMS metadata.
- Launched the Electron development shell, inspected its onboarding and settings
  window, and verified the renderer, tray process, and daemon lifecycle.
- Launched the packaged AppImage directly and with extraction fallback. Its
  embedded daemon reported ready, and the controlled extraction run stopped it
  cleanly.
- Forced an X11 session over XWayland, registered `Ctrl+Alt+Space`, sent a real
  synthetic global press, observed `Preparing`, cancelled, released the keys,
  and verified the state returned to `Idle`.
- Repeated X11 cancellation with slow microphone startup and verified capture
  stopped before cancellation and daemon shutdown completed.

No live paid OpenAI request, automatic paste into the requested application
matrix, or native Wayland portal shortcut was manually tested.

## Packaging Output

- `desktop/dist/FreeFlow-Linux-0.2.0-x86_64.AppImage` — 131 MB,
  SHA-256 `220b301772bf69dde7fd8d9b08ecd40830b6f2a7682b87bbb33f9ddb8099ec9e`
- `desktop/dist/FreeFlow-Linux-0.2.0-amd64.deb` — 102 MB,
  SHA-256 `875489799de852330923e8576b927b69fe66c6744aa94c88f770db271c360623`
- `rust/target/release/freeflow-daemon` — bundled into both desktop artifacts

Build outputs remain ignored and are not committed.

## Known Limitations

- Modifier-only X11 shortcuts need an XInput2 listener; modifier-plus-key
  combinations work.
- Direct AT-SPI insertion and reliable clipboard restoration remain deferred.
  FreeFlow preserves the transcript instead of risking early clipboard restore.
- The X11 paste implementation needs manual coverage across VS Code, Chromium,
  Firefox, terminal emulators, and GTK/Qt fields before a production release.
- Realtime connections reconnect with bounded backoff but do not yet maintain a
  permanently warm spare session between dictations.
- The automated smoke suite verifies the cloud protocols but does not yet drive
  prerecorded PCM through Electron into a virtual text field.
- Packages are unsigned and automatic updates are not enabled.
- Start-on-login depends on Electron and the desktop environment and needs
  distribution-specific validation.

## Wayland Status

FreeFlow detects Wayland and exposes start, stop, cancel, copy, and retry-paste
actions in the tray and window. It writes the transcript to the clipboard,
retains it after delivery failure, and displays an explicit manual-paste message
instead of claiming synthetic input succeeded.

Desktop portal global-shortcut registration is not implemented. Automatic
global push-to-talk and unrestricted synthetic paste therefore remain
unavailable on native Wayland applications. XWayland rendering does not remove
those compositor restrictions.

## Security Review

- RPC binds only to `127.0.0.1:0`, uses a random token for every launch, admits
  one desktop connection, and never exposes its token to the renderer.
- Electron enables context isolation and renderer sandboxing, disables Node.js
  integration, denies new windows, and exposes only allow-listed RPC methods.
- API keys never enter JSON settings, process arguments, diagnostics, or normal
  logs. Secret Service stores persistent credentials; explicit session-only
  values remain in daemon memory.
- XDG configuration directories use mode 0700 and atomically written files use
  mode 0600. Diagnostic exports use a fixed data model and private permissions.
- Logs report categories, timing, sample counts, and character counts without
  raw audio, clipboard contents, authorization headers, or transcript text.
- Audio accumulation, RPC clients, notifications, retry loops, request times,
  and daemon restart attempts are bounded.

## Files and Architecture Added

- `rust/` contains the pure core, OpenAI client, shared platform persistence,
  Linux integrations, RPC contract/server, daemon, and deterministic service.
- `desktop/` contains Electron main/preload/renderer projects, the generated RPC
  contract, packaged icon, and AppImage/Debian definitions.
- `scripts/` contains dependency checking and Linux development, test, build,
  packaging, and RPC generation commands.
- `.github/workflows/cross-platform.yml` adds an independent Linux CI job.
- `docs/ARCHITECTURE.md`, `docs/LINUX.md`, and `docs/PORT_STATUS.md` describe the
  implementation, operating requirements, and honest subsystem status.

## Existing macOS Behavior Affected

No files under `FreeFlowApp/` or `FreeFlowKit/` changed. Existing macOS build,
test, release, signing, and notarization targets remain in place. The root
Makefile only adds independent `linux-*` targets.

## Deferred Work

- Wayland global shortcuts through the desktop portal.
- AT-SPI editable-field insertion and paste-consumption-aware clipboard restore.
- Deterministic virtual-display desktop injection smoke coverage.
- Offline models, Apple MLX runtimes on Linux, and Windows implementations.
- Signed packages, auto-update delivery, Flatpak, RPM, and Arch packages.

## Recommended Next Five Tasks

1. Run the full live X11 acceptance matrix with an opt-in API key and record
   per-application paste behavior for Electron, browser, terminal, GTK, and Qt.
2. Add an Xvfb test target that feeds deterministic PCM, focuses a small X11
   text field, triggers the shortcut, and asserts the pasted result.
3. Implement the Global Shortcuts portal with activation/deactivation events and
   keep the existing tray fallback for unsupported compositors.
4. Add AT-SPI insertion and clipboard-consumption detection before enabling
   clipboard restoration.
5. Validate Secret Service, start-on-login, AppImage, and Debian behavior on
   clean Ubuntu, Fedora, and Arch installations.
