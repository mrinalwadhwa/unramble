#!/bin/bash
set -euo pipefail

# Release Unramble: app or service image.
#
# Usage:
#   ./scripts/release.sh app                    # release macOS app (current Info.plist version)
#   ./scripts/release.sh app --version 0.2.0    # set version in Info.plist, then release
#   ./scripts/release.sh app --tag v0.1.0-rc.1  # override tag (default: v{version})
#   ./scripts/release.sh image                  # build and push service image to ECR
#
# Expects:
#   - Working directory is the unramble repo root
#   - gh CLI is authenticated
#   - No uncommitted changes
#
# For app releases:
#   - ../homebrew is the homebrew-unramble repo checkout
#   - The release environment on GitHub has required secrets configured

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

usage() {
  echo "Usage: ./scripts/release.sh <command> [options]"
  echo ""
  echo "Commands:"
  echo "  app                Release the macOS app to GitHub Releases"
  echo "  image              Build and push the service image to ECR"
  echo ""
  echo "App options:"
  echo "  --version VERSION  Set version in Info.plist before releasing"
  echo "  --tag TAG          Override the git tag (default: v{version})"
  echo ""
  echo "Examples:"
  echo "  ./scripts/release.sh app"
  echo "  ./scripts/release.sh app --version 0.2.0"
  echo "  ./scripts/release.sh app --tag v0.1.0-rc.1"
  echo "  ./scripts/release.sh image"
}

# ── Preflight (common) ────────────────────────────────────────────

preflight_common() {
  if [ -n "$(git status --porcelain)" ]; then
    echo "Error: uncommitted changes" >&2
    exit 1
  fi

  if ! command -v gh &>/dev/null; then
    echo "Error: gh CLI not found" >&2
    exit 1
  fi
}

# ── App release ───────────────────────────────────────────────────

release_app() {
  local HOMEBREW_ROOT="$REPO_ROOT/../homebrew"
  local CASK_FILE="$HOMEBREW_ROOT/Casks/unramble.rb"
  local PLIST="$REPO_ROOT/UnrambleApp/Info.plist"
  local NEW_VERSION=""
  local TAG_OVERRIDE=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        if [ $# -lt 2 ]; then
          echo "Error: --version requires a version argument" >&2
          exit 1
        fi
        NEW_VERSION="$2"
        shift 2
        ;;
      --tag)
        if [ $# -lt 2 ]; then
          echo "Error: --tag requires a tag argument" >&2
          exit 1
        fi
        TAG_OVERRIDE="$2"
        shift 2
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  preflight_common

  if [ ! -f "$CASK_FILE" ]; then
    echo "Error: $CASK_FILE not found" >&2
    echo "Expected homebrew-unramble checkout at ../homebrew" >&2
    exit 1
  fi

  if [ -n "$(cd "$HOMEBREW_ROOT" && git status --porcelain)" ]; then
    echo "Error: uncommitted changes in homebrew repo" >&2
    exit 1
  fi

  # Set version if requested
  if [ -n "$NEW_VERSION" ]; then
    echo "── Setting version to ${NEW_VERSION} ──"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "$PLIST"
    git add "$PLIST"
    git commit -m "Set version to ${NEW_VERSION}"
    git push
    echo ""
  fi

  local VERSION
  VERSION=$(make version)
  local TAG="${TAG_OVERRIDE:-v${VERSION}}"

  echo "Releasing Unramble ${VERSION} (tag: ${TAG})"
  echo ""

  if git rev-parse "$TAG" &>/dev/null; then
    echo "Error: tag ${TAG} already exists" >&2
    exit 1
  fi

  # Tag and push
  echo "── Tagging ${TAG} ──"
  git tag -m "Unramble ${TAG}" "$TAG"
  git push origin "$TAG"

  echo ""
  echo "── Waiting for CI ──"
  echo "The release environment requires your approval."
  echo "Approve at: https://github.com/mrinalwadhwa/unramble/actions"
  echo ""

  sleep 5
  local RUN_ID
  RUN_ID=$(gh run list --branch "$TAG" --limit 1 --json databaseId --jq '.[0].databaseId')
  if [ -z "$RUN_ID" ]; then
    echo "Error: no workflow run found for tag ${TAG}" >&2
    exit 1
  fi

  echo "Run: https://github.com/mrinalwadhwa/unramble/actions/runs/${RUN_ID}"
  echo ""

  gh run watch "$RUN_ID" --exit-status
  echo ""

  # Download DMG and compute SHA256
  echo "── Downloading DMG ──"
  local DMG_DIR
  DMG_DIR=$(mktemp -d)
  local DMG_PATH="$DMG_DIR/Unramble.dmg"
  gh release download "$TAG" --pattern "Unramble.dmg" --output "$DMG_PATH"

  local SHA256
  SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
  rm -rf "$DMG_DIR"

  echo "  SHA256: ${SHA256}"
  echo ""

  # Update Homebrew Cask
  echo "── Updating Homebrew Cask ──"
  cd "$HOMEBREW_ROOT"

  sed -i '' "s/version \".*\"/version \"${TAG#v}\"/" Casks/unramble.rb
  sed -i '' "s/sha256 \".*\"/sha256 \"${SHA256}\"/" Casks/unramble.rb

  echo "  Updated Casks/unramble.rb:"
  head -3 Casks/unramble.rb | sed 's/^/    /'
  echo ""

  git add Casks/unramble.rb
  git commit -m "Update Unramble to ${TAG#v}"
  git push

  echo ""
  echo "══════════════════════════════════════════════════"
  echo "  Release complete!"
  echo "  Tag:      ${TAG}"
  echo "  Release:  https://github.com/mrinalwadhwa/unramble/releases/tag/${TAG}"
  echo "  Install:  brew install mrinalwadhwa/unramble/unramble"
  echo "══════════════════════════════════════════════════"
}

# ── Image release ─────────────────────────────────────────────────

release_image() {
  preflight_common

  echo "── Triggering image build ──"
  gh workflow run release-image.yml

  sleep 5
  local RUN_ID
  RUN_ID=$(gh run list --workflow=release-image.yml --limit 1 --json databaseId --jq '.[0].databaseId')
  if [ -z "$RUN_ID" ]; then
    echo "Error: no workflow run found" >&2
    exit 1
  fi

  echo "Run: https://github.com/mrinalwadhwa/unramble/actions/runs/${RUN_ID}"
  echo ""

  gh run watch "$RUN_ID" --exit-status

  echo ""
  echo "══════════════════════════════════════════════════"
  echo "  Image release complete!"
  echo "══════════════════════════════════════════════════"
}

# ── Main ──────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  app)   release_app "$@" ;;
  image) release_image "$@" ;;
  -h|--help) usage ;;
  *)
    echo "Error: unknown command: $COMMAND" >&2
    echo ""
    usage
    exit 1
    ;;
esac
