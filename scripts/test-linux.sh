#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cargo fmt --manifest-path "$ROOT/rust/Cargo.toml" --all -- --check
cargo clippy --manifest-path "$ROOT/rust/Cargo.toml" --workspace --all-targets -- -D warnings
cargo test --manifest-path "$ROOT/rust/Cargo.toml" --workspace
cd "$ROOT/desktop"
if [[ ! -d node_modules ]]; then
  npm ci
fi
npm run typecheck
npm test
"$ROOT/scripts/test-install-linux.sh"
