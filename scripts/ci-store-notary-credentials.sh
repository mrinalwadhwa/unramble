#!/usr/bin/env bash
#
# Store App Store Connect API credentials in the notarytool keychain profile
# that `make notarize` uses. Read the base64 API key and its identifiers from
# the environment. Run on a GitHub Actions runner.
set -euo pipefail

: "${APPLE_API_KEY:?set to the base64-encoded .p8}"
: "${APPLE_API_KEY_ID:?set to the API key id}"
: "${APPLE_API_ISSUER_ID:?set to the API issuer id}"

API_KEY_PATH="$RUNNER_TEMP/api-key.p8"
echo "$APPLE_API_KEY" | base64 --decode > "$API_KEY_PATH"

xcrun notarytool store-credentials "unramble-notarize" \
  --key "$API_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID"

rm -f "$API_KEY_PATH"
