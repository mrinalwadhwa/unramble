#!/usr/bin/env bash
set -euo pipefail

if [[ "${TRACE:-0}" == "1" ]]; then
    set -x
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$ROOT_DIR/scripts/parse-test-results.sh"
RUNNER="$ROOT_DIR/scripts/run-tests.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/unramble-test-runner-tests.XXXXXX")"
PASSED=0

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok %s - %s\n' "$PASSED" "$1"
}

assert_contains() {
    local path="$1"
    local expected="$2"

    grep -Fqx "$expected" "$path" || fail "$path does not contain: $expected"
}

expect_parser_success() {
    local name="$1"
    local log="$2"
    local xml="$3"

    if ! "$PARSER" --log "$log" --swift-testing-xml "$xml" \
        >"$TEMP_DIR/$name.out" 2>"$TEMP_DIR/$name.err"; then
        cat "$TEMP_DIR/$name.err" >&2
        fail "$name should succeed"
    fi
}

expect_parser_failure() {
    local name="$1"
    local log="$2"
    local xml="$3"
    local status

    set +e
    "$PARSER" --log "$log" --swift-testing-xml "$xml" \
        >"$TEMP_DIR/$name.out" 2>"$TEMP_DIR/$name.err"
    status=$?
    set -e
    [[ "$status" == "2" ]] || fail "$name should exit 2, got $status"
}

write_fixtures() {
    cat >"$TEMP_DIR/valid.log" <<'EOF'
Test Suite 'All tests' started at 2026-07-13 12:00:00.000.
Test Case '-[ProbeTests testPassOne]' passed (0.001 seconds).
Test Case '-[ProbeTests testPassTwo]' passed (0.001 seconds).
Test Case '-[ProbeTests testSkip]' skipped (0.001 seconds).
Test Suite 'All tests' passed at 2026-07-13 12:00:00.010.
	 Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.003 (0.010) seconds
EOF

    cat >"$TEMP_DIR/multiple-native-failures.log" <<'EOF'
Test Suite 'All tests' started at 2026-07-13 12:00:00.000.
Test Case '-[ProbeTests testFailsTwice]' failed (0.001 seconds).
Test Case '-[ProbeTests testPasses]' passed (0.001 seconds).
Test Suite 'All tests' failed at 2026-07-13 12:00:00.010.
	 Executed 2 tests, with 2 failures (0 unexpected) in 0.002 (0.010) seconds
EOF

    cat >"$TEMP_DIR/truncated.log" <<'EOF'
Test Suite 'All tests' started at 2026-07-13 12:00:00.000.
Test Case '-[ProbeTests testPasses]' passed (0.001 seconds).
Test Suite 'All tests' passed at 2026-07-13 12:00:00.010.
EOF

    sed 's/All tests/Selected tests/g' "$TEMP_DIR/valid.log" >"$TEMP_DIR/selected.log"

    cat >"$TEMP_DIR/valid.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="0" tests="2" failures="0" skipped="1" time="0.01">
    <testcase classname="Probe" name="passesOne" time="0.001" />
    <testcase classname="Probe" name="passesTwo" time="0.001" />
    <testcase classname="Probe" name="skips"><skipped>fixture</skipped></testcase>
  </testsuite>
</testsuites>
EOF

    cat >"$TEMP_DIR/failures.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="TestResults" errors="1" tests="3" failures="1" skipped="1" time="0.01">
    <testcase classname="Probe" name="passes" />
    <testcase classname="Probe" name="fails">
      <failure message="first" />
      <failure message="second" />
    </testcase>
    <testcase classname="Probe" name="errors"><error message="fixture" /></testcase>
    <testcase classname="Probe" name="skips"><skipped>fixture</skipped></testcase>
  </testsuite>
</testsuites>
EOF

    cat >"$TEMP_DIR/malformed.xml" <<'EOF'
<testsuites><testsuite>
EOF

    cat >"$TEMP_DIR/zero.xml" <<'EOF'
<testsuites><testsuite name="empty" errors="0" tests="0" failures="0" skipped="0" /></testsuites>
EOF

    cat >"$TEMP_DIR/mismatch.xml" <<'EOF'
<testsuites>
  <testsuite name="mismatch" errors="0" tests="8" failures="0" skipped="1">
    <testcase classname="Probe" name="passes" />
    <testcase classname="Probe" name="skips"><skipped>fixture</skipped></testcase>
  </testsuite>
</testsuites>
EOF

    cat >"$TEMP_DIR/overlap.xml" <<'EOF'
<testsuites>
  <testsuite name="overlap" errors="0" tests="0" failures="1" skipped="1">
    <testcase classname="Probe" name="overlap">
      <skipped>fixture</skipped>
      <failure message="fixture" />
    </testcase>
  </testsuite>
</testsuites>
EOF
}

