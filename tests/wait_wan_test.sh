#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

WAIT_SCRIPT=$ROOT/scripts/v6plus-wait-wan.sh
test_start 'WAN readiness executable exists'
if [ -x "$WAIT_SCRIPT" ]; then
  pass
else
  fail "missing executable $WAIT_SCRIPT"
  test_finish
fi

TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/v6plus-wait-wan-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

WAIT_PATH=$ROOT/tests/stubs/wait:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/usr/bin:/bin
export V6PLUS_ROOT=$ROOT
export V6PLUS_LIB=$ROOT/scripts/v6plus-lib.sh

write_config() {
  cat >"$CONFIG/v6plus.env" <<'EOF'
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
  printf '%s\n' 'br0 192.168.20.0/24' >"$CONFIG/networks.conf"
}

write_non_documentation_config() {
  cat >"$CONFIG/v6plus.env" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
STATIC_V4=8.8.8.8
BR_V6=2400:abcd:ffff::1
IID=00cb:0071:2a00:0000
TUN_MTU=1460
TCP_MSS=1420
ROUTE_TABLE=300
RULE_PREF_BASE=10000
WATCH_INTERVAL_SECONDS=5
UPDATE_INTERVAL_SECONDS=600
OUTER_IPIP_ALLOW=auto
EOF
  printf '%s\n' 'br0 192.168.20.0/24' >"$CONFIG/networks.conf"
}

new_case() {
  CASE=$TMP/$1
  CONFIG=$CASE/config
  WAIT_ROUND_FILE=$CASE/round
  WAIT_IP_LOG=$CASE/ip.log
  WAIT_EXTERNAL_LOG=$CASE/external.log
  WAIT_SLEEP_LOG=$CASE/sleep.log
  WAIT_CLOCK_LOG=$CASE/clock.log
  WAIT_NOW_VALUES_FILE=$CASE/now.values
  WAIT_NOW_CALL_FILE=$CASE/now.call
  mkdir -p "$CONFIG"
  printf '%s\n' 1 >"$WAIT_ROUND_FILE"
  : >"$WAIT_IP_LOG"
  : >"$WAIT_EXTERNAL_LOG"
  : >"$WAIT_SLEEP_LOG"
  : >"$WAIT_CLOCK_LOG"
  printf '%s\n' 0 >"$WAIT_NOW_CALL_FILE"
  write_config

  WAIT_READY_ROUND=3
  WAIT_LINK_STYLE=up
  WAIT_ADDR_STYLE=preferred
  WAIT_ADDR_SOURCE=2001:db8:1234:30:abcd::1
  WAIT_OTHER_SOURCE=2001:db8:1234:30:cafe::1
  WAIT_DEFAULT_DEV=eth9
  WAIT_TUN_MODE=ipip6
  WAIT_BR_STYLE=normal
  WAIT_BR_DESTINATION=2001:db8:ffff::1
  WAIT_ROUTE_SOURCE=2001:db8:1234:30:abcd::1
  write_clock 0 0 0 1 1 2 2

  V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
  V6PLUS_ALLOW_NONROOT=1

  V6_IP_CMD=ip
  V6_IPTABLES_CMD=iptables
  V6_IP6TABLES_CMD=ip6tables
  V6_IPTABLES_SAVE_CMD=iptables-save
  V6_IP6TABLES_SAVE_CMD=ip6tables-save
  V6_CURL_CMD=curl
  V6_SYSTEMCTL_CMD=systemctl
  V6_SLEEP_CMD=sleep
  V6PLUS_NOW_CMD=now

  export CASE CONFIG WAIT_ROUND_FILE WAIT_IP_LOG WAIT_EXTERNAL_LOG WAIT_SLEEP_LOG WAIT_CLOCK_LOG
  export WAIT_NOW_VALUES_FILE WAIT_NOW_CALL_FILE
  export WAIT_READY_ROUND WAIT_LINK_STYLE WAIT_ADDR_STYLE WAIT_ADDR_SOURCE WAIT_OTHER_SOURCE
  export WAIT_DEFAULT_DEV WAIT_TUN_MODE WAIT_BR_STYLE WAIT_BR_DESTINATION WAIT_ROUTE_SOURCE
  export V6_IP_CMD V6_IPTABLES_CMD V6_IP6TABLES_CMD V6_IPTABLES_SAVE_CMD
  export V6_IP6TABLES_SAVE_CMD V6_CURL_CMD V6_SYSTEMCTL_CMD V6_SLEEP_CMD
  export V6PLUS_NOW_CMD V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES V6PLUS_ALLOW_NONROOT
}

