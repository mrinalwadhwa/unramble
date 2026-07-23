#!/usr/bin/env bash
#
# Update the Homebrew cask after an Unramble release is published.
#
# Run from the unramble repo AFTER the GitHub release (and its Unramble.dmg)
# exist. Downloads the released DMG, computes its sha256, and pushes the new
# version + sha256 to the tap. Uses your own gh/git credentials, which must
# have write access to both repos.
#
# Usage: scripts/bump-cask.sh [version]   # defaults to the Info.plist version
set -euo pipefail

REPO="mrinalwadhwa/unramble"
TAP="mrinalwadhwa/homebrew-unramble"
CASK_PATH="Casks/unramble.rb"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' UnrambleApp/Info.plist)}"
TAG="v${VERSION}"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/Unramble.dmg"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "── Downloading ${DMG_URL}"
if ! curl -fsSL "$DMG_URL" -o "$tmp/Unramble.dmg"; then
    echo "!! No DMG at ${DMG_URL} — has the release finished building?" >&2
    exit 1
fi
SHA="$(shasum -a 256 "$tmp/Unramble.dmg" | cut -d' ' -f1)"
echo "   version=${VERSION}  sha256=${SHA}"

echo "── Updating ${TAP}/${CASK_PATH}"
gh repo clone "$TAP" "$tmp/tap" -- --depth 1 --quiet
cask="$tmp/tap/${CASK_PATH}"
sed -i '' -E "s/^([[:space:]]*version )\"[^\"]*\"/\1\"${VERSION}\"/" "$cask"
sed -i '' -E "s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"${SHA}\"/" "$cask"

if git -C "$tmp/tap" diff --quiet; then
    echo "   cask already current; nothing to push"
    exit 0
fi
git -C "$tmp/tap" commit -am "Update unramble to ${VERSION}"
git -C "$tmp/tap" push
echo "── Done: unramble ${VERSION} is live in the tap"
