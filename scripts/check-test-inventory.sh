#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
    set -x
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/UnrambleKit"
INVENTORY="$ROOT_DIR/scripts/ci-test-suites.txt"
SWIFT_BIN="${SWIFT_BIN:-swift}"

usage() {
    printf 'usage: %s {check|update}\n' "$0" >&2
}

# List every test suite the package discovers under the current compile
# configuration, one suite type per line, sorted and de-duplicated. The list
# form emits "Target.Suite/testName"; strip the target prefix and test suffix.
# `swift test list` prints unrelated build diagnostics to stderr; drop them.
# pipefail still fails the pipeline if the list command itself exits nonzero.
discover_suites() {
    (cd "$PACKAGE_DIR" && "$SWIFT_BIN" test list 2>/dev/null) \
        | sed -E 's#^[^.]+\.##; s#/.*$##' \
        | sort -u
}

update_inventory() {
    discover_suites >"$INVENTORY"
    printf 'Updated %s (%s suites)\n' "$INVENTORY" "$(wc -l <"$INVENTORY" | tr -d ' ')"
}

# Fail closed: a suite discovered but absent from the committed inventory (or an
# inventory entry no longer discovered) is a lane-ownership gap that a person
# must resolve, not a silently running or vanished suite.
check_inventory() {
    local current

    if [[ ! -f "$INVENTORY" ]]; then
        printf 'test-inventory: committed inventory is missing: %s\n' "$INVENTORY" >&2
        return 2
    fi

    current="$(mktemp)"
    discover_suites >"$current"

    if diff -u "$INVENTORY" "$current" >/dev/null; then
        printf 'Test suite inventory matches (%s suites).\n' \
            "$(wc -l <"$current" | tr -d ' ')"
        rm -f "$current"
        return 0
    fi

    printf 'test-inventory: discovered suites differ from the committed inventory.\n' >&2
    printf '  < committed   > discovered\n' >&2
    diff "$INVENTORY" "$current" >&2 || true
    rm -f "$current"
    printf '\nAssign every new suite to a lane (deterministic, host, live, model,\n' >&2
    printf 'or slow), then refresh the inventory: scripts/check-test-inventory.sh update\n' >&2
    return 1
}

main() {
    (($# <= 1)) || {
        usage
        exit 2
    }

    case "${1:-check}" in
        check) check_inventory ;;
        update) update_inventory ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
