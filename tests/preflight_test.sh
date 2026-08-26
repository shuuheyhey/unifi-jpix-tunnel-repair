#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/unifi-jpix-tunnel-repair-preflight-test.$$
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || :; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/project" "$TMP/absent-project" "$TMP/missing-bin" "$TMP/present-bin"
printf '10.5.67.0-g6e0e987bf\n' >"$TMP/network-version"
ln -s "$(command -v awk)" "$TMP/missing-bin/awk"
ln -s "$(command -v awk)" "$TMP/present-bin/curl"
ln -s "$(command -v awk)" "$TMP/present-bin/systemctl"

PREFLIGHT_PATH=$TMP/present-bin:$ROOT/tests/stubs/preflight:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

run_preflight() {
  RUN_OUTPUT=$TMP/output
  RUN_ERROR=$TMP/error
  : >"$TMP/calls.log"
  set +e
  PATH=${RUN_PATH:-$PREFLIGHT_PATH} \
    PREFLIGHT_PROJECT_ROOT=${PREFLIGHT_PROJECT_ROOT:-$TMP/absent-project/not-installed} \
    PREFLIGHT_VERSION_FILE=$TMP/missing-version \
    PREFLIGHT_NETWORK_VERSION_FILE=$TMP/network-version \
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
test_start 'exact verified platform tuple is required without exposing its values'
assert_contains "$output" 'UNIFI_NETWORK_VERSION=verified
PLATFORM_COMPATIBILITY=verified
XTABLES_BACKEND=legacy'
test_start 'ready preflight reports required network capabilities'
assert_contains "$output" 'IPV6_DEFAULT_ROUTE=present
IPV6_GLOBAL_ADDRESS=present
DHCPV6_PD_ROUTE=present
DHCPV6_PD_LAN64_EVIDENCE=absent
IPIP6_TUNNEL_CANDIDATE_COUNT=2
IPIP6_TUNNEL_READY_COUNT=1'
test_start 'ready preflight reports UniFi firewall hooks'
assert_contains "$output" 'UNIFI_NAT_USER_CHAIN=present
UNIFI_NAT_PARENT_JUMP=present
UNIFI_IPV6_INPUT_USER_CHAIN=present
UNIFI_IPV6_INPUT_PARENT_JUMP=present'
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

PREFLIGHT_STUB_MODE=expanded-pd run_preflight
test_start 'expanded PD on a bridge is ready without an aggregate route'
assert_eq "$RUN_STATUS" 0
test_start 'expanded PD reports bridge evidence separately from aggregate route'
assert_contains "$(cat "$RUN_OUTPUT")" 'DHCPV6_PD_ROUTE=absent
DHCPV6_PD_LAN64_EVIDENCE=present'
test_start 'expanded PD produces ready-for-config result'
assert_contains "$(cat "$RUN_OUTPUT")" 'RESULT=ready-for-config'
test_start 'expanded PD bridge identity stays private'
case $(cat "$RUN_OUTPUT")$(cat "$RUN_ERROR") in
  *br-secret*) fail 'bridge identity leaked' ;;
  *) pass ;;
esac

PREFLIGHT_STUB_MODE=wan-only-64 run_preflight
test_start 'global 64 on a non-bridge remains non-ready'
assert_eq "$RUN_STATUS" 1
test_start 'WAN-only 64 is not accepted as delegated LAN evidence'
assert_contains "$(cat "$RUN_OUTPUT")" 'DHCPV6_PD_ROUTE=absent
DHCPV6_PD_LAN64_EVIDENCE=absent'
test_start 'WAN-only 64 produces needs-attention result'
assert_contains "$(cat "$RUN_OUTPUT")" 'RESULT=needs-attention'

test_start 'preflight invokes only the expected read-only command families'
unexpected_calls=$(printf '%s\n' "$calls" | awk '
  $1 != "id" && $1 != "ubnt-device-info" && $1 != "uname" &&
  $1 != "ip" && $1 != "iptables" && $1 != "ip6tables" { print }
')
assert_eq "$unexpected_calls" ''
test_start 'preflight does not trust a removed dpkg package record'
if grep -F 'dpkg-query' "$TMP/calls.log" >/dev/null 2>&1; then fail 'dpkg-query was invoked'; else pass; fi

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
DHCPV6_PD_LAN64_EVIDENCE=absent
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

for platform_mode in unsupported-kernel unsupported-iproute nft-backend; do
  PREFLIGHT_STUB_MODE=$platform_mode run_preflight
  test_start "$platform_mode makes the exact platform gate non-ready"
  assert_eq "$RUN_STATUS" 1
  test_start "$platform_mode reports only share-safe platform classifications"
  assert_contains "$(cat "$RUN_OUTPUT")" 'PLATFORM_COMPATIBILITY=unknown'
done

cp "$TMP/network-version" "$TMP/network-version.good"
printf '10.5.68.0-unknown\n' >"$TMP/network-version"
run_preflight
test_start 'unknown UniFi Network version makes the exact platform gate non-ready'
assert_eq "$RUN_STATUS" 1
test_start 'unknown UniFi Network version is not disclosed'
assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_NETWORK_VERSION=unverified
PLATFORM_COMPATIBILITY=unknown'
mv "$TMP/network-version.good" "$TMP/network-version"

for parent_mode in missing-parent duplicate-parent detached-parent; do
  PREFLIGHT_STUB_MODE=$parent_mode run_preflight
  test_start "$parent_mode makes the NAT hook gate non-ready"
  assert_eq "$RUN_STATUS" 1
  test_start "$parent_mode reports no verified NAT parent jump"
  assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_NAT_PARENT_JUMP=absent'
done

for parent_mode in missing-v6-parent duplicate-v6-parent detached-v6-parent; do
  PREFLIGHT_STUB_MODE=$parent_mode run_preflight
  test_start "$parent_mode makes the IPv6 hook gate non-ready"
  assert_eq "$RUN_STATUS" 1
  test_start "$parent_mode reports no verified IPv6 input parent jump"
  assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_IPV6_INPUT_PARENT_JUMP=absent'
done

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
