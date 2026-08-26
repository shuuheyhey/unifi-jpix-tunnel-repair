#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/unifi-jpix-tunnel-repair-preflight-test.$$
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || :; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/project" "$TMP/absent-project" "$TMP/missing-bin"
ln -s "$(command -v awk)" "$TMP/missing-bin/awk"

PREFLIGHT_PATH=$ROOT/tests/stubs/preflight:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

run_preflight() {
  RUN_OUTPUT=$TMP/output
  RUN_ERROR=$TMP/error
  : >"$TMP/calls.log"
  set +e
  PATH=${RUN_PATH:-$PREFLIGHT_PATH} \
    PREFLIGHT_PROJECT_ROOT=${PREFLIGHT_PROJECT_ROOT:-$TMP/absent-project/not-installed} \
    PREFLIGHT_VERSION_FILE=$TMP/missing-version \
    STUB_LOG=$TMP/calls.log \
    "$ROOT/scripts/unifi-jpix-tunnel-repair-preflight.sh" "$@" >"$RUN_OUTPUT" 2>"$RUN_ERROR"
  RUN_STATUS=$?
  unset PREFLIGHT_PROJECT_ROOT PREFLIGHT_STUB_MODE RUN_PATH
  set -e
}

run_preflight
output=$(cat "$RUN_OUTPUT")
calls=$(cat "$TMP/calls.log")

test_start 'ready preflight succeeds without an installed project'
assert_eq "$RUN_STATUS" 0
test_start 'preflight output is explicitly share-safe'
assert_contains "$output" 'PREFLIGHT_MODE=share-safe'
test_start 'target UniFi OS is recognized without exposing the version'
assert_contains "$output" 'UNIFI_OS_COMPATIBILITY=target'
test_start 'ready preflight reports required network capabilities'
assert_contains "$output" 'IPV6_DEFAULT_ROUTE=present
IPV6_GLOBAL_ADDRESS=present
DHCPV6_PD_ROUTE=present
IPIP6_TUNNEL_CANDIDATE_COUNT=2
IPIP6_TUNNEL_READY_COUNT=1'
test_start 'ready preflight reports UniFi firewall hooks'
assert_contains "$output" 'UNIFI_NAT_USER_CHAIN=present
UNIFI_IPV6_INPUT_USER_CHAIN=present'
test_start 'absent installation is informational'
assert_contains "$output" 'PROJECT_INSTALLATION=absent
RESULT=ready-for-config'

test_start 'share-safe output excludes fixture IPv4 IPv6 MAC interface and credentials'
for secret in \
  '203.0.113.42' \
  '2001:db8:1234:30::1' \
  '2001:db8:ffff::1' \
  'aa:bb:cc:dd:ee:ff' \
  'eth9' \
  'ip6tnl-secret' \
  'fixture-api-key' \
  'fixture-password'
do
  case $output$(cat "$RUN_ERROR") in
    *"$secret"*) fail "sensitive fixture value leaked: $secret" ;;
    *) pass ;;
  esac
done

test_start 'preflight invokes only the expected read-only command families'
unexpected_calls=$(printf '%s\n' "$calls" | awk '
  $1 != "id" && $1 != "ubnt-device-info" && $1 != "dpkg-query" &&
  $1 != "ip" && $1 != "iptables" && $1 != "ip6tables" { print }
')
assert_eq "$unexpected_calls" ''

test_start 'preflight issues no mutation command'
if grep -E ' (add|change|replace|set|del|delete|flush|-A|-I|-D|-F|-N|-X)( |$)' "$TMP/calls.log" >/dev/null; then
  fail 'mutation command observed'
else
  pass
fi

PREFLIGHT_STUB_MODE=missing-ipv6 run_preflight
test_start 'missing IPv6 prerequisites make preflight non-ready'
assert_eq "$RUN_STATUS" 1
test_start 'missing IPv6 prerequisites are reported without raw values'
assert_contains "$(cat "$RUN_OUTPUT")" 'IPV6_DEFAULT_ROUTE=absent
IPV6_GLOBAL_ADDRESS=absent
DHCPV6_PD_ROUTE=absent
IPIP6_TUNNEL_CANDIDATE_COUNT=0
IPIP6_TUNNEL_READY_COUNT=0'
test_start 'missing IPv6 prerequisites produce needs-attention result'
assert_contains "$(cat "$RUN_OUTPUT")" 'RESULT=needs-attention'

PREFLIGHT_STUB_MODE=unsupported-os run_preflight
test_start 'outside-target UniFi OS makes preflight non-ready'
assert_eq "$RUN_STATUS" 1
test_start 'outside-target version is classified without being disclosed'
assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_OS_COMPATIBILITY=outside-target'
test_start 'outside-target version produces needs-attention result'
assert_contains "$(cat "$RUN_OUTPUT")" 'RESULT=needs-attention'
test_start 'outside-target exact version stays private'
case $(cat "$RUN_OUTPUT")$(cat "$RUN_ERROR") in
  *4.1.13*) fail 'exact version leaked' ;;
  *) pass ;;
esac

RUN_PATH=$ROOT/tests/stubs/preflight:$TMP/missing-bin run_preflight
test_start 'missing required dependencies make preflight non-ready'
assert_eq "$RUN_STATUS" 1
test_start 'missing required dependencies are named generically'
assert_contains "$(cat "$RUN_OUTPUT")" 'DEPENDENCY_curl=missing
DEPENDENCY_systemctl=missing'
test_start 'missing required dependencies produce needs-attention result'
assert_contains "$(cat "$RUN_OUTPUT")" 'RESULT=needs-attention'

PREFLIGHT_PROJECT_ROOT=$TMP/project run_preflight
test_start 'existing installation is reported generically'
assert_contains "$(cat "$RUN_OUTPUT")" 'PROJECT_INSTALLATION=present'

run_preflight unexpected
test_start 'preflight rejects command-line arguments'
assert_eq "$RUN_STATUS" 2
test_start 'argument error remains share-safe'
case $(cat "$RUN_OUTPUT")$(cat "$RUN_ERROR") in
  *203.0.113.42*|*2001:db8:*|*fixture-password*) fail 'argument error leaked fixture data' ;;
  *) pass ;;
esac

test_finish
