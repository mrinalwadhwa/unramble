#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
    set -x
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/UnrambleKit"
REPORTER="$ROOT_DIR/scripts/parse-test-results.sh"
INVOCATION_DIR="$PWD"
SWIFT_BIN="${SWIFT_BIN:-swift}"

# Host and OS-adapter suites live in the UnrambleKitOSTests target and run in
# their own `os` lane, so the bounded CI selection excludes that whole target by
# name prefix. The remaining entries are the live, model, keychain, and corpus
# suites that run under their own gates.
CI_SKIP_REGEX='(AudioPipelineTests|KeychainServiceTests|LocalModelIntegrationTests|NemotronStreamingTests|OpenAIFileTranscriberLiveTests|OpenAIRealtimeLiveTests|OpenAIStreamingBenchmarkTests|PolishScenarioRegexTests|PolishScenarioDeterministicTests|ServiceConfigTests|UnrambleKitOSTests\.)'
# Positive selection for the host and OS-adapter lane. These suites exercise real
# CoreAudio devices, CGEvent taps, the main run loop, and system sound files.
# They degrade gracefully when a resource is absent, so they stay out of the
# bounded CI selection and run explicitly here.
OS_FILTER='UnrambleKitOSTests\.'
CI_FLAG_PATHS=(
    /tmp/unramble-test-categories
    /tmp/unramble-test-p1
    /tmp/unramble-test-training
    /tmp/unramble-test-nemotron-streaming
    /tmp/unramble-test-replay
    /tmp/unramble-test-streaming-replay
    /tmp/unramble-test-nemotron-baseline
    /tmp/unramble-test-mlx
    /tmp/unramble-test-mlx-17
    /tmp/unramble-test-mlx-gemma
)

usage() {
    printf 'usage: %s {default|ci|os|keychain}\n' "$0" >&2
}

die() {
    printf 'test-runner: %s\n' "$*" >&2
    exit 2
}

absolute_path() {
    local path="$1"

    case "$path" in
        /*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$INVOCATION_DIR" "$path" ;;
    esac
}

require_command() {
    local executable="$1"

    if [[ "$executable" == */* ]]; then
        [[ -x "$executable" ]] || die "command is not executable: $executable"
    else
        command -v "$executable" >/dev/null 2>&1 || die "command not found: $executable"
    fi
}

normalize_swift_bin() {
    case "$SWIFT_BIN" in
        /*) ;;
        */*) SWIFT_BIN="$(absolute_path "$SWIFT_BIN")" ;;
    esac
}

configure_paths() {
    local results_root timestamp log_dir

    if [[ -n "${TEST_LOG:-}" ]]; then
        LOG_PATH="$(absolute_path "$TEST_LOG")"
        log_dir="$(dirname "$LOG_PATH")"
        mkdir -p "$log_dir"
        RUN_DIR="$log_dir"
        SUMMARY_PATH="$LOG_PATH.summary.txt"
        REPORT_ERROR_PATH="$LOG_PATH.report-errors.log"
        XUNIT_OUTPUT="${TEST_XUNIT_OUTPUT:-$LOG_PATH.results.xml}"
        XUNIT_OUTPUT="$(absolute_path "$XUNIT_OUTPUT")"
    else
        results_root="$(absolute_path "${TEST_LOG_DIR:-$ROOT_DIR/.scratch/test-runs}")"
        mkdir -p "$results_root"
        timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
        RUN_DIR="$(mktemp -d "$results_root/unramble-tests-$MODE-$timestamp.XXXXXX")"
        LOG_PATH="$RUN_DIR/swift-test.log"
        SUMMARY_PATH="$RUN_DIR/summary.txt"
        REPORT_ERROR_PATH="$RUN_DIR/report-errors.log"
        XUNIT_OUTPUT="${TEST_XUNIT_OUTPUT:-$RUN_DIR/results.xml}"
        XUNIT_OUTPUT="$(absolute_path "$XUNIT_OUTPUT")"
    fi

    [[ "$XUNIT_OUTPUT" == *.xml ]] || die "TEST_XUNIT_OUTPUT must end in .xml"
    mkdir -p "$(dirname "$XUNIT_OUTPUT")"
    SWIFT_XML_PATH="${XUNIT_OUTPUT%.xml}-swift-testing.xml"
    [[ "$LOG_PATH" != "$SUMMARY_PATH" ]] || die "test log and summary paths must differ"
    [[ "$LOG_PATH" != "$SWIFT_XML_PATH" ]] || die "test log and xUnit paths must differ"

    rm -f "$SUMMARY_PATH" "$REPORT_ERROR_PATH" "$SWIFT_XML_PATH"
}

check_ci_ambient_flags() {
    local flag found
    found=0

    for flag in "${CI_FLAG_PATHS[@]}"; do
        if [[ -e "$flag" || -L "$flag" ]]; then
            printf 'test-runner: CI selection flag is present: %s\n' "$flag" >&2
            found=1
        fi
    done
    if (( found != 0 )); then
        printf 'test-runner: remove or move the listed flags before running the bounded CI selection\n' >&2
        return 2
    fi
}

