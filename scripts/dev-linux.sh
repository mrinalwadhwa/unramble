#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT/desktop"
if [[ ! -d node_modules ]]; then
  npm ci
fi
exec npm run dev
