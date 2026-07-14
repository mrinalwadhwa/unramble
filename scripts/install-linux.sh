#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $# -gt 1 ]]; then
  printf 'Usage: %s [FreeFlow.AppImage]\n' "$0" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  SOURCE=$1
else
  shopt -s nullglob
  artifacts=("$ROOT"/desktop/dist/FreeFlow-Linux-*.AppImage)
  shopt -u nullglob
  if [[ ${#artifacts[@]} -eq 0 ]]; then
    printf 'No FreeFlow AppImage found. Run make linux-package first.\n' >&2
    exit 1
  fi
  SOURCE=${artifacts[${#artifacts[@]} - 1]}
fi

if [[ ! -f "$SOURCE" ]]; then
  printf 'AppImage not found: %s\n' "$SOURCE" >&2
  exit 1
fi

ICON_SOURCE="$ROOT/desktop/build/icon.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'FreeFlow icon not found: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi

DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
BIN_HOME=${XDG_BIN_HOME:-"$HOME/.local/bin"}
INSTALL_DIRECTORY="$DATA_HOME/freeflow"
APPLICATION="$INSTALL_DIRECTORY/FreeFlow.AppImage"
COMMAND="$BIN_HOME/freeflow"
APPLICATIONS_DIRECTORY="$DATA_HOME/applications"
DESKTOP_ENTRY="$APPLICATIONS_DIRECTORY/com.freeflow.FreeFlow.Linux.desktop"
AUTOSTART_DIRECTORY="$CONFIG_HOME/autostart"
AUTOSTART_ENTRY="$AUTOSTART_DIRECTORY/com.freeflow.FreeFlow.Linux.desktop"
ICON="$DATA_HOME/icons/hicolor/1024x1024/apps/freeflow.png"

if [[ -e "$COMMAND" && ! -L "$COMMAND" ]]; then
  printf 'Refusing to replace the existing file: %s\n' "$COMMAND" >&2
  exit 1
fi
if [[ -L "$COMMAND" && $(readlink "$COMMAND") != "$APPLICATION" ]]; then
  printf 'Refusing to replace the existing symlink: %s\n' "$COMMAND" >&2
  exit 1
fi

desktop_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//\`/\\\`}
  value=${value//\$/\\\$}
  value=${value//%/%%}
  printf '"%s"' "$value"
}

mkdir -p "$INSTALL_DIRECTORY" "$BIN_HOME" "$APPLICATIONS_DIRECTORY" "$AUTOSTART_DIRECTORY"

application_temporary="$APPLICATION.tmp.$$"
desktop_temporary="$DESKTOP_ENTRY.tmp.$$"
autostart_temporary="$AUTOSTART_ENTRY.tmp.$$"
trap 'rm -f "$application_temporary" "$desktop_temporary" "$autostart_temporary"' EXIT

install -m 0755 "$SOURCE" "$application_temporary"
mv -f "$application_temporary" "$APPLICATION"
ln -sfn "$APPLICATION" "$COMMAND"
install -Dm 0644 "$ICON_SOURCE" "$ICON"

quoted_command=$(desktop_quote "$COMMAND")
{
  printf '%s\n' \
    '[Desktop Entry]' \
    'Type=Application' \
    'Name=FreeFlow' \
    'Comment=Push-to-talk dictation for Linux' \
    "Exec=$quoted_command" \
    'Icon=freeflow' \
    'Terminal=false' \
    'Categories=Utility;' \
    'Keywords=Dictation;Speech;Voice;' \
    'StartupNotify=false' \
    'StartupWMClass=FreeFlow'
} > "$desktop_temporary"
chmod 0644 "$desktop_temporary"
mv -f "$desktop_temporary" "$DESKTOP_ENTRY"

{
  printf '%s\n' \
    '[Desktop Entry]' \
    'Type=Application' \
    'Name=FreeFlow' \
    'Comment=Keep push-to-talk dictation ready' \
    "Exec=/usr/bin/env FREEFLOW_START_HIDDEN=1 $quoted_command" \
    'Icon=freeflow' \
    'Terminal=false' \
    'Categories=Utility;' \
    'StartupNotify=false' \
    'X-GNOME-Autostart-enabled=true'
} > "$autostart_temporary"
chmod 0644 "$autostart_temporary"
mv -f "$autostart_temporary" "$AUTOSTART_ENTRY"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPLICATIONS_DIRECTORY" >/dev/null 2>&1 || true
fi

printf 'Installed FreeFlow to %s\n' "$APPLICATION"
printf 'Launcher entry: %s\n' "$DESKTOP_ENTRY"
printf 'Startup entry: %s\n' "$AUTOSTART_ENTRY"
printf 'Command: %s\n' "$COMMAND"

case ":$PATH:" in
  *":$BIN_HOME:"*) ;;
  *) printf 'Add %s to PATH so dmenu_run can find the freeflow command.\n' "$BIN_HOME" >&2 ;;
esac