write_clock() {
  : >"$WAIT_NOW_VALUES_FILE"
  for clock_value in "$@"; do printf '%s\n' "$clock_value" >>"$WAIT_NOW_VALUES_FILE"; done
  printf '%s\n' 0 >"$WAIT_NOW_CALL_FILE"
}

run_wait() {
  RUN_OUTPUT=$CASE/stdout
  RUN_ERROR=$CASE/stderr
  : >"$RUN_OUTPUT"
  : >"$RUN_ERROR"
  set +e
  PATH=$WAIT_PATH "$WAIT_SCRIPT" --config "$CONFIG" "$@" >"$RUN_OUTPUT" 2>"$RUN_ERROR"
  RUN_STATUS=$?
  set -e
}

assert_run_status() {
  test_start "$1"
  assert_eq "$RUN_STATUS" "$2"
}

assert_no_mutation() {
  test_start "$1"
  if grep -E '(^|[[:space:]])(add|change|replace|set|del|-A|-I|-R|-D|-F|-Z|-N|-X|-P|-E|--append|--insert|--replace|--delete|--flush|--zero|--new-chain|--delete-chain|--policy|--rename-chain|start|restart|stop|enable|disable)([[:space:]]|$)' \
      "$WAIT_IP_LOG" "$WAIT_EXTERNAL_LOG" >/dev/null 2>&1; then
    fail "mutation command observed: $(cat "$WAIT_IP_LOG" "$WAIT_EXTERNAL_LOG")"
  else
    pass
  fi
}

assert_process_logs_hide_addresses() {
  test_start "$1"
  if grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}|([[:xdigit:]]{0,4}:){2,}[[:xdigit:]:]*' \
      "$RUN_OUTPUT" "$RUN_ERROR" >/dev/null 2>&1; then
    fail "address found in process log: $(cat "$RUN_OUTPUT" "$RUN_ERROR")"
  else
    pass
  fi
}

readiness_probe_count() {
  grep -c ' ip -o link show dev eth9$' "$WAIT_IP_LOG" 2>/dev/null || true
}

new_case transition
run_wait --timeout 9
assert_run_status 'readiness succeeds when the third polling round becomes ready' 0
test_start 'exactly two one-second sleeps lead to round three'
assert_eq "$(cat "$WAIT_ROUND_FILE")" 3
calls=$(cat "$WAIT_IP_LOG")
test_start 'each polling round checks WAN link state'
assert_contains "$calls" 'round=3 ip -o link show dev eth9'
test_start 'the first polling round is inspected'
assert_contains "$calls" 'round=1 ip -o link show dev eth9'
test_start 'the second polling round is inspected'
assert_contains "$calls" 'round=2 ip -o link show dev eth9'
test_start 'each polling round checks preferred global WAN IPv6'
assert_contains "$calls" 'round=3 ip -6 addr show dev eth9 scope global'
test_start 'each polling round checks the IPv6 default route'
assert_contains "$calls" 'round=3 ip -6 route show default'
test_start 'each polling round checks the configured ipip6 tunnel'
assert_contains "$calls" 'round=3 ip -d -6 tunnel show ip6tnl1'
test_start 'each polling round checks BR route dev and src data'
assert_contains "$calls" 'round=3 ip -6 route get 2001:db8:ffff::1'
for probe_round in 1 2 3; do
  test_start "WAN address snapshot is captured exactly once in round $probe_round"
  assert_eq "$(grep -c "round=$probe_round ip -6 addr show dev eth9 scope global" "$WAIT_IP_LOG" || true)" 1
  test_start "IPv6 default route is captured exactly once in round $probe_round"
  assert_eq "$(grep -c "round=$probe_round ip -6 route show default" "$WAIT_IP_LOG" || true)" 1
  test_start "configured tunnel is captured exactly once in round $probe_round"
  assert_eq "$(grep -c "round=$probe_round ip -d -6 tunnel show ip6tnl1" "$WAIT_IP_LOG" || true)" 1
  test_start "BR route is captured exactly once in round $probe_round"
  assert_eq "$(grep -c "round=$probe_round ip -6 route get 2001:db8:ffff::1" "$WAIT_IP_LOG" || true)" 1
