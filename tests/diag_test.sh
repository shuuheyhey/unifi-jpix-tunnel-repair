#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/v6plus-diag-test.$$
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || :; rm -rf "$TMP"' EXIT HUP INT TERM
STATE=$TMP/state
mkdir -p "$TMP/config" "$TMP/missing-bin" "$STATE"
chmod 700 "$STATE"

cat >"$TMP/config/v6plus.env" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
STATIC_V4=203.0.113.42
BR_V6=2001:db8:ffff::1
IID=00cb:0071:2a00:0000
TUN_MTU=1460
TCP_MSS=1420
ROUTE_TABLE=300
RULE_PREF_BASE=10000
WATCH_INTERVAL_SECONDS=5
UPDATE_INTERVAL_SECONDS=600
OUTER_IPIP_ALLOW=auto
EOF

cat >"$TMP/config/networks.conf" <<'EOF'
br0 192.168.20.0/24
br10 192.168.10.0/24
EOF

DIAG_PATH=$ROOT/tests/stubs/diag:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_LIB="$ROOT/scripts/v6plus-lib.sh"
export V6PLUS_STATE_DIR=$STATE
export V6PLUS_ALLOW_NONROOT=1

run_diag() {
  RUN_OUTPUT=$TMP/output
  RUN_SAFE_OUTPUT=$TMP/share-safe-output
  RUN_ERROR=$TMP/error
  rm -f "$RUN_OUTPUT" "$RUN_SAFE_OUTPUT" "$RUN_ERROR"
  : >"$TMP/calls.log"
  set +e
  PATH=$DIAG_PATH STUB_LOG="$TMP/calls.log" "$ROOT/scripts/v6plus-diag.sh" \
    --config "$TMP/config" --full-output "$RUN_OUTPUT" "$@" >"$RUN_SAFE_OUTPUT" 2>"$RUN_ERROR"
  RUN_STATUS=$?
  unset DIAG_CURL4_FAIL DIAG_CURL6_FAIL DIAG_FALLBACK_CHAINS \
    DIAG_NETWORK_DOWN DIAG_NETWORK_MISSING DIAG_NO_GLOBAL_V6 DIAG_NO_PD \
    DIAG_NO_ROUTE_SOURCE DIAG_OUTER_APPROVED_TAG DIAG_OUTER_ARBITRARY_COMMENT \
    DIAG_OUTER_EXTRA DIAG_OUTER_IPENCAP DIAG_OUTER_NEGATED DIAG_OUTER_UNTAGGED \
    DIAG_SNAPSHOT_SECRETS DIAG_TUNNEL_ABSENT DIAG_TUNNEL_LIST_MODE \
    DIAG_TUNNEL_WRONG_MODE DIAG_UBNT_MODE DIAG_WAN_DOWN \
    DIAG_ZERO_PREFERRED_ONLY V6PLUS_VERSION_DRAIN_MARKER V6PLUS_VERSION_FILE
  set -e
}

DIAG_SKIP_CONNECTIVITY=1 PATH=$DIAG_PATH STUB_LOG="$TMP/calls.log" \
  "$ROOT/scripts/v6plus-diag.sh" --config "$TMP/config" >"$TMP/default-output" 2>"$TMP/default-error" || :
test_start 'default diagnostic output is explicitly share-safe'
assert_contains "$(cat "$TMP/default-output")" 'DIAGNOSTIC_MODE=share-safe'
test_start 'default diagnostic output contains no complete IP address or CIDR'
if grep -E '([0-9]{1,3}[.]){3}[0-9]{1,3}|[0-9A-Fa-f]{1,4}:[0-9A-Fa-f:]|/[0-9]{1,3}' "$TMP/default-output" >/dev/null; then
  fail 'sensitive network value found in share-safe output'
else
  pass
fi

assert_not_contains() {
  case $1 in
    *"$2"*) fail "unexpected <$2> in <$1>" ;;
    *) pass ;;
  esac
}

