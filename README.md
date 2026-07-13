# FreeFlow – seamless speech to text in any app

Press a hotkey, dictate naturally, polished text appears in any app.

Ramble, use filler words, correct yourself mid-sentence. FreeFlow turns messy
speech into clean writing and injects it wherever your cursor is: your messaging app,
your editor, your coding agent, the terminal, email, anything.

It is open source, so you have the [freedom to customize](DEVELOP.md#customize) it any way you
want. It runs entirely on your Mac and talks directly to OpenAI with your own API key,
so your audio and transcripts never pass through anyone else's servers.

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
speak. The model transcribes incrementally, so much of the work is complete by
the time you release the key. The current Realtime-response polish path still
needs a fresh published latency and warm-connection run; the historical
baseline is recorded in [BENCHMARK.md](BENCHMARK.md).

A warm backup connection is kept pre-opened in the background so later
dictations can skip the WebSocket handshake.

The same Realtime connection transcribes the audio and returns the polished
response. If that streaming path fails, FreeFlow can recover through batch
transcription and chat polish for the full recording or its uncommitted tail.

See [BENCHMARK.md](BENCHMARK.md) for detailed timing breakdowns.

## Private

Local mode uses Nemotron speech recognition and a fine-tuned Qwen polisher on
Apple Silicon. Audio and transcripts stay on this Mac, and local mode needs no
API key or network connection. In cloud mode, audio and transcripts flow
directly to OpenAI with your own API key; there is no FreeFlow server in the
middle.

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