done
test_start 'unchanged missing prerequisites are logged once before success'
assert_eq "$(grep -c 'readiness missing=' "$RUN_ERROR" || true)" 1
test_start 'successful readiness is logged once'
assert_eq "$(grep -c 'readiness ready ' "$RUN_ERROR" || true)" 1
assert_no_mutation 'readiness transition issues no mutation command'
assert_process_logs_hide_addresses 'readiness transition logs contain no fixture address'

new_case timeout
WAIT_READY_ROUND=99
export WAIT_READY_ROUND
write_clock 0 0 0 3 3 6 6 9
run_wait --timeout 9
assert_run_status 'deadline returns runtime failure' 1
test_start 'timeout never sleeps or polls past the monotonic deadline'
assert_eq "$(cat "$WAIT_ROUND_FILE")" 4
test_start 'no readiness command is issued at the deadline round'
if grep -F 'round=4 ip ' "$WAIT_IP_LOG" >/dev/null 2>&1; then
  fail 'polling continued at the deadline'
else
  pass
fi
test_start 'injected monotonic clock reaches the exact deadline'
assert_contains "$(cat "$WAIT_CLOCK_LOG")" 'call=8 now=9'
test_start 'timeout reports the final missing prerequisite set'
assert_contains "$(cat "$RUN_ERROR")" 'readiness timeout=9 missing=wan_global_v6,wan_default_route,tunnel_ipip6,br_route_source'
test_start 'unchanged timeout missing set is not logged every round'
assert_eq "$(grep -c 'readiness missing=' "$RUN_ERROR" || true)" 1
assert_no_mutation 'timeout path issues no mutation command'
assert_process_logs_hide_addresses 'timeout logs contain no fixture address'

new_case zero-timeout
WAIT_READY_ROUND=1
export WAIT_READY_ROUND
write_clock 0 0
run_wait --timeout 0
assert_run_status 'zero timeout reaches the deadline before any readiness probe' 1
test_start 'zero timeout performs zero readiness probes'
assert_eq "$(readiness_probe_count)" 0
test_start 'zero timeout reports that no snapshot was taken'
assert_contains "$(cat "$RUN_ERROR")" 'readiness timeout=0 missing=not_polled'

new_case first-probe-deadline
WAIT_READY_ROUND=1
export WAIT_READY_ROUND
write_clock 0 9
run_wait --timeout 9
assert_run_status 'deadline reached before the first snapshot returns timeout' 1
test_start 'deadline reached before the first snapshot performs zero probes'
assert_eq "$(readiness_probe_count)" 0

new_case probe-crosses-deadline
WAIT_READY_ROUND=1
export WAIT_READY_ROUND
write_clock 0 0 9
run_wait --timeout 9
assert_run_status 'ready snapshot finishing at the deadline is rejected' 1
test_start 'deadline-crossing snapshot is probed exactly once'
assert_eq "$(readiness_probe_count)" 1
test_start 'deadline-crossing snapshot is never logged ready'
assert_eq "$(grep -c 'readiness ready ' "$RUN_ERROR" || true)" 0
test_start 'deadline-crossing ready snapshot reports no missing prerequisite'
assert_contains "$(cat "$RUN_ERROR")" 'readiness timeout=9 missing=none'

new_case lower-up
WAIT_READY_ROUND=1
WAIT_LINK_STYLE=lower
export WAIT_READY_ROUND WAIT_LINK_STYLE
run_wait --timeout 1
assert_run_status 'LOWER_UP satisfies the WAN link prerequisite' 0