assert_status() { assert_eq "$RUN_STATUS" "$1"; }

DIAG_SKIP_CONNECTIVITY=1 run_diag
output=$(cat "$RUN_OUTPUT")
calls=$(cat "$TMP/calls.log")

test_start 'full diagnostics report is ready'
assert_status 0
test_start 'full diagnostics file is private'
assert_eq "$(stat -c %a "$RUN_OUTPUT")" 600
test_start 'full diagnostics uses configured WAN'
assert_contains "$output" 'WAN_IF=eth9'
test_start 'full diagnostics uses configured tunnel selection'
assert_contains "$output" 'TUN_SELECTION=configured
TUN_IF=ip6tnl1'
test_start 'route-selected source is expanded'
assert_contains "$output" 'BR_ROUTE_SOURCE_V6=2001:0db8:1234:0030:abcd:0000:0000:0001'
test_start 'local endpoint uses route source upper 64 bits'
assert_contains "$output" 'LOCAL_TUNNEL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000'
test_start 'tunnel remote is collected read-only'
assert_contains "$output" 'TUN_REMOTE_V6=2001:db8:ffff::1'
test_start 'exact outer accept recognizes explicit host prefixes'
assert_contains "$output" 'OUTER_IPIP_EXACT_ACCEPT=yes'

DIAG_SKIP_CONNECTIVITY=1 DIAG_OUTER_IPENCAP=1 run_diag
test_start 'exact outer accept recognizes the kernel ipencap protocol spelling'
assert_contains "$(cat "$RUN_OUTPUT")" 'OUTER_IPIP_EXACT_ACCEPT=yes'
test_start 'first network is numbered in file order'
assert_contains "$output" 'NETWORK_1_IFACE=br0'
test_start 'second network is numbered in file order'
assert_contains "$output" 'NETWORK_2_IFACE=br10'
test_start 'BR route lookup was issued'
assert_contains "$calls" 'ip -6 route get 2001:db8:ffff::1'
test_start 'preferred global WAN address wins over deprecated address'
assert_contains "$output" 'WAN_GLOBAL_V6=2001:0db8:1234:0030:abcd:0000:0000:0001'
test_start 'PD candidates are normalized sorted and deduplicated'
assert_contains "$output" 'PD_PREFIX_1=2001:0db8:1234:0100:0000:0000:0000:0000/56
PD_PREFIX_2=2001:0db8:1234:0200:0000:0000:0000:0000/56'
test_start 'network link states are reported'
assert_contains "$output" 'NETWORK_1_LINK=up
NETWORK_2_IFACE=br10
NETWORK_2_CIDR=192.168.10.0/24
NETWORK_2_LINK=up'
test_start 'absent update state is neutral'
assert_contains "$output" 'LAST_UPDATE_LOCAL_V6=none
LAST_UPDATE_SUCCEEDED_AT=none
LAST_UPDATE_HTTP_CODE=none'
test_start 'skipped connectivity is stable'
assert_contains "$output" 'IPV4_CONNECTIVITY=skipped
IPV6_CONNECTIVITY=skipped'

test_start 'diagnostics issue no mutation command'
if grep -E ' (add|change|replace|set|del|-A|-I|-D|-F|-N|-X)( |$)' "$TMP/calls.log"; then
  fail 'mutation command observed'
else
  pass
fi

printf 'outside-original\n' >"$TMP/outside-full-output"
ln -s "$TMP/outside-full-output" "$TMP/full-output-link"
set +e
DIAG_SKIP_CONNECTIVITY=1 PATH=$DIAG_PATH STUB_LOG="$TMP/calls.log" \
  "$ROOT/scripts/v6plus-diag.sh" --config "$TMP/config" --full-output "$TMP/full-output-link" \
  >"$TMP/link-safe-output" 2>"$TMP/link-error"
