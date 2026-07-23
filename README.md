<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/hud-dark.gif">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/hud-light.gif">
    <img alt="Unramble dictation HUD — idle, then listening" src=".github/assets/hud-light.gif" width="100%">
  </picture>
</p>

# Unramble — dictate incognito

Press a hotkey, speak, and cleaned-up text lands at your cursor, in any app.

More and more, we get things done by instructing agents. Speaking is the most
direct way to hand agents what you mean at full fidelity. But turning voice into
filler-free, polished text has so far needed models too big to run anywhere but
in the cloud. So every word you dictate, whether to an agent, an email, or a
terminal, first goes to someone else's servers.

That's changed. Small, open-weight models are now good enough, and fast.
Unramble runs them locally, so your voice never leaves your machine.

<!-- Demo: recorded walkthrough — to be added -->

Incognito is the default and does everything on your machine — no API key, no
connection, no cost — but it needs Apple Silicon and works only in English.
Cloud sends your audio to OpenAI instead: it needs your own API key, a
connection, and OpenAI's per-use rates, and in return runs on any Mac and in
other languages. Press `Ctrl + Shift + M` to switch anytime.

## Install

Install with [Homebrew](https://brew.sh) or
[download the DMG](https://github.com/mrinalwadhwa/unramble/releases/latest/download/Unramble.dmg).
Requires macOS 14 or later.

    brew install mrinalwadhwa/unramble/unramble

On first launch, Unramble walks you through setup: pick a mode, grant
Accessibility and Microphone permissions, and try a dictation. If you pick
Cloud, you'll add your OpenAI API key — create one at
[platform.openai.com/api-keys](https://platform.openai.com/api-keys) — and
Unramble keeps it in the macOS Keychain.
