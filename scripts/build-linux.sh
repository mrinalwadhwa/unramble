#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cargo build --manifest-path "$ROOT/rust/Cargo.toml" --release -p freeflow-daemon
cd "$ROOT/desktop"
if [[ ! -d node_modules ]]; then
  npm ci
fi
npm run build