link_status=$?
set -e
test_start 'full diagnostics rejects a symlink destination'
assert_eq "$link_status" 2
test_start 'full diagnostics never follows the symlink destination'
assert_eq "$(cat "$TMP/outside-full-output")" outside-original

expected_keys='DEPENDENCY_ip
DEPENDENCY_iptables
DEPENDENCY_ip6tables
DEPENDENCY_curl
DEPENDENCY_systemctl
UNIFI_OS_VERSION
UNIFI_NETWORK_VERSION
BR_ROUTE_DEV
WAN_IF
WAN_LINK
WAN_SPEED_MBIT
WAN_GLOBAL_V6
PD_PREFIX_1
PD_PREFIX_2
BR_ROUTE_SOURCE_V6
LOCAL_TUNNEL_V6
TUN_SELECTION
TUN_IF
TUN_EXISTS
TUN_LOCAL_V6
TUN_REMOTE_V6
TUN_IPV4
TUN_MTU
ROUTER_IPV4_ROUTE
NAT_CHAIN
V6_INPUT_CHAIN
OUTER_IPIP_EXACT_ACCEPT
ROUTE_TABLE_ENTRY_1
ROUTE_TABLE_ENTRY_2
POLICY_RULE_1
POLICY_RULE_2
NAT_RULE_1
MANGLE_RULE_1
LAST_UPDATE_LOCAL_V6
LAST_UPDATE_SUCCEEDED_AT
LAST_UPDATE_HTTP_CODE
IPV4_CONNECTIVITY
IPV6_CONNECTIVITY
NETWORK_1_IFACE
NETWORK_1_CIDR
NETWORK_1_LINK
NETWORK_2_IFACE
NETWORK_2_CIDR
NETWORK_2_LINK'
actual_keys=$(sed 's/=.*//' "$RUN_OUTPUT")
test_start 'stable keys are complete unique and ordered'
assert_eq "$actual_keys" "$expected_keys"

DIAG_SKIP_CONNECTIVITY=1 run_diag
test_start 'repeat collection has byte-stable output'
assert_eq "$(cat "$RUN_OUTPUT")" "$output"

printf '4.0.21\nfile-second-line-MUST-NOT-LEAK\n' >"$TMP/unifi-version"
DIAG_SKIP_CONNECTIVITY=1 DIAG_UBNT_MODE=fail V6PLUS_VERSION_FILE="$TMP/unifi-version" run_diag
test_start 'failed device-info falls back to injected version file'
assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_OS_VERSION=4.0.21'
test_start 'version fallback emits only the first file line'
assert_not_contains "$(cat "$RUN_OUTPUT")" 'file-second-line-MUST-NOT-LEAK'

DIAG_SKIP_CONNECTIVITY=1 DIAG_UBNT_MODE=empty V6PLUS_VERSION_FILE="$TMP/unifi-version" run_diag
test_start 'empty device-info falls back to version file'
assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_OS_VERSION=4.0.21'

version_drain_marker=$TMP/version-drained
DIAG_SKIP_CONNECTIVITY=1 DIAG_UBNT_MODE=multi \
  V6PLUS_VERSION_DRAIN_MARKER="$version_drain_marker" run_diag
test_start 'device-info first line is emitted'
assert_contains "$(cat "$RUN_OUTPUT")" 'UNIFI_OS_VERSION=4.1.13'
test_start 'version command is not consumed beyond its first line'
if [ -e "$version_drain_marker" ]; then
  fail 'device-info output was consumed through EOF'
else
  pass
fi

DIAG_SKIP_CONNECTIVITY=1 DIAG_WAN_DOWN=1 run_diag
test_start 'down WAN makes readiness fail'
assert_status 1
test_start 'down WAN is emitted explicitly'
assert_contains "$(cat "$RUN_OUTPUT")" 'WAN_LINK=down'

