# FreeFlow on Linux

The Linux application is experimental. It provides a working cloud dictation
path on common desktop audio stacks, with the most complete shortcut and paste
behavior under X11. The native macOS application remains the supported release.

## System packages

FreeFlow needs a Rust toolchain, Node.js 22 or newer, a C/C++ build toolchain,
ALSA and PulseAudio development headers, X11/XTest headers, and Secret Service.
Wayland automation also uses the Global Shortcuts portal, `wtype`, and
`wl-clipboard`. PipeWire desktops normally expose compatible PulseAudio and ALSA
bridges.

Ubuntu or Debian:

```bash
sudo apt install build-essential pkg-config libasound2-dev libpulse-dev \
  libx11-dev libxtst-dev libsecret-1-dev nodejs npm \
  xdg-desktop-portal wtype wl-clipboard
```

Fedora:

```bash
sudo dnf install @development-tools pkgconf-pkg-config alsa-lib-devel \
  pulseaudio-libs-devel libX11-devel libXtst-devel libsecret-devel nodejs npm \
  xdg-desktop-portal wtype wl-clipboard
```

Arch Linux:

```bash
sudo pacman -S --needed base-devel pkgconf alsa-lib libpulse libx11 libxtst \
  libsecret nodejs npm xdg-desktop-portal wtype wl-clipboard
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
with the Start FreeFlow on login toggle. Login startup sets a dedicated launch
environment flag, so it does not steal focus by opening the settings window.

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

FreeFlow registers push-to-talk through the XDG Global Shortcuts portal. The
default `Ctrl+Win` modifier chord is verified on Hyprland, including either key
order, press/release events, native-Wayland microphone capture, and automatic
paste into the field that was focused when dictation started.

Hyprland delivery restores the captured target and uses the compositor's input
dispatcher. Other compositors use `wtype` when the virtual-keyboard protocol is
available. If the portal or virtual-keyboard protocol is unavailable, tray and
window start/stop controls remain available, the transcript stays in the
clipboard, and FreeFlow reports the limitation instead of silently failing.
GNOME and KDE portal behavior still needs broader distribution testing.

Electron can report a Wayland/Vulkan warning on some compositors. If the window
does not render, run with `ELECTRON_OZONE_PLATFORM_HINT=x11` to use XWayland;
this does not remove the Wayland shortcut and synthetic-input restrictions.

## Troubleshooting

Audio:

- Run `pactl list short sources` to verify that PipeWire or PulseAudio exposes
  the microphone.
- Choose the microphone directly on Flow or under Voice input, then run the
  level test. FreeFlow persists the stable device ID, pre-opens it during daemon
  startup, and pauses it while idle so later push-to-talk capture starts quickly.
- If an unplugged selected device fails, choose System default and retry.

Shortcut:

- Confirm `echo "$XDG_SESSION_TYPE"`. On Wayland, verify that
  `org.freedesktop.portal.GlobalShortcuts` is available and that the desktop's
  matching portal backend is running.
- Choose a different combination if registration says another application owns
  it.
- Window managers often reserve Win-key combinations. FreeFlow reports the
  conflict instead of swallowing another binding.

Text delivery:

- Under X11, confirm the XTest extension with `xdpyinfo -queryExtensions | grep XTEST`.
- Terminals use `Ctrl+Shift+V`; other detected targets use `Ctrl+V`.
- On Hyprland, install `wtype` and `wl-clipboard`; FreeFlow prefers Hyprland's
  dispatcher and retains `wtype` as a fallback. Other compositors must expose the
  virtual-keyboard protocol for automatic paste.
- Protected fields and applications that reject synthetic paste still require
  the explicit recovery action; the transcript remains on the clipboard.

Credentials:

- Unlock a Secret Service provider such as GNOME Keyring or KWallet.
- If none is running, use the session-only option. FreeFlow never silently writes
  a persistent plaintext key.

Logs and sanitized environment details are available from Diagnostics. Exports
exclude credentials, authorization headers, transcripts, audio, focused content,
and clipboard data.
