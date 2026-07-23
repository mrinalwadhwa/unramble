#!/usr/bin/env bash
#
# Cut a release candidate.
#
# Sets the version (VERSION env var, else keeps the current one), bumps the
# build number, commits, and pushes a `v<version>-rc.<n>` tag. The tag triggers
# CI, which builds the signed, notarized prerelease you'll test. When it passes,
# run `make release` to ship that exact binary.
#
# Pushes to origin/main and pushes a tag, so it needs your git credentials
# (a security-key tap).
set -euo pipefail

PLIST="UnrambleApp/Info.plist"
pb() { /usr/libexec/PlistBuddy "$@" "$PLIST"; }

if [ -n "$(git status --porcelain)" ]; then
    echo "!! working tree is not clean — commit or stash first" >&2
    exit 1
fi

VERSION="${VERSION:-$(pb -c 'Print :CFBundleShortVersionString')}"
BUILD=$(( $(pb -c 'Print :CFBundleVersion') + 1 ))

echo "── Setting version ${VERSION} (build ${BUILD})"
pb -c "Set :CFBundleShortVersionString ${VERSION}"
pb -c "Set :CFBundleVersion ${BUILD}"
git add "$PLIST"
git commit -m "Set version to ${VERSION} (build ${BUILD})"

git fetch --tags --quiet
N=1
while git rev-parse -q --verify "refs/tags/v${VERSION}-rc.${N}" >/dev/null 2>&1; do
    N=$(( N + 1 ))
done
TAG="v${VERSION}-rc.${N}"

echo "── Tagging ${TAG} and pushing (tap your security key)"
git tag "$TAG"
git push origin HEAD:main "$TAG"

echo "── ${TAG} pushed. CI is building the signed, notarized prerelease."
echo "   Watch:  gh run watch"
echo "   Then test the prerelease DMG and run:  make release"