DIAG_SKIP_CONNECTIVITY=1 DIAG_NETWORK_DOWN=br10 run_diag
test_start 'down configured network makes readiness fail'
assert_status 1
test_start 'down configured network preserves stable file order'
assert_contains "$(cat "$RUN_OUTPUT")" 'NETWORK_1_IFACE=br0
NETWORK_1_CIDR=192.168.20.0/24
NETWORK_1_LINK=up
NETWORK_2_IFACE=br10
NETWORK_2_CIDR=192.168.10.0/24
NETWORK_2_LINK=down'

DIAG_SKIP_CONNECTIVITY=1 DIAG_NETWORK_MISSING=br10 run_diag
test_start 'missing configured network is readiness failure, not invalid config'
assert_status 1
test_start 'missing configured network remains in stable report order'
assert_contains "$(cat "$RUN_OUTPUT")" 'NETWORK_2_IFACE=br10
NETWORK_2_CIDR=192.168.10.0/24
NETWORK_2_LINK=missing'

DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_ABSENT=1 run_diag
test_start 'absent tunnel makes readiness fail'
assert_status 1
test_start 'absent tunnel is explicit'
assert_contains "$(cat "$RUN_OUTPUT")" 'TUN_EXISTS=no'

DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_WRONG_MODE=1 run_diag
test_start 'wrong tunnel mode makes readiness fail'
assert_status 1
test_start 'wrong-mode tunnel still emits discovered state'
assert_contains "$(cat "$RUN_OUTPUT")" 'TUN_EXISTS=yes
TUN_LOCAL_V6=2001:db8:1234:30:cb:71:2a00:0
TUN_REMOTE_V6=2001:db8:ffff::1
TUN_IPV4=203.0.113.42
TUN_MTU=1460'

DIAG_SKIP_CONNECTIVITY=1 DIAG_NO_GLOBAL_V6=1 run_diag
test_start 'missing preferred global WAN IPv6 makes readiness fail'
assert_status 1
test_start 'missing preferred global WAN IPv6 is explicit'
assert_contains "$(cat "$RUN_OUTPUT")" 'WAN_GLOBAL_V6=none'

DIAG_SKIP_CONNECTIVITY=1 DIAG_ZERO_PREFERRED_ONLY=1 run_diag
test_start 'zero preferred lifetime makes readiness fail'
assert_status 1
test_start 'zero preferred lifetime is not treated as preferred'
assert_contains "$(cat "$RUN_OUTPUT")" 'WAN_GLOBAL_V6=none'

DIAG_SKIP_CONNECTIVITY=1 DIAG_NO_ROUTE_SOURCE=1 run_diag
test_start 'missing route-selected source makes readiness fail'
assert_status 1
test_start 'missing route-selected source is explicit'
assert_contains "$(cat "$RUN_OUTPUT")" 'BR_ROUTE_SOURCE_V6=none'

DIAG_SKIP_CONNECTIVITY=1 DIAG_NO_PD=1 run_diag
test_start 'absence of PD candidates is diagnostic only'
assert_status 0
test_start 'absence of PD candidates has stable placeholder'
assert_contains "$(cat "$RUN_OUTPUT")" 'PD_PREFIX_1=unknown'
test_start 'PD absence does not alter composed endpoint'
assert_contains "$(cat "$RUN_OUTPUT")" 'LOCAL_TUNNEL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000'

DIAG_SKIP_CONNECTIVITY=1 DIAG_FALLBACK_CHAINS=1 run_diag
test_start 'missing UniFi chains fall back without creation'
assert_contains "$(cat "$RUN_OUTPUT")" 'NAT_CHAIN=POSTROUTING
V6_INPUT_CHAIN=INPUT'
test_start 'fallback probes remain list-only'
if grep -E ' (-A|-I|-D|-F|-N|-X)( |$)' "$TMP/calls.log"; then
  fail 'firewall mutation observed'
else
  pass
fi

