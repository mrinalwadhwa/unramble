# Develop

Build, test, customize, and understand the FreeFlow codebase.

## Prerequisites

- macOS 14+
- Xcode 16+
- Python 3.10+ for explicit model downloads
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

    make models          # download the pinned local model pack
    make verify-models   # verify local assets without network access
    make build           # debug build (generates the project if missing)
    make test            # fast tests (~5s)
    make test-all        # Keychain + slow tests (~90s)
    make clean           # clean build output
    make xcode           # open in Xcode

`make models` is the only model command that uses the network. It creates its
own disposable Python environment, downloads immutable Hugging Face revisions,
and verifies the resulting pack. Build and archive commands only perform
offline verification. The built app never downloads or installs model assets
at runtime.

`FREEFLOW_TEST_KEYCHAIN=1` enables Keychain tests (require macOS login
Keychain access, trigger password prompts). `FREEFLOW_TEST_OPENAI=1`
enables live tests that hit the real OpenAI API and require
`OPENAI_API_KEY` to be set. `FREEFLOW_TEST_OPENAI_BENCH=1` additionally
enables the latency benchmark suite.

## Project structure

The repo has two main directories:

**`FreeFlowApp/`** — macOS app. Menu bar UI, onboarding, settings, HUD
overlay. Sources are in `Sources/`, bundled HTML and assets in
`Resources/`.

**`FreeFlowKit/`** — Swift package with the testable core. The
dictation pipeline, streaming and batch OpenAI providers, the polish
pipeline, audio capture, device switching, text injection, Keychain
storage, and the recording state machine. Protocols for every provider
enable dependency injection in tests.

The supported local pipeline is incremental and has one production speech
recognizer:

```mermaid
flowchart LR
    A[16 kHz microphone PCM] --> N[Nemotron Core ML session]
    N --> R[Running raw transcript]
    R --> Q[Fine-tuned Qwen polish via MLX]
    Q --> I[Rolling chunks and final tail injection]
```

## Customize

FreeFlow is designed to be taken apart and reassembled. Edit code,
rebuild, and use the rebuilt binary.

### Change a prompt

The polish prompts live in `FreeFlowKit/Sources/FreeFlowKit/Prompts/`.
`PolishPipeline.swift` selects and augments them for each backend:

| Constant | File | What it controls |
|----------|------|------------------|
| `systemPromptQwen` | `PolishPromptQwen.swift` | Supported local Qwen polish |
| `systemPromptEnglish` | `PolishPromptEnglish.swift` | Cloud English polish |
| `systemPromptCasual` | `PolishPromptCasual.swift` | Cloud casual-style English polish |
| `systemPromptHindi`, `systemPromptKannada`, `systemPromptTamil` | Matching language prompt files | Cloud polish for explicitly supported languages |
| `systemPromptMinimal` | `PolishPromptMinimal.swift` | Conservative cloud fallback for other languages |

Edit the prompt for the backend and language you want to change. For example,
to make the English cloud polish step produce British English:

    11. British English: use British spelling conventions. "organize" becomes
        "organise", "color" becomes "colour", "center" becomes "centre", etc.

Or to format code identifiers in backticks:

    11. Code identifiers: when the speaker mentions a function, variable,
        class name, or file path, wrap it in backticks. "the render function"
        becomes "the `render` function".

Add the rule to `PolishPromptEnglish.swift` before its final instructions about
language preservation and output format.

### Change a model

Cloud model identifiers are configured at the composition root or as provider
defaults:

| Constant | File | Default | What it does |
|----------|------|---------|-------------|
| `realtimeModel` | `AppDelegate.swift` | `gpt-realtime-2.1` | Production Realtime connection and response polish |
| `sttModel` | `OpenAIStreamingProvider.swift` | `gpt-4o-mini-transcribe` | Realtime transcription |
| `model` | `OpenAIBatchProvider.swift` | `gpt-4o-mini-transcribe` | Batch fallback transcription |
| `polishModel` | `PolishPipeline.swift` | `gpt-5.4-nano` | Batch/chat fallback cleanup |

The local Nemotron and Qwen repository revisions, selected files, and hashes
are pinned in `scripts/models.sh`. The fine-tuned adapter source is tracked at
`FreeFlowApp/ModelSources/qwen3-0.6b-4bit-polish-adapter`; rerun `make models`
after changing it so the generated pack receives the current adapter bytes.

### Rebuild

    make generate   # Regenerate Xcode project
    make build      # Build the app

The debug build is at
`~/Library/Developer/Xcode/DerivedData/FreeFlow-*/Build/Products/Debug/FreeFlow.app`.
Launch it directly or replace your installed app with the rebuilt one.

Everything else in `FreeFlowKit/Sources/FreeFlowKit/Services/` is open
to modification: audio capture, device switching, text injection, the
dictation pipeline state machine, even the Realtime protocol message
construction. The test suite covers every provider and pipeline stage so
regressions are caught quickly.

## App icon

The app icon is a 6-bar waveform squircle. The source SVG is
`FreeFlowApp/AppIcon.svg`.

### Regenerating

Requires `rsvg-convert` (install via `brew install librsvg` or Nix):

    rsvg-convert -w 1024 -h 1024 FreeFlowApp/AppIcon.svg -o /tmp/AppIcon-1024.png

    mkdir -p /tmp/AppIcon.iconset
    sips -z 16 16     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_16x16.png
    sips -z 32 32     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_16x16@2x.png
    sips -z 32 32     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_32x32.png
    sips -z 64 64     /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_32x32@2x.png
    sips -z 128 128   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_128x128.png
    sips -z 256 256   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_128x128@2x.png
    sips -z 256 256   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_256x256.png
    sips -z 512 512   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_256x256@2x.png
    sips -z 512 512   /tmp/AppIcon-1024.png --out /tmp/AppIcon.iconset/icon_512x512.png
    cp /tmp/AppIcon-1024.png /tmp/AppIcon.iconset/icon_512x512@2x.png

    iconutil -c icns /tmp/AppIcon.iconset -o FreeFlowApp/Resources/AppIcon.icns

The `.icns` file is referenced by `CFBundleIconFile` in
`FreeFlowApp/Info.plist`. After regenerating, run `xcodegen generate`
and rebuild.
