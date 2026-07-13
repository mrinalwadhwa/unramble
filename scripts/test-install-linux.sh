#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

home="$temporary/home with space"
data="$home/.local/share"
config="$home/.config"
bin="$home/.local/bin"
source_directory="$temporary/source artifacts"
source="$source_directory/FreeFlow.AppImage"
mkdir -p "$source_directory"
printf '#!/usr/bin/env bash\nexit 0\n' > "$source"
chmod 0755 "$source"

HOME="$home" \
XDG_DATA_HOME="$data" \
XDG_CONFIG_HOME="$config" \
XDG_BIN_HOME="$bin" \
PATH="$bin:$PATH" \
  "$ROOT/scripts/install-linux.sh" "$source" >/dev/null

application="$data/freeflow/FreeFlow.AppImage"
command="$bin/freeflow"
desktop="$data/applications/com.freeflow.FreeFlow.Linux.desktop"
autostart="$config/autostart/com.freeflow.FreeFlow.Linux.desktop"

cmp "$source" "$application"
[[ -x "$application" ]]
[[ -L "$command" ]]
[[ $(readlink "$command") == "$application" ]]
grep -Fqx 'Name=FreeFlow' "$desktop"
grep -Fqx "Exec=\"$command\"" "$desktop"
grep -Fqx "Exec=\"$command\" --hidden" "$autostart"
grep -Fqx 'X-GNOME-Autostart-enabled=true' "$autostart"
[[ -f "$data/icons/hicolor/1024x1024/apps/freeflow.png" ]]

printf 'Linux user installer test passed.\n'