write_fake_swift() {
    cat >"$TEMP_DIR/fake-swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "test" ]] || {
    printf 'fake-swift: expected test subcommand\n' >&2
    exit 64
}
shift
output=""
locked=0
skip_pattern=""
while (( $# > 0 )); do
    case "$1" in
        --xunit-output)
            (( $# >= 2 )) || exit 64
            output="$2"
            shift 2
            ;;
        --skip)
            (( $# >= 2 )) || exit 64
            skip_pattern="$2"
            shift 2
            ;;
        --disable-automatic-resolution)
            locked=1
            shift
            ;;
        *)
            printf 'fake-swift: unexpected argument: %s\n' "$1" >&2
            exit 64
            ;;
    esac
done
[[ -n "$output" ]] || exit 64
if [[ "${FAKE_REQUIRE_LOCKED:-0}" == "1" && "$locked" != "1" ]]; then
    printf 'fake-swift: CI did not lock package resolution\n' >&2
    exit 66
fi
if [[ "${FAKE_REQUIRE_SKIP:-0}" == "1" && -z "$skip_pattern" ]]; then
    printf 'fake-swift: CI did not supply a skip filter\n' >&2
    exit 67
fi
if [[ "${FAKE_ASSERT_CI_CLEAN:-0}" == "1" ]]; then
    if env | grep -Eq '^(UNRAMBLE_TEST_|UNRAMBLE_MLX_TESTS=|OPENAI_API_KEY=|SWIFT_ACTIVE_COMPILATION_CONDITIONS=)'; then
        printf 'fake-swift: CI test gates were not cleared\n' >&2
        exit 65
    fi
fi
actual="${output%.xml}-swift-testing.xml"
mkdir -p "$(dirname "$actual")"
if [[ "${FAKE_SWIFT_NO_XML:-0}" != "1" ]]; then
    cp "$FAKE_SWIFT_XML" "$actual"
fi
cat "$FAKE_SWIFT_LOG"
sleep "${FAKE_SWIFT_DELAY:-0}"
exit "${FAKE_SWIFT_STATUS:-0}"
EOF
    chmod +x "$TEMP_DIR/fake-swift"
}

test_parser_counts() {
    expect_parser_success "valid" "$TEMP_DIR/valid.log" "$TEMP_DIR/valid.xml"
    assert_contains "$TEMP_DIR/valid.out" "XCTest: selected=3 passed=2 failed=0 skipped=1"
    assert_contains "$TEMP_DIR/valid.out" "Swift Testing: selected=3 passed=2 failed=0 skipped=1"
    expect_parser_success "selected" "$TEMP_DIR/selected.log" "$TEMP_DIR/valid.xml"
    assert_contains "$TEMP_DIR/selected.out" "XCTest: selected=3 passed=2 failed=0 skipped=1"
    pass "reports All/Selected root suites without treating the xUnit tests attribute as selected"
}

test_failed_case_counts() {
    local status

    set +e
    "$PARSER" \
        --log "$TEMP_DIR/multiple-native-failures.log" \
        --swift-testing-xml "$TEMP_DIR/failures.xml" \
        >"$TEMP_DIR/failures.out" 2>"$TEMP_DIR/failures.err"
    status=$?
    set -e
    [[ "$status" == "1" ]] || fail "valid failure report should exit 1, got $status"
    assert_contains "$TEMP_DIR/failures.out" "XCTest: selected=2 passed=1 failed=1 skipped=0"
    assert_contains "$TEMP_DIR/failures.out" "XCTest native failures: 2 across 1 failed test cases"
    assert_contains "$TEMP_DIR/failures.out" "Swift Testing: selected=4 passed=1 failed=2 skipped=1"
    pass "counts failed test cases once when frameworks record multiple issues"
}

test_invalid_reports() {
    expect_parser_failure "truncated" "$TEMP_DIR/truncated.log" "$TEMP_DIR/valid.xml"
    expect_parser_failure "malformed" "$TEMP_DIR/valid.log" "$TEMP_DIR/malformed.xml"
    expect_parser_failure "missing" "$TEMP_DIR/valid.log" "$TEMP_DIR/missing.xml"
    expect_parser_failure "zero" "$TEMP_DIR/valid.log" "$TEMP_DIR/zero.xml"
    expect_parser_failure "mismatch" "$TEMP_DIR/valid.log" "$TEMP_DIR/mismatch.xml"
    expect_parser_failure "overlap" "$TEMP_DIR/valid.log" "$TEMP_DIR/overlap.xml"
    pass "rejects truncated, missing, malformed, zero, mismatched, and overlapping reports"
}

test_runner_preserves_status() {
    local status explicit_log
    explicit_log="$TEMP_DIR/explicit result.log"

    set +e
    (
        cd "$TEMP_DIR" || exit 1
        env \
            TEST_LOG="$explicit_log" \
            SWIFT_BIN=./fake-swift \
            FAKE_SWIFT_LOG="$TEMP_DIR/valid.log" \
            FAKE_SWIFT_XML="$TEMP_DIR/valid.xml" \
            FAKE_SWIFT_STATUS=42 \
            "$RUNNER" default >"$TEMP_DIR/runner-status.out" 2>&1
    )
    status=$?
    set -e

    [[ "$status" == "42" ]] || fail "runner should preserve status 42, got $status"
    [[ -f "$explicit_log" ]] || fail "runner did not honor TEST_LOG"
    assert_contains "$explicit_log.summary.txt" "XCTest: selected=3 passed=2 failed=0 skipped=1"
    pass "normalizes a relative Swift command and preserves its process status"
}

test_runner_preserves_status_without_reports() {
    local status compile_log
    compile_log="$TEMP_DIR/compile failure.log"

    set +e
    env \
        TEST_LOG="$compile_log" \
        SWIFT_BIN="$TEMP_DIR/fake-swift" \
        FAKE_SWIFT_LOG="$TEMP_DIR/truncated.log" \
        FAKE_SWIFT_XML="$TEMP_DIR/valid.xml" \
        FAKE_SWIFT_NO_XML=1 \
        FAKE_SWIFT_STATUS=42 \
        "$RUNNER" default >"$TEMP_DIR/runner-no-report.out" 2>&1
    status=$?
    set -e

    [[ "$status" == "42" ]] || fail "runner should preserve status 42 without reports, got $status"
    [[ -s "$compile_log.report-errors.log" ]] || fail "runner did not preserve its reporting error"
    pass "preserves the Swift process status when reports are unavailable"
}

test_runner_fails_on_reported_failures() {
    local status failure_log
    failure_log="$TEMP_DIR/reported failure.log"

    set +e
    env \
        TEST_LOG="$failure_log" \
        SWIFT_BIN="$TEMP_DIR/fake-swift" \
        FAKE_SWIFT_LOG="$TEMP_DIR/multiple-native-failures.log" \
        FAKE_SWIFT_XML="$TEMP_DIR/failures.xml" \
        FAKE_SWIFT_STATUS=0 \
        "$RUNNER" default >"$TEMP_DIR/runner-reported-failure.out" 2>&1
    status=$?
    set -e

    [[ "$status" == "1" ]] || fail "runner should fail on reported test failures, got $status"
    assert_contains "$failure_log.summary.txt" "Swift Testing: selected=4 passed=1 failed=2 skipped=1"
    pass "fails closed when reports contain failures despite a zero Swift process status"
}

test_ci_clears_environment() {
    local ci_log
    ci_log="$TEMP_DIR/ci result.log"

    env \
        TEST_LOG="$ci_log" \
        SWIFT_BIN="$TEMP_DIR/fake-swift" \
        FAKE_SWIFT_LOG="$TEMP_DIR/selected.log" \
        FAKE_SWIFT_XML="$TEMP_DIR/valid.xml" \
        FAKE_ASSERT_CI_CLEAN=1 \
        FAKE_REQUIRE_LOCKED=1 \
        FAKE_REQUIRE_SKIP=1 \
        UNRAMBLE_TEST_OPENAI=1 \
        UNRAMBLE_TEST_UNLISTED_FUTURE_GATE=1 \
        UNRAMBLE_MLX_TESTS=1 \
        OPENAI_API_KEY=fixture-secret \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS=UNRAMBLE_MLX_TESTS \
        "$RUNNER" ci >"$TEMP_DIR/runner-ci.out" 2>&1 || {
            cat "$TEMP_DIR/runner-ci.out" >&2
            fail "CI runner should clear test gates"
        }

    assert_contains "$ci_log.summary.txt" "Selection: bounded clean CI selection; host, live, model, and corpus suites excluded."
    pass "clears test gates and locks dependencies in the clean CI selection"
}

test_concurrent_run_directories() {
    local runs_root pid_one pid_two status_one status_two directory
    local directories
    runs_root="$TEMP_DIR/run results with spaces"
    mkdir -p "$runs_root"

    env \
        TEST_LOG_DIR="$runs_root" \
        SWIFT_BIN="$TEMP_DIR/fake-swift" \
        FAKE_SWIFT_LOG="$TEMP_DIR/valid.log" \
        FAKE_SWIFT_XML="$TEMP_DIR/valid.xml" \
        FAKE_SWIFT_DELAY=0.1 \
        "$RUNNER" default >"$TEMP_DIR/concurrent-one.out" 2>&1 &
    pid_one=$!
    env \
        TEST_LOG_DIR="$runs_root" \
        SWIFT_BIN="$TEMP_DIR/fake-swift" \
        FAKE_SWIFT_LOG="$TEMP_DIR/valid.log" \
        FAKE_SWIFT_XML="$TEMP_DIR/valid.xml" \
        FAKE_SWIFT_DELAY=0.1 \
        "$RUNNER" default >"$TEMP_DIR/concurrent-two.out" 2>&1 &
    pid_two=$!

    set +e
    wait "$pid_one"
    status_one=$?
    wait "$pid_two"
    status_two=$?
    set -e
    [[ "$status_one" == "0" && "$status_two" == "0" ]] || fail "concurrent runners failed: $status_one, $status_two"

    shopt -s nullglob
    directories=("$runs_root"/*)
    shopt -u nullglob
    [[ "${#directories[@]}" == "2" ]] || fail "expected two run directories, got ${#directories[@]}"
    for directory in "${directories[@]}"; do
        [[ -f "$directory/swift-test.log" ]] || fail "missing concurrent test log: $directory"
        [[ -f "$directory/results-swift-testing.xml" ]] || fail "missing concurrent xUnit: $directory"
        [[ -f "$directory/summary.txt" ]] || fail "missing concurrent summary: $directory"
    done
    pass "creates independent artifacts for concurrent runs and paths with spaces"
}

test_shell_quality() {
    bash -n "$PARSER" "$RUNNER" "$0"
    pass "passes Bash syntax checks"

    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck "$PARSER" "$RUNNER" "$0"
        pass "passes ShellCheck"
    else
        [[ "${CI:-}" != "true" ]] || fail "ShellCheck is required in CI"
        printf 'skip - ShellCheck is not installed locally\n'
    fi
}

main() {
    write_fixtures
    write_fake_swift
    test_parser_counts
    test_failed_case_counts
    test_invalid_reports
    test_runner_preserves_status
    test_runner_preserves_status_without_reports
    test_runner_fails_on_reported_failures
    test_ci_clears_environment
    test_concurrent_run_directories
    test_shell_quality
    printf '%s runner checks passed\n' "$PASSED"
}

main "$@"
