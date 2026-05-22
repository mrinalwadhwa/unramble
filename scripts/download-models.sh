#!/bin/bash
# Download models listed in models.json into Resources/models/.
#
# Usage:
#   make models                                  # from repo root
#   ./scripts/download-models.sh                 # download missing models
#   ./scripts/download-models.sh --force         # re-download all
#   ./scripts/download-models.sh --verify        # verify hashes only
#
# Requires: python3, hf (huggingface-hub CLI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="$ROOT_DIR/FreeFlowApp/Resources/models"
MANIFEST="$ROOT_DIR/FreeFlowApp/models.json"

FORCE=false
VERIFY_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --verify) VERIFY_ONLY=true ;;
    esac
done

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: models.json not found at $MANIFEST"
    exit 1
fi

mkdir -p "$MODELS_DIR"

# Parse manifest with Python (json is in the standard library).
parse_manifest() {
    python3 -c "
import json, sys
with open('$MANIFEST') as f:
    data = json.load(f)
for name, info in data.get('models', {}).items():
    print(json.dumps({'name': name, **info}))
"
}

hash_dir() {
    local dir="$1"
    # Content-based hash: hash each file, then hash the sorted list.
    # Ignores timestamps and permissions so downloads are reproducible.
    find "$dir" -type f | sort | xargs shasum -a 256 | sed "s|$dir/||" | shasum -a 256 | cut -d' ' -f1
}

download_huggingface() {
    local name="$1"
    local repo="$2"
    local revision="$3"
    shift 3
    local include_patterns=("${@+"$@"}")
    local dest="$MODELS_DIR/$name"

    echo "  Downloading $repo (revision: ${revision:0:12}...)..."

    # Prefer `hf` (new CLI), fall back to `huggingface-cli` (deprecated).
    local hf_cmd=""
    if command -v hf &>/dev/null; then
        hf_cmd="hf"
    elif command -v huggingface-cli &>/dev/null; then
        hf_cmd="huggingface-cli"
    else
        echo "  ERROR: hf CLI not found. Install with: pip install huggingface-hub"
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local include_args=()
    for pattern in "${include_patterns[@]+"${include_patterns[@]}"}"; do
        include_args+=(--include "$pattern")
    done
    $hf_cmd download "$repo" \
        --revision "$revision" \
        --local-dir "$tmpdir/$name" \
        ${include_args[@]+"${include_args[@]}"}
    # Remove HuggingFace metadata.
    rm -rf "$tmpdir/$name/.huggingface"
    rm -rf "$tmpdir/$name/.cache"
    rm -f "$tmpdir/$name/.gitattributes"
    rm -f "$tmpdir/$name/README.md"
    rm -rf "$dest"
    mv "$tmpdir/$name" "$dest"
    rm -rf "$tmpdir"
}

ERRORS=0

while IFS= read -r line; do
    name=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
    source=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['source'])")
    expected_sha=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['sha256'])")

    dest="$MODELS_DIR/$name"

    if [ "$source" = "bundled" ]; then
        if [ -d "$dest" ]; then
            actual_sha=$(hash_dir "$dest")
            if [ "$actual_sha" = "$expected_sha" ]; then
                echo "✓ $name (bundled, hash ok)"
            else
                echo "✗ $name (bundled, hash mismatch)"
                echo "  expected: $expected_sha"
                echo "  actual:   $actual_sha"
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo "✗ $name (bundled, missing)"
            ERRORS=$((ERRORS + 1))
        fi
        continue
    fi

    if [ "$VERIFY_ONLY" = true ]; then
        if [ -d "$dest" ]; then
            actual_sha=$(hash_dir "$dest")
            if [ "$actual_sha" = "$expected_sha" ]; then
                echo "✓ $name (hash ok)"
            else
                echo "✗ $name (hash mismatch)"
                echo "  expected: $expected_sha"
                echo "  actual:   $actual_sha"
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo "✗ $name (missing)"
            ERRORS=$((ERRORS + 1))
        fi
        continue
    fi

    # Skip if already present and hash matches (unless --force).
    if [ "$FORCE" = false ] && [ -d "$dest" ]; then
        actual_sha=$(hash_dir "$dest")
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "✓ $name (already downloaded)"
            continue
        else
            echo "  $name hash mismatch, re-downloading..."
        fi
    fi

    if [ "$source" = "huggingface" ]; then
        repo=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['repo'])")
        revision=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('revision','main'))")
        # Parse include patterns (JSON array → space-separated args).
        includes=()
        while IFS= read -r pat; do
            [ -n "$pat" ] && includes+=("$pat")
        done < <(echo "$line" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for p in d.get('include', []):
    print(p)
")
        download_huggingface "$name" "$repo" "$revision" "${includes[@]+"${includes[@]}"}"
    else
        echo "  ERROR: unknown source '$source' for $name"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Verify hash after download.
    if [ -d "$dest" ]; then
        actual_sha=$(hash_dir "$dest")
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "✓ $name (downloaded, hash ok)"
        else
            echo "✗ $name (downloaded, hash mismatch)"
            echo "  expected: $expected_sha"
            echo "  actual:   $actual_sha"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "✗ $name (download failed)"
        ERRORS=$((ERRORS + 1))
    fi
done < <(parse_manifest)

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "FAILED: $ERRORS model(s) have errors"
    exit 1
fi

echo ""
echo "All models ready."
