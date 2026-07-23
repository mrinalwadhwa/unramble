#!/usr/bin/env bash
#
# Import the Developer ID signing certificate into a temporary keychain for a
# CI signing run. Read the base64 certificate and its password from the
# environment, create an ephemeral keychain, and export its path to GITHUB_ENV
# for later steps. Run on a GitHub Actions runner.
set -euo pipefail

: "${DEVELOPER_ID_CERTIFICATE_P12:?set to the base64-encoded .p12}"
: "${DEVELOPER_ID_CERTIFICATE_PASSWORD:?set to the .p12 password}"

KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

CERT_PATH="$RUNNER_TEMP/certificate.p12"
echo "$DEVELOPER_ID_CERTIFICATE_P12" | base64 --decode > "$CERT_PATH"
security import "$CERT_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
rm -f "$CERT_PATH"

security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
# shellcheck disable=SC2046  # intentional word-split of the keychain list
security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')

echo "KEYCHAIN_PATH=${KEYCHAIN_PATH}" >> "$GITHUB_ENV"
