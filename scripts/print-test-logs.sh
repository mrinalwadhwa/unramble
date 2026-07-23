#!/usr/bin/env bash
#
# Print every Swift test log under TEST_LOG_DIR, each wrapped in a GitHub
# Actions log group. Print a notice when the directory or the logs are absent.
# Run on a GitHub Actions runner as an always() step.
set -euo pipefail

if [[ ! -d "${TEST_LOG_DIR:-}" ]]; then
  printf 'No test log directory was created.\n'
  exit 0
fi

found=0
while IFS= read -r log; do
  found=1
  printf '::group::%s\n' "$log"
  cat "$log"
  printf '::endgroup::\n'
done < <(find "$TEST_LOG_DIR" -type f -name swift-test.log -print | sort)

if (( found == 0 )); then
  printf 'No Swift test logs were created.\n'
fi
