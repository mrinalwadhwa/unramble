#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
    set -x
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/UnrambleKit"
INVENTORY="$ROOT_DIR/scripts/ci-test-suites.txt"
RUNNER="$ROOT_DIR/scripts/run-tests.sh"
SWIFT_BIN="${SWIFT_BIN:-swift}"

# The test target whose suites run in the dedicated host and OS-adapter lane.
OS_TARGET="UnrambleKitOSTests"

usage() {
    printf 'usage: %s {check|update}\n' "$0" >&2
}

# Read the bounded-CI denylist straight from the test runner so the lane
# assignment shares one source of truth with the lane that enforces it. The
# assignment is a single-quoted extended regex on its own line.
read_ci_skip_regex() {
    local line
    line="$(grep -m1 "^CI_SKIP_REGEX=" "$RUNNER")" || {
        printf 'test-inventory: could not read CI_SKIP_REGEX from %s\n' "$RUNNER" >&2
        return 2
    }
    line="${line#CI_SKIP_REGEX=\'}"
    printf '%s\n' "${line%\'}"
}

# Assign a lane to one suite. The OS target owns the host lane; the runner's
# denylist owns the gated lanes (live, model, keychain, corpus, slow timeout);
# everything else is the deterministic CI core. The denylist match uses the same
# regex `make test-ci` applies, so a suite is labelled `gated` exactly when the
# clean CI selection skips it.
classify_suite() {
    local target="$1" suite="$2" skip="$3"
    if [[ "$target" == "$OS_TARGET" ]]; then
        printf 'os\n'
    elif [[ "$suite" =~ $skip ]]; then
        printf 'gated\n'
    else
        printf 'ci\n'
    fi
}

# List every discovered suite as "<lane> <suite>", sorted and de-duplicated.
# `swift test list` emits "Target.Suite/testName"; drop the test name, split the
# target from the suite, then classify. Unrelated build diagnostics go to stderr
# and are dropped; pipefail still fails the pipeline if the list command exits
# nonzero.
discover_lanes() {
    local skip qualified target suite
    skip="$(read_ci_skip_regex)"
    while IFS= read -r qualified; do
        [[ -n "$qualified" ]] || continue
        target="${qualified%%.*}"
        suite="${qualified#*.}"
        printf '%s %s\n' "$(classify_suite "$target" "$suite" "$skip")" "$suite"
    done < <(
        (cd "$PACKAGE_DIR" && "$SWIFT_BIN" test list 2>/dev/null) \
            | sed -E 's#/.*$##' \
            | sort -u
    ) | sort -u
}

update_inventory() {
    discover_lanes >"$INVENTORY"
    printf 'Updated %s (%s suites)\n' "$INVENTORY" "$(wc -l <"$INVENTORY" | tr -d ' ')"
}

# Fail closed: a suite discovered but absent from the committed inventory, an
# inventory entry no longer discovered, or a suite whose lane changed is a
# lane-ownership gap that a person must resolve, not a silently running, vanished,
# or reassigned suite.
check_inventory() {
    local current

    if [[ ! -f "$INVENTORY" ]]; then
        printf 'test-inventory: committed inventory is missing: %s\n' "$INVENTORY" >&2
        return 2
    fi

    current="$(mktemp)"
    discover_lanes >"$current"

    if diff -u "$INVENTORY" "$current" >/dev/null; then
        printf 'Test suite inventory matches (%s suites).\n' \
            "$(wc -l <"$current" | tr -d ' ')"
        rm -f "$current"
        return 0
    fi

    printf 'test-inventory: discovered suites differ from the committed inventory.\n' >&2
    printf '  < committed   > discovered   (each line is "<lane> <suite>")\n' >&2
    diff "$INVENTORY" "$current" >&2 || true
    rm -f "$current"
    printf '\nA new suite lands in the ci lane unless the OS target or the\n' >&2
    printf 'run-tests.sh denylist assigns it elsewhere. Place every suite in its\n' >&2
    printf 'lane, then refresh the inventory: scripts/check-test-inventory.sh update\n' >&2
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
