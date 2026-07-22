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

## Two modes

You pick a mode when you set up Unramble, and switch between them anytime by
pressing ⌃⇧M (Control-Shift-M).

|                    | 🔒 Incognito          | ☁️ Cloud            |
|--------------------|-----------------------|---------------------|
| Your voice         | stays on your machine | goes to OpenAI      |
| API key            | none                  | your own            |
| Offline            | yes                   | no                  |
| Cost               | free                  | OpenAI's API rates  |

## Install

Install with [Homebrew](https://brew.sh) or
[download the DMG](https://github.com/mrinalwadhwa/unramble/releases/latest/download/Unramble.dmg).
Requires macOS 14 or later.

    brew install mrinalwadhwa/unramble/unramble

On first launch, Unramble walks you through setup: pick a mode, grant
Accessibility and Microphone permissions, and try a dictation.

- **🔒 Incognito** ships with everything it needs: no key, no configuration.
  Runs on Apple Silicon, English only.
- **☁️ Cloud** asks for your OpenAI API key and stores it in the macOS Keychain.
  Create one at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
  Runs on any Mac, and supports other languages.