DIAG_SKIP_CONNECTIVITY=1 DIAG_OUTER_NEGATED=1 run_diag
test_start 'negated outer rule is not an exact accept'
assert_contains "$(cat "$RUN_OUTPUT")" 'OUTER_IPIP_EXACT_ACCEPT=no'

DIAG_SKIP_CONNECTIVITY=1 DIAG_OUTER_EXTRA=1 run_diag
test_start 'outer rule with extra restriction is not exact'
assert_contains "$(cat "$RUN_OUTPUT")" 'OUTER_IPIP_EXACT_ACCEPT=no'

DIAG_SKIP_CONNECTIVITY=1 DIAG_OUTER_UNTAGGED=1 run_diag
test_start 'otherwise exact untagged outer accept is recognized'
assert_contains "$(cat "$RUN_OUTPUT")" 'OUTER_IPIP_EXACT_ACCEPT=yes'

DIAG_SKIP_CONNECTIVITY=1 DIAG_OUTER_APPROVED_TAG=1 run_diag
test_start 'Task 5 approved tagged outer accept is recognized'
assert_contains "$(cat "$RUN_OUTPUT")" 'OUTER_IPIP_EXACT_ACCEPT=yes'

DIAG_SKIP_CONNECTIVITY=1 DIAG_OUTER_ARBITRARY_COMMENT=1 run_diag
test_start 'arbitrary outer-rule comment is not approved metadata'
assert_contains "$(cat "$RUN_OUTPUT")" 'OUTER_IPIP_EXACT_ACCEPT=no'

DIAG_SKIP_CONNECTIVITY=1 DIAG_SNAPSHOT_SECRETS=1 run_diag
snapshot_output=$(cat "$RUN_OUTPUT")
test_start 'route and firewall snapshot credentials are redacted'
assert_not_contains "$snapshot_output" 'MUST-NOT-LEAK'
test_start 'route snapshot visibly records redaction'
assert_contains "$snapshot_output" 'ROUTE_TABLE_ENTRY_3=198.51.100.1 dev eth8 note UPDATE_PASSWORD=[REDACTED]'
test_start 'firewall snapshot visibly redacts URL credentials'
assert_contains "$snapshot_output" 'MANGLE_RULE_2=-A UBIOS_FORWARD_IN_USER -m comment --comment v6plus:redact?user=[REDACTED]&pass=[REDACTED]'

cat >"$STATE/last-update.env" <<'EOF'
LOCAL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000
SUCCEEDED_AT=1700000000
HTTP_CODE=200
EOF
chmod 600 "$STATE/last-update.env"
cat >"$TMP/config/last-update.env" <<'EOF'
LOCAL_V6=2001:0db8:ffff:ffff:ffff:ffff:ffff:ffff
SUCCEEDED_AT=1
HTTP_CODE=599
UPDATE_PASSWORD=state-password-MUST-NOT-LEAK
EOF
cat >"$TMP/config/update.env" <<'EOF'
UPDATE_URL=https://update.example.invalid/?user=url-user-MUST-NOT-LEAK&pass=url-pass-MUST-NOT-LEAK
UPDATE_USERNAME=config-user-MUST-NOT-LEAK
UPDATE_PASSWORD=$(touch update-env-executed)
EOF
DIAG_SKIP_CONNECTIVITY=1 run_diag
state_output=$(cat "$RUN_OUTPUT")
test_start 'safe update state fields are parsed as data'
assert_contains "$state_output" 'LAST_UPDATE_LOCAL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000
LAST_UPDATE_SUCCEEDED_AT=1700000000
LAST_UPDATE_HTTP_CODE=200'
test_start 'diagnostics ignores unrelated config-directory state'
assert_not_contains "$state_output" '2001:0db8:ffff:ffff:ffff:ffff:ffff:ffff'
test_start 'credential fields from state and update config never leak'
assert_not_contains "$state_output$(cat "$RUN_ERROR")" 'MUST-NOT-LEAK'
test_start 'update config is never executed'
if [ -e "$TMP/config/update-env-executed" ] || [ -e update-env-executed ]; then
  fail 'update.env command substitution executed'
