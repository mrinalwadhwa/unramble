# FreeFlow on Linux

The Linux application is experimental. It provides a working cloud dictation
path on common desktop audio stacks, with the most complete shortcut and paste
behavior under X11. The native macOS application remains the supported release.

## System packages

FreeFlow needs a Rust toolchain, Node.js 22 or newer, a C/C++ build toolchain,
ALSA and PulseAudio development headers, X11/XTest headers, and Secret Service.
PipeWire desktops normally expose compatible PulseAudio and ALSA bridges.

Ubuntu or Debian:

```bash
sudo apt install build-essential pkg-config libasound2-dev libpulse-dev \
  libx11-dev libxtst-dev libsecret-1-dev nodejs npm
```

Fedora:

```bash
sudo dnf install @development-tools pkgconf-pkg-config alsa-lib-devel \
  pulseaudio-libs-devel libX11-devel libXtst-devel libsecret-devel nodejs npm
```

Arch Linux:

```bash
sudo pacman -S --needed base-devel pkgconf alsa-lib libpulse libx11 libxtst \
  libsecret nodejs npm
```

Install Rust through [rustup](https://rustup.rs/). The dependency checker only
reports missing components and never changes the system:

```bash
./scripts/bootstrap-linux.sh
```

## Develop and build

```bash
make linux-dev       # build the daemon and launch Electron
make linux-test      # Rust format, Clippy, Rust tests, TypeScript, UI tests
make linux-build     # release daemon and production desktop bundle
make linux-package   # AppImage and Debian package
make linux-install   # install the AppImage for the current user
```

Release artifacts appear under `desktop/dist/`:

```bash
./desktop/dist/FreeFlow-Linux-0.2.0-x86_64.AppImage
sudo apt install ./desktop/dist/FreeFlow-Linux-0.2.0-amd64.deb
```

For an AppImage installation that desktop launchers and command launchers can
discover, run:

```bash
make linux-package
make linux-install
freeflow
```

The installer copies the AppImage to
`${XDG_DATA_HOME:-~/.local/share}/freeflow/FreeFlow.AppImage`, installs a
`FreeFlow` application entry and icon, and links `freeflow` into
`${XDG_BIN_HOME:-~/.local/bin}`. Rofi `drun` and desktop application menus read
the application entry; `dmenu_run` finds the command when that bin directory is
on `PATH`. The installer never uses root privileges or replaces an unrelated
file or symlink at that command path.

FreeFlow starts in the tray on login by default. The installer creates the XDG
autostart entry immediately, and the packaged application keeps it synchronized
with the Start FreeFlow on login toggle. Login startup passes `--hidden`, so it
does not steal focus by opening the settings window.

The AppImage supports `--appimage-extract-and-run` on systems where FUSE is not
available. Package builds embed the release daemon under Electron resources and
do not depend on a separately installed FreeFlow service.

The headless microphone path requires `OPENAI_API_KEY` and stops on Enter:

```bash
OPENAI_API_KEY='…' cargo run --manifest-path rust/Cargo.toml \
  -p freeflow-daemon -- record
```

Ordinary settings live at `${XDG_CONFIG_HOME:-~/.config}/freeflow/config.json`.
Persistent API keys use the desktop Secret Service and never enter that file.
If Secret Service is unavailable, the UI offers a clearly labeled session-only
credential that disappears on quit.

## X11

Push-to-talk shortcuts use passive X11 key grabs. The default is the
modifier-only chord `Ctrl+Win` (`Ctrl+Super` in X11 terminology). Either key can
be pressed first. Focus a field, hold both keys, speak, and release either key.
FreeFlow retains the successful transcript before it attempts clipboard paste.

If another application owns the combination, choose another key in Delivery.
The shortcut editor also supports modifier-plus-key combinations.

## Wayland

Wayland deliberately restricts global key observation and synthetic keyboard
input. FreeFlow detects the session and does not pretend an XWayland key grab can
control native applications. Use Start/Stop in the tray or Flow window. The
transcript stays in the clipboard and the HUD tells you when to paste manually.

A compositor portal global-shortcut implementation remains incomplete. Results
therefore vary by GNOME, KDE, Hyprland, and other compositors.

Electron can report a Wayland/Vulkan warning on some compositors. If the window
does not render, run with `ELECTRON_OZONE_PLATFORM_HINT=x11` to use XWayland;
this does not remove the Wayland shortcut and synthetic-input restrictions.

## Troubleshooting

Audio:

- Run `pactl list short sources` to verify that PipeWire or PulseAudio exposes
  the microphone.
- Open Voice input and run the level test. FreeFlow reports the selected backend,
  native device error, format, and fallback rather than a generic denial.
- If an unplugged selected device fails, choose System default and retry.

Shortcut:

- Confirm `echo "$XDG_SESSION_TYPE"`. Automatic global shortcuts currently need
  `x11`.
- Choose a different combination if registration says another application owns
  it.
- Window managers often reserve Win-key combinations. FreeFlow reports the
  conflict instead of swallowing another binding.

Text delivery:

- Under X11, confirm the XTest extension with `xdpyinfo -queryExtensions | grep XTEST`.
- Terminals use `Ctrl+Shift+V`; other detected targets use `Ctrl+V`.
- Under Wayland, use the explicit Copy/Paste recovery action when automatic input
  is prohibited.

Credentials:

- Unlock a Secret Service provider such as GNOME Keyring or KWallet.
- If none is running, use the session-only option. FreeFlow never silently writes
  a persistent plaintext key.

Logs and sanitized environment details are available from Diagnostics. Exports
exclude credentials, authorization headers, transcripts, audio, focused content,
and clipboard data.
