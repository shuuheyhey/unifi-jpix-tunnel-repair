#!/bin/sh
TEST_COUNT=0
TEST_FAILURES=0

test_start() { TEST_NAME=$1; }
pass() { TEST_COUNT=$((TEST_COUNT + 1)); printf 'ok - %s\n' "$TEST_NAME"; }
fail() { TEST_COUNT=$((TEST_COUNT + 1)); TEST_FAILURES=$((TEST_FAILURES + 1)); printf 'not ok - %s: %s\n' "$TEST_NAME" "$1" >&2; }
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected <$2>, got <$1>"; }
assert_contains() { case $1 in *"$2"*) pass ;; *) fail "missing <$2> in <$1>" ;; esac; }
assert_file_exists() { [ -f "$1" ] && pass || fail "missing file $1"; }
assert_success() { "$@" >/tmp/unifi-jpix-tunnel-repair-test.out 2>/tmp/unifi-jpix-tunnel-repair-test.err && pass || fail "command failed: $*"; }
assert_failure() { if "$@" >/tmp/unifi-jpix-tunnel-repair-test.out 2>/tmp/unifi-jpix-tunnel-repair-test.err; then fail "command unexpectedly passed: $*"; else pass; fi; }
test_finish() { [ "$TEST_FAILURES" -eq 0 ] || exit 1; }
