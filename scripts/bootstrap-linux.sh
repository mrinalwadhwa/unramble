#!/usr/bin/env bash
set -euo pipefail

missing=0
for command in cargo node npm pkg-config; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'missing command: %s\n' "$command"
    missing=1
  fi
done

for library in alsa libpulse x11 xtst libsecret-1; do
  if ! pkg-config --exists "$library" 2>/dev/null; then
    printf 'missing development library: %s\n' "$library"
    missing=1
  fi
done

if ! command -v secret-tool >/dev/null 2>&1; then
  printf 'warning: secret-tool was not found; install libsecret tools to inspect Secret Service availability\n'
fi

if [[ $missing -ne 0 ]]; then
  printf '\nInstall the packages listed in docs/LINUX.md, then run this check again.\n'
  exit 1
fi

printf 'FreeFlow Linux build dependencies are available.\n'
