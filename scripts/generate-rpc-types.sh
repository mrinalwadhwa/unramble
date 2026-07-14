#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cargo run --quiet \
  --manifest-path "$ROOT/rust/Cargo.toml" \
  -p freeflow-daemon -- export-types \
  > "$ROOT/desktop/src/shared/rpc.generated.ts"
