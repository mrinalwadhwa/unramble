<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/hud-dark.gif">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/hud-light.gif">
    <img alt="Unramble dictation HUD — idle, then listening" src=".github/assets/hud-light.gif" width="100%">
  </picture>
</p>

# Unramble — dictate incognito

Press a hotkey, speak, and cleaned-up text lands at your cursor, in any app.

More and more, we get things done by instructing agents and speaking is the
most direct way to tell them exactly what you mean. But turning voice into
filler-free, polished text has so far needed models too big to run anywhere but
in the cloud. So every word you dictate, whether to an agent, an email, or a
terminal, first goes to someone else's servers.

That's changed. Small, open-weight models are now good enough, and fast.
Unramble runs them locally on your Mac: NVIDIA's 0.6B Nemotron transcribes your
speech, and a fine-tuned 0.6B Qwen3 cleans it up. Your voice never leaves your
machine.

<!-- Demo: recorded walkthrough — to be added -->

## How it works

Unramble runs in two modes. Incognito, the default mode, does everything on
your machine. It needs no API key, works offline, and costs nothing, but it
runs only on Apple Silicon and only supports English. Cloud mode sends your
audio to OpenAI instead. It works on any Mac and supports more languages, but
it needs an internet connection and your own OpenAI API key, and you pay
OpenAI's usage rates.

Press `Ctrl + Shift + M` to switch between modes at any time.

## Install

Install with [Homebrew](https://brew.sh) or
[download the DMG](https://github.com/mrinalwadhwa/unramble/releases/latest/download/Unramble.dmg).
Requires macOS 14 or later.

    brew install mrinalwadhwa/unramble/unramble

On first launch, Unramble walks you through setup: pick a mode, give it
permission to hear you and type into any app, and try a dictation. If you pick
Cloud, Unramble will ask you for your OpenAI API key and store it in your macOS
Keychain. You'll need to [get one](https://platform.openai.com/api-keys) from
OpenAI first.