clear_ci_environment() {
    local variable _

    while IFS='=' read -r variable _; do
        case "$variable" in
            UNRAMBLE_TEST_*) unset "$variable" ;;
        esac
    done < <(env)
    unset UNRAMBLE_MLX_TESTS
    unset OPENAI_API_KEY
    unset SWIFT_ACTIVE_COMPILATION_CONDITIONS
}

run_swift_tests() {
    local swift_args
    swift_args=(test --xunit-output "$XUNIT_OUTPUT")

    case "$MODE" in
        default)
            ;;
        ci)
            clear_ci_environment
            swift_args+=(--disable-automatic-resolution --skip "$CI_SKIP_REGEX")
            ;;
        os)
            clear_ci_environment
            swift_args+=(--disable-automatic-resolution --filter "$OS_FILTER")
            ;;
        keychain)
            export UNRAMBLE_TEST_KEYCHAIN=1
            ;;
    esac

    cd "$PACKAGE_DIR" || {
        printf 'test-runner: cannot enter package directory: %s\n' "$PACKAGE_DIR" >&2
        return 2
    }
    "$SWIFT_BIN" "${swift_args[@]}"
}

append_run_context() {
    case "$MODE" in
        default)
            printf 'Selection: default package selection; environment gates inherited.\n'
            ;;
        ci)
            printf 'Selection: bounded clean CI selection; host, live, model, and corpus suites excluded.\n'
            ;;
        os)
            printf 'Selection: host and OS-adapter lane (UnrambleKitOSTests target only).\n'
            ;;
        keychain)
            printf 'Selection: default plus Keychain suites; live/model/evaluation gates unchanged.\n'
            ;;
    esac
    printf 'Compile-gated: the SwiftPM selection did not define UNRAMBLE_MLX_TESTS; guarded tests were not compiled.\n'
}

print_failure_excerpt() {
    printf '\nFailure excerpt:\n'
    awk '
        /^Test Case .* failed \(/ || /^.*: error:/ || /^error:/ || /Fatal error:/ || /exited with unexpected signal/ || /^✘ Test / || /^✘ Suite / {
            print
            shown += 1
            if (shown == 20) {
                exit
            }
        }
    ' "$LOG_PATH"
}

print_artifacts() {
    printf '\nTest artifacts:\n'
    printf '  log: %s\n' "$LOG_PATH"
    printf '  Swift Testing xUnit: %s\n' "$SWIFT_XML_PATH"
    printf '  summary: %s\n' "$SUMMARY_PATH"
    if [[ -s "$REPORT_ERROR_PATH" ]]; then
        printf '  reporting errors: %s\n' "$REPORT_ERROR_PATH"
    fi
}

main() {
    local swift_status report_status context_status

    (( $# <= 1 )) || {
        usage
        exit 2
    }
    MODE="${1:-default}"
    case "$MODE" in
        default|ci|os|keychain) ;;
        *)
            usage
            die "unknown mode: $MODE"
            ;;
    esac

    normalize_swift_bin
    require_command "$SWIFT_BIN"
    require_command "$REPORTER"
    configure_paths

    if [[ "$MODE" == "ci" ]]; then
        if ! check_ci_ambient_flags >"$LOG_PATH" 2>&1; then
            cat "$LOG_PATH" >&2
            print_artifacts
            exit 2
        fi
    fi

    printf 'Running %s tests; full output: %s\n' "$MODE" "$LOG_PATH"
    set +e
    (run_swift_tests) >"$LOG_PATH" 2>&1
    swift_status=$?
    set -e

    set +e
    "$REPORTER" \
        --log "$LOG_PATH" \
        --swift-testing-xml "$SWIFT_XML_PATH" \
        >"$SUMMARY_PATH" 2>"$REPORT_ERROR_PATH"
    report_status=$?
    set -e

    if (( report_status == 0 || report_status == 1 )); then
        set +e
        append_run_context >>"$SUMMARY_PATH"
        context_status=$?
        rm -f "$REPORT_ERROR_PATH"
        set -e
        if (( context_status != 0 )); then
            printf '\nResult context could not be written to %s\n' "$SUMMARY_PATH" >&2
            if (( report_status == 0 )); then
                report_status=2
            fi
        fi
        set +e
        printf '\n'
        cat "$SUMMARY_PATH"
        set -e
    else
        set +e
        printf '\nResult reporting failed:\n' >&2
        cat "$REPORT_ERROR_PATH" >&2
        set -e
    fi

    set +e
    if (( swift_status != 0 || report_status == 1 )); then
        print_failure_excerpt
    fi
    print_artifacts
    set -e

    if (( swift_status != 0 )); then
        exit "$swift_status"
    fi
    if (( report_status != 0 )); then
        exit "$report_status"
    fi
}

main "$@"
