# FreeFlow – seamless speech to text in any app

Press a hotkey, dictate naturally, polished text appears in any app.

Ramble, use filler words, correct yourself mid-sentence. FreeFlow turns messy
speech into clean writing and injects it wherever your cursor is: your messaging app,
your editor, your coding agent, the terminal, email, anything.

It is open source, so you have the [freedom to customize](DEVELOP.md#customize) it any way you
want. It runs entirely on your Mac and talks directly to OpenAI with your own API key,
so your audio and transcripts never pass through anyone else's servers.

## Experimental Linux build

FreeFlow now has a separate experimental Linux application beside the native
macOS source. It combines a Rust dictation daemon with an Electron tray, settings
window, and recording HUD. X11 supports global push-to-talk and clipboard paste.
Wayland uses the Global Shortcuts portal and compositor-assisted paste when
available, with a visible clipboard recovery action when a compositor blocks
automation.

```bash
./scripts/bootstrap-linux.sh
make linux-package
make linux-install
freeflow
```

The user-local install appears as FreeFlow in application launchers and as the
`freeflow` command in dmenu-style command launchers. It starts in the tray when
you sign in and uses `Ctrl+Win` as the default hold-to-talk shortcut. Hyprland
supports the complete hold-to-talk and automatic-insertion path.

See [docs/LINUX.md](docs/LINUX.md) for distribution packages, build commands,
credential-store requirements, Wayland restrictions, and troubleshooting. The
Linux build is not yet a production release and does not replace the macOS app.

## Demo (sound on 🔊)

In this demo, you'll hear rambling speech with filler words and corrections. Watch what appears at the cursor.

https://github.com/user-attachments/assets/da62c769-d56b-4c16-be04-148197536dfa

## Install

Requires **macOS 14** or later. Install with [Homebrew](https://brew.sh) or [download the DMG](https://github.com/mrinalwadhwa/freeflow/releases/latest/download/FreeFlow.dmg) directly.

```
brew install mrinalwadhwa/freeflow/freeflow
```

On first launch, FreeFlow asks for your OpenAI API key and stores it in the macOS
Keychain. Create one at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
After that, grant accessibility and microphone permissions and you are ready to dictate.

## Fast

Audio streams to OpenAI's Realtime API over a persistent WebSocket while you
speak. The model transcribes incrementally, so by the time you release the key
the transcript is already done. Median latency from key release to polished text
at cursor is **0.55 seconds**.

A warm backup connection is kept pre-opened in the background. After your first
dictation, subsequent ones skip the WebSocket handshake entirely — 91% of
sessions see zero connection setup time.

83% of dictations skip the LLM polish step entirely thanks to a local heuristic
that detects clean transcripts. When polish is needed, `gpt-4.1-nano` handles it
in 320–780 ms. If the streaming path fails, a batch fallback runs in parallel
and catches it automatically.

See [BENCHMARK.md](BENCHMARK.md) for detailed timing breakdowns.

## Private

Everything runs on your Mac. Your audio and transcripts flow directly to OpenAI
with your own API key; there is no FreeFlow server in the middle. On macOS 26,
FreeFlow can also transcribe entirely on-device using Apple's SpeechAnalyzer
framework — no network, no API key needed, audio never leaves the Mac.

## Open

Everything is in this repo: the app, the providers, the polish pipeline, the
prompts. Change the models, rewrite the prompts, add a language, or fork the
whole thing. See [DEVELOP.md](DEVELOP.md#customize).

## Contribute

Jump in, we'd love your help.

The single most useful contribution right now is
[mic compatibility data](https://github.com/mrinalwadhwa/freeflow/issues/2).
FreeFlow works well with built-in mics and AirPods, but every USB mic,
headset, and audio interface is different. The app's "Contribute Mic
Data" menu item generates a one-click diagnostic report that
can help us improve accuracy of dictation for everyone.

Want to add or improve support for a language? [Here's how.](https://github.com/mrinalwadhwa/freeflow/issues/1) Found an app where injection breaks? Open an issue. Code contributions and pull requests are welcome too. [DEVELOP.md](DEVELOP.md) has the build and test guide.