for compatible_tunnel_mode in 'any/ipv6' 'ip/ipv6'; do
  new_case "compatible-tunnel-$(printf '%s' "$compatible_tunnel_mode" | tr '/' '-')"
  WAIT_READY_ROUND=1
  WAIT_TUN_MODE=$compatible_tunnel_mode
  export WAIT_READY_ROUND WAIT_TUN_MODE
  write_clock 0 0 0 1
  run_wait --timeout 1
  assert_run_status "Linux tunnel display mode <$compatible_tunnel_mode> satisfies readiness" 0
  assert_no_mutation "Linux tunnel display mode <$compatible_tunnel_mode> readiness is read-only"
done

new_case rfc3849-source-production
write_non_documentation_config
WAIT_READY_ROUND=1
WAIT_BR_DESTINATION=2400:abcd:ffff::1
WAIT_ADDR_SOURCE=2001:0db8:1234:0030:abcd::1
WAIT_ROUTE_SOURCE=2001:0db8:1234:0030:abcd::1
export WAIT_READY_ROUND WAIT_BR_DESTINATION WAIT_ADDR_SOURCE WAIT_ROUTE_SOURCE
unset V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'production mode rejects an RFC 3849 preferred route source' 1
test_start 'RFC 3849 route source is identified without invalidating non-documentation config'
assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'
test_start 'RFC 3849 route source never reaches a ready log'
assert_eq "$(grep -c 'readiness ready ' "$RUN_ERROR" || true)" 0
assert_process_logs_hide_addresses 'RFC 3849 rejection logs contain no fixture address'
assert_no_mutation 'RFC 3849 rejection issues no mutation command'
V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES

new_case rfc3849-source-explicit-override
WAIT_READY_ROUND=1
V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export WAIT_READY_ROUND V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'exact documentation-address override accepts an RFC 3849 readiness fixture' 0
assert_process_logs_hide_addresses 'RFC 3849 override success logs contain no fixture address'
assert_no_mutation 'RFC 3849 override success issues no mutation command'

new_case tentative
WAIT_READY_ROUND=1
WAIT_ADDR_STYLE=tentative-only
export WAIT_READY_ROUND WAIT_ADDR_STYLE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'tentative-only global IPv6 does not satisfy readiness' 1
test_start 'tentative-only address is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=wan_global_v6'

new_case deprecated
WAIT_READY_ROUND=1
WAIT_ADDR_STYLE=deprecated-only
export WAIT_READY_ROUND WAIT_ADDR_STYLE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'zero preferred lifetime does not satisfy readiness' 1
test_start 'deprecated address is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=wan_global_v6'

new_case wrong-default-device
WAIT_READY_ROUND=1
WAIT_DEFAULT_DEV=br0
export WAIT_READY_ROUND WAIT_DEFAULT_DEV
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'default route on a non-WAN device fails readiness' 1
test_start 'wrong default-route device is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=wan_default_route'

new_case wrong-tunnel-mode
WAIT_READY_ROUND=1
WAIT_TUN_MODE=gre6
export WAIT_READY_ROUND WAIT_TUN_MODE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'non-ipip6 tunnel mode fails readiness' 1
test_start 'wrong tunnel mode is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=tunnel_ipip6'

new_case missing-route-source
WAIT_READY_ROUND=1
WAIT_BR_STYLE=no-source
export WAIT_READY_ROUND WAIT_BR_STYLE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'BR route without src fails readiness' 1
test_start 'missing BR route source is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'

new_case wrong-br-device
WAIT_READY_ROUND=1
WAIT_BR_STYLE=wrong-device
export WAIT_READY_ROUND WAIT_BR_STYLE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'BR route on a non-WAN device fails readiness' 1
test_start 'wrong BR route device is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'

new_case wrong-br-source-address
WAIT_READY_ROUND=1
WAIT_ROUTE_SOURCE=2001:db8:1234:30:beef::1
export WAIT_READY_ROUND WAIT_ROUTE_SOURCE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'BR source absent from the preferred WAN snapshot fails readiness' 1
test_start 'wrong BR source address is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'