else
  pass
fi

cat >"$STATE/last-update.env" <<'EOF'
LOCAL_V6=$(touch last-state-executed)
SUCCEEDED_AT=bad value
HTTP_CODE=secret-code
EOF
chmod 600 "$STATE/last-update.env"
DIAG_SKIP_CONNECTIVITY=1 run_diag
test_start 'unsafe optional state values degrade to none without failure'
assert_status 0
test_start 'unsafe optional state is not evaluated or printed'
assert_contains "$(cat "$RUN_OUTPUT")" 'LAST_UPDATE_LOCAL_V6=none
LAST_UPDATE_SUCCEEDED_AT=none
LAST_UPDATE_HTTP_CODE=none'
test_start 'state command substitution is never executed'
if [ -e "$TMP/config/last-state-executed" ] || [ -e last-state-executed ]; then
  fail 'last-update.env command substitution executed'
else
  pass
fi
rm -f "$STATE/last-update.env" "$TMP/config/last-update.env"

DIAG_SKIP_CONNECTIVITY=0 run_diag
connectivity_output=$(cat "$RUN_OUTPUT")
test_start 'bounded connectivity success maps to ok'
assert_contains "$connectivity_output" 'IPV4_CONNECTIVITY=ok
IPV6_CONNECTIVITY=ok'
test_start 'IPv4 connectivity curl is exact and bounded'
assert_contains "$(cat "$TMP/calls.log")" 'curl -4 --silent --show-error --fail --max-time 5 https://connectivitycheck.gstatic.com/generate_204'
test_start 'IPv6 connectivity curl is exact and bounded'
assert_contains "$(cat "$TMP/calls.log")" 'curl -6 --silent --show-error --fail --max-time 5 https://connectivitycheck.gstatic.com/generate_204'
test_start 'connectivity response body and credentials never leak'
assert_not_contains "$connectivity_output$(cat "$RUN_ERROR")" 'MUST-NOT-LEAK'

DIAG_SKIP_CONNECTIVITY=0 DIAG_CURL6_FAIL=1 run_diag
test_start 'connectivity failure makes readiness fail'
assert_status 1
test_start 'connectivity success and failure map independently'
assert_contains "$(cat "$RUN_OUTPUT")" 'IPV4_CONNECTIVITY=ok
IPV6_CONNECTIVITY=failed'

cp "$ROOT/tests/stubs/diag/ip" "$TMP/missing-bin/ip"
cp "$ROOT/tests/stubs/diag/iptables" "$TMP/missing-bin/iptables"
cp "$ROOT/tests/stubs/diag/curl" "$TMP/missing-bin/curl"
cp "$ROOT/tests/stubs/diag/curl" "$TMP/missing-bin/systemctl"
if command -v gstat >/dev/null 2>&1; then
  cp "$(command -v gstat)" "$TMP/missing-bin/stat"
else
  cp "$(command -v stat)" "$TMP/missing-bin/stat"
