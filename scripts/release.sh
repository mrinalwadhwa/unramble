#!/usr/bin/env bash
#
# Ship the tested release candidate.
#
# Finds the latest v<version>-rc.* prerelease for the current Info.plist
# version and promotes its exact DMG to a v<version> release — no rebuild, no
# re-sign, no re-notarize (the ticket is already stapled). Regenerates the
# appcast for the final URL and updates the Homebrew cask.
#
# Errors if there is no candidate to release.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="mrinalwadhwa/unramble"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' UnrambleApp/Info.plist)"

CAND="$(gh release list --repo "$REPO" --limit 50 \
    --json tagName,isPrerelease \
    --jq "[.[] | select(.isPrerelease and (.tagName | startswith(\"v${VERSION}-rc.\")))] | first | .tagName // empty")"

if [ -z "$CAND" ]; then
    echo "!! no release candidate for v${VERSION} — run 'make release-candidate' first" >&2
    exit 1
fi

echo "── Promoting ${CAND} → v${VERSION} (same binary, no rebuild)"
tmp="$(mktemp -d)"
trap 'hdiutil detach "$tmp/mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"' EXIT

gh release download "$CAND" --repo "$REPO" --pattern 'Unramble.dmg' --dir "$tmp"

echo "── Verifying the candidate is notarized"
hdiutil attach "$tmp/Unramble.dmg" -nobrowse -quiet -mountpoint "$tmp/mnt"
spctl --assess --type execute --verbose=2 "$tmp/mnt/Unramble.app"
hdiutil detach "$tmp/mnt" -quiet

echo "── Regenerating the appcast for the v${VERSION} URL"
rm -rf releases
mkdir -p releases
cp "$tmp/Unramble.dmg" releases/
make appcast DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/"

echo "── Creating the v${VERSION} release"
gh release create "v${VERSION}" --repo "$REPO" \
    --title "Unramble ${VERSION}" \
    --generate-notes \
    releases/Unramble.dmg releases/appcast.xml

echo "── Retiring ${CAND}"
gh release delete "$CAND" --repo "$REPO" --yes --cleanup-tag || true

echo "── Updating the Homebrew cask"
scripts/bump-cask.sh "$VERSION"

echo "── Released v${VERSION}."