for source_state in tentative deprecated; do
  new_case "route-source-$source_state"
  WAIT_READY_ROUND=1
  WAIT_ADDR_STYLE=$source_state
  export WAIT_READY_ROUND WAIT_ADDR_STYLE
  write_clock 0 0 0 1
  run_wait --timeout 1
  assert_run_status "BR source that is $source_state on WAN fails readiness" 1
  test_start "$source_state BR source is identified in the missing set"
  assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'
done

for bad_source in '::' '::1' 'fe80::1' 'ff02::1' 'fd00::1'; do
  new_case "non-global-$(printf '%s' "$bad_source" | tr ':' '_')"
  WAIT_READY_ROUND=1
  WAIT_ROUTE_SOURCE=$bad_source
  WAIT_ADDR_SOURCE=$bad_source
  export WAIT_READY_ROUND WAIT_ROUTE_SOURCE WAIT_ADDR_SOURCE
  write_clock 0 0 0 1
  run_wait --timeout 1
  assert_run_status "non-global BR source <$bad_source> fails readiness" 1
  test_start "non-global BR source <$bad_source> is identified in the missing set"
  assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'
  test_start "non-global BR source <$bad_source> is absent from process logs"
  if grep -F "$bad_source" "$RUN_OUTPUT" "$RUN_ERROR" >/dev/null 2>&1; then fail 'source address leaked'; else pass; fi
done

new_case multi-record-splice
WAIT_READY_ROUND=1
WAIT_BR_STYLE=split
export WAIT_READY_ROUND WAIT_BR_STYLE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'dev and src from different route records cannot be spliced' 1
test_start 'multi-record route output is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'

new_case route-churn
WAIT_READY_ROUND=1
WAIT_BR_STYLE=churn
export WAIT_READY_ROUND WAIT_BR_STYLE
write_clock 0 0 0 1
run_wait --timeout 1
assert_run_status 'route output churn cannot compose two snapshots' 1
test_start 'route churn uses exactly one route query in the snapshot'
assert_eq "$(grep -c 'round=1 ip -6 route get 2001:db8:ffff::1' "$WAIT_IP_LOG" || true)" 1
test_start 'route churn is identified in the missing set'
assert_contains "$(cat "$RUN_ERROR")" 'missing=br_route_source'
assert_process_logs_hide_addresses 'route validation failures log no fixture address'

for bad_timeout in invalid -1; do
  new_case "bad-timeout-$bad_timeout"
  run_wait --timeout "$bad_timeout"
  assert_run_status "timeout <$bad_timeout> is a usage error" 2
  test_start "timeout <$bad_timeout> is rejected before readiness inspection"
  assert_eq "$(cat "$WAIT_IP_LOG")" ''
done

set_missing_dependency() {
  case $1 in
    ip) V6_IP_CMD=v6plus-missing-ip ;;
    iptables) V6_IPTABLES_CMD=v6plus-missing-iptables ;;
    ip6tables) V6_IP6TABLES_CMD=v6plus-missing-ip6tables ;;
    iptables-save) V6_IPTABLES_SAVE_CMD=v6plus-missing-iptables-save ;;
    ip6tables-save) V6_IP6TABLES_SAVE_CMD=v6plus-missing-ip6tables-save ;;
    curl) V6_CURL_CMD=v6plus-missing-curl ;;
    systemctl) V6_SYSTEMCTL_CMD=v6plus-missing-systemctl ;;
    sleep) V6_SLEEP_CMD=v6plus-missing-sleep ;;
  esac
  export V6_IP_CMD V6_IPTABLES_CMD V6_IP6TABLES_CMD V6_IPTABLES_SAVE_CMD
  export V6_IP6TABLES_SAVE_CMD V6_CURL_CMD V6_SYSTEMCTL_CMD V6_SLEEP_CMD
}

for dependency in ip iptables ip6tables iptables-save ip6tables-save curl systemctl sleep; do
  new_case "missing-$dependency"
  set_missing_dependency "$dependency"
  run_wait --timeout 9
  assert_run_status "missing $dependency fails closed" 1
  test_start "missing $dependency is reported"
  assert_contains "$(cat "$RUN_ERROR")" "missing_dependencies=$dependency"
  test_start "missing $dependency is detected before readiness inspection"
  assert_eq "$(cat "$WAIT_IP_LOG")" ''
done

test_finish
