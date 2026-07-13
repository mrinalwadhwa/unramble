# FreeFlow Architecture

FreeFlow keeps the native macOS application and the experimental Linux
application as independent front ends over behavior that follows the same
dictation rules.

## Processes and security boundary

The Linux build runs two local processes:

```text
Electron tray, settings, HUD
        │
        │ authenticated JSON-RPC 2.0 WebSocket
        │ 127.0.0.1:ephemeral-port
        ▼
Rust daemon
  ├── recording pipeline
  ├── OpenAI-compatible clients
  ├── CPAL microphone capture
  ├── X11 or Wayland integration
  └── Secret Service and XDG settings
```

The daemon binds only to `127.0.0.1:0`. It prints one machine-readable ready
record containing the selected port and a random per-launch token. The Electron
main process reads that record and authenticates the WebSocket. The token never
enters the renderer, and the daemon admits only one desktop connection.

The preload exposes a narrow typed bridge with RPC invocation and notification
subscription. Context isolation and the renderer sandbox remain enabled.

## Rust crates

- `freeflow-core` defines the state machine, configuration, application events,
  audio algorithms, transcript cleanup, recovery buffer, and platform traits.
  It imports no Linux desktop or audio APIs.
- `freeflow-openai` sends realtime PCM, complete WAV recordings, and optional
  polish requests directly to an OpenAI-compatible service.
- `freeflow-platform` persists validated ordinary settings atomically with
  private Unix permissions.
- `freeflow-platform-linux` captures audio and implements X11 context, shortcut,
  clipboard, synthetic paste, session detection, and Secret Service access.
- `freeflow-rpc` owns the authenticated transport and the canonical method and
  notification contract. It generates the TypeScript transport declarations.
- `freeflow-daemon` assembles the providers, supervises resources, handles RPC,
  and exposes a small headless recording command.
- `freeflow-mock-openai` serves scripted deterministic API behavior for tests.

## Recording state

```text
Idle → Preparing → Recording → Finalizing → Transcribing
                                      └────→ Polishing → Injecting → Idle
                                                            └────→ InjectionFailed
Any active state ──cancel──→ Idle
Network or device error ───→ Failed ──retry/new recording──→ …
```

The pipeline rejects duplicate starts and ignores release outside recording.
It stores every successful transcript before injection. A failed paste therefore
leaves copy and retry-paste actions available.

## Audio and cloud flow

CPAL opens the selected input or falls back to the current default. The callback
downmixes to mono, measures RMS and ambient noise, resamples to 16 kHz, applies
bounded far-field gain, publishes HUD levels, and retains signed 16-bit PCM.

Realtime transcription resamples chunks to 24 kHz and commits the input buffer
when push-to-talk is released. If setup, streaming, or final collection fails,
the pipeline encodes the retained 16 kHz PCM as WAV and uses batch transcription.
Polish first applies deterministic punctuation, correction, filler, repetition,
and formatting transforms. It skips clean text and falls back to that local
result when the optional model call fails or returns destructive output.

## Linux delivery

On X11, passive grabs support both modifier-plus-key shortcuts and modifier
chords. The default chord grabs either order of `Ctrl+Win`, publishes one press
when the chord becomes active, and publishes release when either key is lifted.

On X11, FreeFlow records the active window before showing any HUD. Delivery then
places the transcript on the clipboard and sends `Ctrl+V`; known terminal targets
use `Ctrl+Shift+V`. The clipboard keeps the transcript because restoring it before
confirmed consumption risks data loss.

On Wayland, FreeFlow uses the clipboard and reports when the compositor requires
a manual paste. The HUD never accepts focus or pointer events. Direct AT-SPI
editing remains separate from the initial reliable fallback.
