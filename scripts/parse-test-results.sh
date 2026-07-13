#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
    set -x
fi

usage() {
    printf 'usage: %s --log PATH --swift-testing-xml PATH\n' "$0" >&2
}

die() {
    printf 'test-results: %s\n' "$*" >&2
    exit 2
}

require_file() {
    local path="$1"
    local label="$2"

    [[ -f "$path" ]] || die "$label is missing: $path"
    [[ -r "$path" ]] || die "$label is not readable: $path"
}

xpath_integer() {
    local expression="$1"
    local value

    if ! value="$("$XMLLINT_BIN" --xpath "$expression" "$SWIFT_XML_PATH" 2>/dev/null)"; then
        die "cannot evaluate xUnit expression: $expression"
    fi
    if [[ "$value" =~ ^([0-9]+)(\.0+)?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi
    die "xUnit expression did not return a non-negative integer: $expression ($value)"
}

parse_xctest() {
    local pair status_line summary_line suite_status aggregate case_counts
    local executed native_failures aggregate_skipped
    local passed failed skipped selected

    if ! pair="$(awk '
        /^Test Suite '\''(All tests|Selected tests)'\'' (passed|failed) at / {
            candidate = $0
            if ((getline following) <= 0 || following !~ /^[[:space:]]*Executed /) {
                malformed += 1
                next
            }
            found += 1
            status = candidate
            summary = following
        }
        END {
            if (found != 1 || malformed != 0) {
                exit 2
            }
            print status
            print summary
        }
    ' "$LOG_PATH")"; then
        die "expected exactly one complete XCTest root summary"
    fi

    status_line="${pair%%$'\n'*}"
    summary_line="${pair#*$'\n'}"
    case "$status_line" in
        "Test Suite 'All tests' passed at "*|"Test Suite 'Selected tests' passed at "*) suite_status="passed" ;;
        "Test Suite 'All tests' failed at "*|"Test Suite 'Selected tests' failed at "*) suite_status="failed" ;;
        *) die "malformed XCTest root status" ;;
    esac

    if ! aggregate="$(printf '%s\n' "$summary_line" | awk '
        function number(value) {
            gsub(/^[^0-9]+|[^0-9]+$/, "", value)
            return value
        }
        {
            skipped = 0
            for (field_index = 1; field_index <= NF; field_index += 1) {
                word = $field_index
                gsub(/[,().]/, "", word)
                if (word == "Executed") {
                    executed = number($(field_index + 1))
                } else if (word == "skipped") {
                    skipped = number($(field_index - 2))
                } else if (word == "failure" || word == "failures") {
                    failures = number($(field_index - 1))
                }
            }
        }
        END {
            if (executed == "" || failures == "") {
                exit 2
            }
            printf "%s %s %s\n", executed, skipped, failures
        }
    ')"; then
        die "malformed XCTest aggregate: $summary_line"
    fi
    read -r executed aggregate_skipped native_failures <<< "$aggregate"

    case_counts="$(awk '
        /^Test Case .* passed \(/ { passed += 1 }
        /^Test Case .* failed \(/ { failed += 1 }
        /^Test Case .* skipped \(/ { skipped += 1 }
        END { printf "%d %d %d\n", passed, failed, skipped }
    ' "$LOG_PATH")"
    read -r passed failed skipped <<< "$case_counts"
    selected=$((passed + failed + skipped))

    (( selected > 0 )) || die "XCTest reported zero terminal test cases"
    (( executed == selected )) || die "XCTest aggregate selected $executed tests but terminal cases total $selected"
    (( aggregate_skipped == skipped )) || die "XCTest aggregate skipped $aggregate_skipped tests but terminal cases skipped $skipped"

    if (( failed == 0 )); then
        (( native_failures == 0 )) || die "XCTest has $native_failures failures but no failed terminal case"
        [[ "$suite_status" == "passed" ]] || die "XCTest suite failed without a failed terminal case"
    else
        (( native_failures >= failed )) || die "XCTest has $failed failed cases but only $native_failures native failures"
        [[ "$suite_status" == "failed" ]] || die "XCTest suite passed with $failed failed terminal cases"
    fi

    XCTEST_SELECTED="$selected"
    XCTEST_PASSED="$passed"
    XCTEST_FAILED="$failed"
    XCTEST_SKIPPED="$skipped"
    XCTEST_NATIVE_FAILURES="$native_failures"
}

parse_swift_testing() {
    local root_name suite_count missing_attributes
    local selected failed skipped overlap failure_error_overlap passed
    local aggregate_tests aggregate_failures aggregate_errors aggregate_skipped

    if ! "$XMLLINT_BIN" --noout "$SWIFT_XML_PATH" 2>/dev/null; then
        die "Swift Testing xUnit is malformed: $SWIFT_XML_PATH"
    fi
    root_name="$("$XMLLINT_BIN" --xpath 'name(/*)' "$SWIFT_XML_PATH" 2>/dev/null)"
    [[ "$root_name" == "testsuites" ]] || die "Swift Testing xUnit root must be testsuites"

    suite_count="$(xpath_integer 'count(/testsuites/testsuite)')"
    (( suite_count > 0 )) || die "Swift Testing xUnit contains no test suites"
    missing_attributes="$(xpath_integer 'count(/testsuites/testsuite[not(@tests) or not(@failures) or not(@errors) or not(@skipped)])')"
    (( missing_attributes == 0 )) || die "Swift Testing xUnit suite is missing count attributes"

    selected="$(xpath_integer 'count(//testcase)')"
    failed="$(xpath_integer 'count(//testcase[failure or error])')"
    skipped="$(xpath_integer 'count(//testcase[skipped])')"
    overlap="$(xpath_integer 'count(//testcase[skipped and (failure or error)])')"
    failure_error_overlap="$(xpath_integer 'count(//testcase[failure and error])')"
    aggregate_tests="$(xpath_integer 'sum(/testsuites/testsuite/@tests)')"
    aggregate_failures="$(xpath_integer 'sum(/testsuites/testsuite/@failures)')"
    aggregate_errors="$(xpath_integer 'sum(/testsuites/testsuite/@errors)')"
    aggregate_skipped="$(xpath_integer 'sum(/testsuites/testsuite/@skipped)')"

    (( selected > 0 )) || die "Swift Testing xUnit contains zero test cases"
    (( overlap == 0 )) || die "Swift Testing xUnit marks a test case as both skipped and failed"
    (( failure_error_overlap == 0 )) || die "Swift Testing xUnit marks a test case as both failure and error"
    (( aggregate_tests + aggregate_skipped == selected )) || die "Swift Testing xUnit aggregate counts do not match its test cases"
    (( aggregate_skipped == skipped )) || die "Swift Testing xUnit skipped count does not match its test cases"
    (( aggregate_failures + aggregate_errors == failed )) || die "Swift Testing xUnit failed count does not match its test cases"

    passed=$((selected - failed - skipped))
    (( passed >= 0 )) || die "Swift Testing xUnit result categories overlap"

    SWIFT_SELECTED="$selected"
    SWIFT_PASSED="$passed"
    SWIFT_FAILED="$failed"
    SWIFT_SKIPPED="$skipped"
}

main() {
    LOG_PATH=""
    SWIFT_XML_PATH=""

    while (( $# > 0 )); do
        case "$1" in
            --log)
                (( $# >= 2 )) || die "--log requires a path"
                LOG_PATH="$2"
                shift 2
                ;;
            --swift-testing-xml)
                (( $# >= 2 )) || die "--swift-testing-xml requires a path"
                SWIFT_XML_PATH="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage
                die "unknown argument: $1"
                ;;
        esac
    done

    [[ -n "$LOG_PATH" ]] || die "--log is required"
    [[ -n "$SWIFT_XML_PATH" ]] || die "--swift-testing-xml is required"
    require_file "$LOG_PATH" "test log"
    require_file "$SWIFT_XML_PATH" "Swift Testing xUnit"

    XMLLINT_BIN="$(command -v xmllint || true)"
    [[ -n "$XMLLINT_BIN" ]] || die "xmllint is required"

    parse_xctest
    parse_swift_testing

    printf 'XCTest: selected=%s passed=%s failed=%s skipped=%s\n' \
        "$XCTEST_SELECTED" "$XCTEST_PASSED" "$XCTEST_FAILED" "$XCTEST_SKIPPED"
    if (( XCTEST_NATIVE_FAILURES != XCTEST_FAILED )); then
        printf 'XCTest native failures: %s across %s failed test cases\n' \
            "$XCTEST_NATIVE_FAILURES" "$XCTEST_FAILED"
    fi
    printf 'Swift Testing: selected=%s passed=%s failed=%s skipped=%s\n' \
        "$SWIFT_SELECTED" "$SWIFT_PASSED" "$SWIFT_FAILED" "$SWIFT_SKIPPED"

    if (( XCTEST_FAILED > 0 || SWIFT_FAILED > 0 )); then
        return 1
    fi
}

main "$@"