fi
chmod +x "$TMP/missing-bin"/*
: >"$TMP/calls.log"
set +e
PATH=$TMP/missing-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
  STUB_LOG="$TMP/calls.log" DIAG_SKIP_CONNECTIVITY=1 \
  "$ROOT/scripts/v6plus-diag.sh" --config "$TMP/config" --full-output "$TMP/missing-output" \
  >"$TMP/missing-safe-output" 2>"$TMP/missing-error"
missing_status=$?
set -e
test_start 'missing required dependency makes readiness fail'
assert_eq "$missing_status" 1
test_start 'every dependency status is emitted when one is missing'
assert_contains "$(cat "$TMP/missing-output")" 'DEPENDENCY_ip=ok
DEPENDENCY_iptables=ok
DEPENDENCY_ip6tables=missing
DEPENDENCY_curl=ok
DEPENDENCY_systemctl=ok'

cp "$TMP/config/v6plus.env" "$TMP/config/v6plus.env.ready"
sed -e 's/WAN_IF=eth9/WAN_IF=replace-with-route-device/' -e '/^TUN_IF=/d' \
  "$TMP/config/v6plus.env.ready" >"$TMP/config/v6plus.env"
printf 'not valid networks data at all\n' >"$TMP/config/networks.conf"
DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_LIST_MODE=single run_diag --discover
discover_output=$(cat "$RUN_OUTPUT")
test_start 'discover mode succeeds before networks are finalized'
assert_status 0
test_start 'discover derives candidate WAN device from BR route'
assert_contains "$discover_output" 'BR_ROUTE_DEV=eth9
WAN_IF=eth9'
test_start 'discover derives and composes route-selected endpoint'
assert_contains "$discover_output" 'BR_ROUTE_SOURCE_V6=2001:0db8:1234:0030:abcd:0000:0000:0001
LOCAL_TUNNEL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000'
test_start 'discover selects the unique ipip6 tunnel whose remote matches BR'
assert_contains "$discover_output" 'TUN_SELECTION=br-remote-match
TUN_IF=ip6tnl7
TUN_EXISTS=yes'
test_start 'discover emits stable network placeholder'
assert_contains "$discover_output" 'NETWORK_1_IFACE=none
NETWORK_1_CIDR=none
NETWORK_1_LINK=none'
test_start 'discover mode remains mutation-free'
if grep -E ' (add|change|replace|set|del|-A|-I|-D|-F|-N|-X)( |$)' "$TMP/calls.log"; then
  fail 'mutation command observed'
else
  pass
fi

DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_LIST_MODE=native-any run_diag --discover
test_start 'discover selects UniFi native any-over-IPv6 tunnel by BR before apply'
assert_status 1
test_start 'native tunnel remains visible while readiness waits for ipip6 mode'
assert_contains "$(cat "$RUN_OUTPUT")" 'TUN_SELECTION=br-remote-match
TUN_IF=ip6tnl3
TUN_EXISTS=yes'

DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_LIST_MODE=post-apply run_diag --discover
test_start 'discover accepts Linux ip-over-IPv6 display mode after apply'
assert_status 0
test_start 'post-apply Linux mode keeps the BR-matched tunnel ready'
assert_contains "$(cat "$RUN_OUTPUT")" 'TUN_SELECTION=br-remote-match
TUN_IF=ip6tnl3
TUN_EXISTS=yes'

DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_LIST_MODE=multiple run_diag --discover
test_start 'discover rejects ambiguous BR-matching tunnels'
assert_status 1
test_start 'ambiguous discovery does not guess a tunnel interface'
assert_contains "$(cat "$RUN_OUTPUT")" 'TUN_SELECTION=ambiguous
TUN_IF=none
TUN_EXISTS=no'

DIAG_SKIP_CONNECTIVITY=1 DIAG_TUNNEL_LIST_MODE=none run_diag --discover
test_start 'discover reports no BR-matching tunnel as not ready'
assert_status 1
test_start 'no-match discovery has stable explicit placeholders'
assert_contains "$(cat "$RUN_OUTPUT")" 'TUN_SELECTION=none
TUN_IF=none
TUN_EXISTS=no'

mv "$TMP/config/v6plus.env.ready" "$TMP/config/v6plus.env"
printf 'br0 192.168.20.0/99\n' >"$TMP/config/networks.conf"
DIAG_SKIP_CONNECTIVITY=1 run_diag
test_start 'invalid full configuration exits 2'
assert_status 2

set +e
PATH=$DIAG_PATH STUB_LOG="$TMP/calls.log" "$ROOT/scripts/v6plus-diag.sh" --bogus >"$TMP/arg-output" 2>"$TMP/arg-error"
arg_status=$?
set -e
test_start 'invalid arguments exit 2'
assert_eq "$arg_status" 2

test_finish
