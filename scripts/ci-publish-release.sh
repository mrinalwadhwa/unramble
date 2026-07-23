#!/usr/bin/env bash
#
# Publish a GitHub release for the given tag from the built DMG and appcast.
# A tag matching *-rc.* publishes as a prerelease. Requires GH_TOKEN in the
# environment. Run on a GitHub Actions runner after the DMG is built, signed,
# notarized, and the appcast generated.
set -euo pipefail

TAG="${1:?usage: ci-publish-release.sh <tag>}"

PRERELEASE_FLAG=""
if [[ "$TAG" == *-rc.* ]]; then
  PRERELEASE_FLAG="--prerelease"
fi

# shellcheck disable=SC2086  # PRERELEASE_FLAG is empty or a single flag
gh release create "$TAG" \
  --title "Unramble ${TAG#v}" \
  --generate-notes \
  $PRERELEASE_FLAG \
  releases/Unramble.dmg \
  releases/appcast.xml
