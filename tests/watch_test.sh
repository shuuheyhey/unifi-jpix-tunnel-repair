#!/bin/sh
set -u
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

SCRIPT=$ROOT/scripts/unifi-jpix-tunnel-repair-watch.sh
STUB=$ROOT/tests/stubs/runtime
TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/unifi-jpix-tunnel-repair-watch-test.$$
OLD_ENDPOINT=2001:0db8:1234:0030:00cb:0071:2a00:0000
NEW_ENDPOINT=2001:0db8:1234:0031:00cb:0071:2a00:0000
SECRET_SENTINEL='watch-secret-user:p&a ss%word'
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

test_start 'watchdog executable exists'
if [ -x "$SCRIPT" ]; then
  pass
else
  fail "missing executable $SCRIPT"
  test_finish
fi

write_last_apply() {
  endpoint=$1
  mode=${2:-600}
  {
    printf 'LOCAL_V6=%s\n' "$endpoint"
    printf 'NAT_CHAIN=POSTROUTING\n'
    printf 'V6_INPUT_CHAIN=none\n'
    printf 'V6_INPUT_MANAGED=no\n'
    printf 'APPLIED_AT=1700000000\n'
  } >"$V6PLUS_STATE_DIR/last-apply.env"
  chmod "$mode" "$V6PLUS_STATE_DIR/last-apply.env"
}

new_case() {
  CASE=$TMP/$1
  mkdir -p "$CASE/config" "$CASE/state"
  chmod 700 "$CASE/config" "$CASE/state"
  cat >"$CASE/config/gateway.conf" <<'EOF'
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
  printf 'br0 192.168.20.0/24\nbr10 192.168.10.0/24\n' >"$CASE/config/routed-networks.conf"
  printf 'UPDATE_URL=https://updates.example.invalid/path\nUPDATE_USERNAME=%s\nUPDATE_PASSWORD=%s\nALLOW_INSECURE_UPDATE_HTTP=no\nINSECURE_UPDATE_HTTP_HOST=\n' \
    "$SECRET_SENTINEL" "$SECRET_SENTINEL" >"$CASE/config/provider-update.conf"
  chmod 600 "$CASE/config/provider-update.conf"
  : >"$CASE/apply.log"
  : >"$CASE/update.log"
  : >"$CASE/sleep.log"
  : >"$CASE/logger.log"
  : >"$CASE/child-env.log"
  : >"$CASE/status.count"
  : >"$CASE/apply.count"
  : >"$CASE/status-sequence"
  : >"$CASE/apply-sequence"
  : >"$CASE/status-output"
  : >"$CASE/status-error"
  : >"$CASE/status-name-sequence"
  : >"$CASE/apply-time.log"
  printf '0\n' >"$CASE/clock"
  printf '%s\n' "$OLD_ENDPOINT" >"$CASE/apply-endpoint"

  V6PLUS_LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh
  V6PLUS_STATE_DIR=$CASE/state
  V6PLUS_LOCK_DIR=$CASE/lock
  V6_IP_CMD=$STUB/ip
  V6PLUS_APPLY_CMD=$STUB/apply
  V6PLUS_UPDATE_CMD=$STUB/update
  V6_SLEEP_CMD=$STUB/sleep
  V6PLUS_NOW_CMD=$STUB/now
  V6PLUS_ALLOW_NONROOT=1
  V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
  RUNTIME_APPLY_LOG=$CASE/apply.log
  RUNTIME_UPDATE_LOG=$CASE/update.log
  RUNTIME_SLEEP_LOG=$CASE/sleep.log
  RUNTIME_LOGGER_LOG=$CASE/logger.log
  RUNTIME_CHILD_ENV_LOG=$CASE/child-env.log
  RUNTIME_STATUS_COUNTER=$CASE/status.count
  RUNTIME_APPLY_COUNTER=$CASE/apply.count
  RUNTIME_STATUS_SEQUENCE=$CASE/status-sequence
  RUNTIME_APPLY_SEQUENCE=$CASE/apply-sequence
  RUNTIME_STATUS_PAYLOAD=$CASE/status-output
  RUNTIME_STATUS_ERROR_PAYLOAD=$CASE/status-error
  RUNTIME_APPLY_ENDPOINT_FILE=$CASE/apply-endpoint
  RUNTIME_CLOCK_FILE=$CASE/clock
  RUNTIME_STATUS_DEFAULT=0
  RUNTIME_APPLY_DEFAULT=0
  RUNTIME_UPDATE_STATUS=0
  PATH=$STUB:$PATH
  export V6PLUS_LIB V6PLUS_STATE_DIR V6PLUS_LOCK_DIR V6_IP_CMD
  export V6PLUS_APPLY_CMD V6PLUS_UPDATE_CMD V6_SLEEP_CMD V6PLUS_NOW_CMD
  export V6PLUS_ALLOW_NONROOT V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
  export RUNTIME_APPLY_LOG RUNTIME_UPDATE_LOG RUNTIME_SLEEP_LOG RUNTIME_LOGGER_LOG RUNTIME_CHILD_ENV_LOG
  export RUNTIME_STATUS_COUNTER RUNTIME_APPLY_COUNTER RUNTIME_STATUS_SEQUENCE
  export RUNTIME_APPLY_SEQUENCE RUNTIME_STATUS_PAYLOAD RUNTIME_STATUS_ERROR_PAYLOAD
  export RUNTIME_APPLY_ENDPOINT_FILE RUNTIME_CLOCK_FILE RUNTIME_STATUS_DEFAULT
  export RUNTIME_APPLY_DEFAULT RUNTIME_UPDATE_STATUS PATH
  unset V6PLUS_NOW V6PLUS_TEST_MAX_CHECKS
  unset RUNTIME_STATUS_NAME_SEQUENCE RUNTIME_APPLY_ADVANCE RUNTIME_APPLY_TIME_LOG
  unset RUNTIME_UPDATE_ADVANCE RUNTIME_UPDATE_TIME_LOG
  write_last_apply "$OLD_ENDPOINT"
}

run_watch() {
  if "$SCRIPT" --config "$CASE/config" "$@" >"$CASE/stdout" 2>"$CASE/stderr"; then
    WATCH_STATUS=0
  else
    WATCH_STATUS=$?
  fi
}

action_count() {
  wanted=$1
  awk -v wanted="$wanted" '$NF == wanted { count++ } END { print count+0 }' "$CASE/apply.log"
}

line_count() { awk 'END { print NR+0 }' "$1"; }

assert_private_output() {
  test_start "$1"
  if cat "$CASE/stdout" "$CASE/stderr" "$CASE/logger.log" | grep -F -e "$SECRET_SENTINEL" -e "$OLD_ENDPOINT" -e "$NEW_ENDPOINT" >/dev/null; then
    fail 'credential or full endpoint was logged'
  else
    pass
  fi
}

new_case once_healthy
printf 'OK state_local=%s\n' "$OLD_ENDPOINT" >"$CASE/status-output"
printf '0\n' >"$CASE/status-sequence"
run_watch --once
test_start 'once healthy returns success'
assert_eq "$WATCH_STATUS" 0
test_start 'once healthy invokes status exactly once'
assert_eq "$(action_count status)" 1
test_start 'once healthy invokes no apply or update'
assert_eq "$(action_count apply):$(line_count "$CASE/update.log")" '0:0'
test_start 'once mode never sleeps'
assert_eq "$(line_count "$CASE/sleep.log")" 0
assert_private_output 'once status output is captured without credential or endpoint logging'

new_case once_repair_same
watch_state_expanded=$OLD_ENDPOINT
export watch_state_expanded
printf 'ERROR tunnel_mtu=1452 expected=1460\nERROR state_local=%s expected=%s\n' "$OLD_ENDPOINT" "$OLD_ENDPOINT" >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
run_watch --once
unset watch_state_expanded
test_start 'once unhealthy runs exactly one repair and returns it'
assert_eq "$WATCH_STATUS:$(action_count status):$(action_count apply)" '0:1:1'
test_start 'once same-endpoint repair sends no update'
assert_eq "$(line_count "$CASE/update.log")" 0
assert_private_output 'once repair logs only a safe failure summary'
test_start 'inherited watchdog parser scratch cannot export a full endpoint to apply'
if grep -F -e "$OLD_ENDPOINT" -e "$NEW_ENDPOINT" "$CASE/child-env.log" >/dev/null; then
  fail 'full endpoint reached apply child environment'
else
  pass
fi

new_case once_endpoint_change
printf 'ERROR tunnel_local=drift expected=managed\n' >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
printf '%s\n' "$NEW_ENDPOINT" >"$CASE/apply-endpoint"
run_watch --once
test_start 'once changed endpoint force-notifies after successful repair'
assert_eq "$(cat "$CASE/update.log")" "--config $CASE/config --force"
test_start 'once update follows apply in separate shared executables'
assert_eq "$(action_count apply)" 1
assert_private_output 'changed endpoint is never written to watchdog output'

new_case once_update_failure
printf 'ERROR tunnel_local=drift expected=managed\n' >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
printf '%s\n' "$NEW_ENDPOINT" >"$CASE/apply-endpoint"
RUNTIME_UPDATE_STATUS=1
export RUNTIME_UPDATE_STATUS
run_watch --once
test_start 'notification failure does not negate successful repair'
assert_eq "$WATCH_STATUS:$(action_count apply):$(line_count "$CASE/update.log")" '0:1:1'
test_start 'notification failure is reported only as safe deferral'
assert_contains "$(cat "$CASE/stderr")" 'update=deferred reason=notification'

new_case once_apply_failure
printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
RUNTIME_APPLY_DEFAULT=1
export RUNTIME_APPLY_DEFAULT
run_watch --once
test_start 'once returns failed repair status exactly'
assert_eq "$WATCH_STATUS:$(action_count apply)" '1:1'
test_start 'failed once repair never updates'
assert_eq "$(line_count "$CASE/update.log")" 0

for once_apply_status in 2 7; do
  new_case "once_apply_fatal_$once_apply_status"
  printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
  printf '1\n' >"$CASE/status-sequence"
  RUNTIME_APPLY_DEFAULT=$once_apply_status
  export RUNTIME_APPLY_DEFAULT
  run_watch --once
  test_start "once returns exact fatal apply status $once_apply_status"
  assert_eq "$WATCH_STATUS:$(action_count apply)" "$once_apply_status:1"
  test_start "once apply status $once_apply_status is not mislabeled as lock contention"
  assert_eq "$(grep -c 'ERROR phase=repair_apply' "$CASE/stderr" || true):$(grep -c 'repair=deferred' "$CASE/stderr" || true)" '1:0'
done

new_case two_failures
printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
printf '1\n1\n1\n' >"$CASE/status-sequence"
V6PLUS_TEST_MAX_CHECKS=3
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'loop waits for two consecutive failures before repair'
assert_eq "$(action_count status):$(action_count apply)" '3:1'
test_start 'successful repair resets failure counter'
assert_eq "$(action_count apply)" 1
test_start 'loop sleeps configured five seconds between checks including after repair'
assert_eq "$(cat "$CASE/sleep.log")" "5
5"
test_start 'unchanged failure summary is logged once'
assert_eq "$(grep -c 'health=unhealthy summary=tunnel_mtu' "$CASE/stderr" || true)" 1

new_case health_reset
printf 'ERROR route_default=missing expected=ip6tnl1\n' >"$CASE/status-output"
printf '1\n0\n1\n1\n' >"$CASE/status-sequence"
V6PLUS_TEST_MAX_CHECKS=4
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'intervening health resets consecutive failure count'
assert_eq "$(action_count status):$(action_count apply)" '4:1'

new_case successful_repair_clears_cooldown
printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
printf '1\n1\n1\n1\n' >"$CASE/status-sequence"
V6PLUS_TEST_MAX_CHECKS=4
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'successful repair clears failed-repair cooldown for a continuous fault'
assert_eq "$(action_count status):$(action_count apply)" '4:2'

new_case distinct_fault_after_success
printf '1\n1\n1\n1\n' >"$CASE/status-sequence"
printf 'tunnel_mtu\ntunnel_mtu\nroute_default\nroute_default\n' >"$CASE/status-name-sequence"
RUNTIME_STATUS_NAME_SEQUENCE=$CASE/status-name-sequence
V6PLUS_TEST_MAX_CHECKS=4
export RUNTIME_STATUS_NAME_SEQUENCE V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'distinct fault repairs after two failures despite a prior successful repair'
assert_eq "$(action_count status):$(action_count apply)" '4:2'
test_start 'distinct safe summaries are each logged once'
assert_eq "$(grep -c 'summary=tunnel_mtu' "$CASE/stderr" || true):$(grep -c 'summary=route_default' "$CASE/stderr" || true)" '1:1'

new_case healthy_check_clears_failed_cooldown
printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
printf '1\n1\n0\n1\n1\n' >"$CASE/status-sequence"
printf '1\n0\n' >"$CASE/apply-sequence"
V6PLUS_TEST_MAX_CHECKS=5
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'healthy status clears prior failed-repair cooldown before a new fault'
assert_eq "$(action_count status):$(action_count apply)" '5:2'

new_case repair_cooldown
printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
i=0
while [ "$i" -lt 14 ]; do printf '1\n' >>"$CASE/status-sequence"; i=$((i + 1)); done
printf '1\n0\n' >"$CASE/apply-sequence"
RUNTIME_APPLY_TIME_LOG=$CASE/apply-time.log
RUNTIME_APPLY_ADVANCE=20
V6PLUS_TEST_MAX_CHECKS=14
export RUNTIME_APPLY_TIME_LOG RUNTIME_APPLY_ADVANCE V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'failed repair cooldown permits only minute-spaced attempts'
assert_eq "$(action_count status):$(action_count apply)" '14:2'
test_start 'health checks continue every five seconds during repair cooldown'
assert_eq "$(line_count "$CASE/sleep.log")" 13
test_start 'failed-repair cooldown starts when the failed repair completes'
assert_eq "$(cat "$CASE/apply-time.log")" "5
85"
test_start 'lock contention or repair failure is deferred without killing loop'
assert_eq "$WATCH_STATUS" 0
test_start 'failed repair is logged as deferred once'
assert_eq "$(grep -c 'repair=deferred' "$CASE/stderr" || true)" 1
test_start 'persistent identical failure summary is not repeated during cooldown'
assert_eq "$(grep -c 'health=unhealthy summary=tunnel_mtu' "$CASE/stderr" || true)" 1

for loop_apply_status in 2 7; do
  new_case "loop_apply_fatal_$loop_apply_status"
  printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
  printf '1\n1\n' >"$CASE/status-sequence"
  RUNTIME_APPLY_DEFAULT=$loop_apply_status
  V6PLUS_TEST_MAX_CHECKS=2
  export RUNTIME_APPLY_DEFAULT V6PLUS_TEST_MAX_CHECKS
  run_watch
  test_start "loop exits exact fatal apply status $loop_apply_status without retry"
  assert_eq "$WATCH_STATUS:$(action_count status):$(action_count apply):$(line_count "$CASE/sleep.log")" "$loop_apply_status:2:1:1"
  test_start "loop apply status $loop_apply_status gets no failed-repair cooldown label"
  assert_eq "$(grep -c 'ERROR phase=repair_apply' "$CASE/stderr" || true):$(grep -c 'repair=deferred' "$CASE/stderr" || true)" '1:0'
done

new_case safe_interface_summaries
{
  printf 'ERROR route_br0.10=missing expected=managed\n'
  printf 'ERROR rule_br0:1=missing expected=managed\n'
  printf 'ERROR snat_veth-a=missing expected=managed\n'
  printf 'ERROR UPDATE_PASSWORD=%s expected=hidden\n' "$SECRET_SENTINEL"
  printf 'ERROR endpoint_2001:db8::1=%s expected=hidden\n' "$OLD_ENDPOINT"
  printf 'ERROR route_abcdefghijklmnop=missing expected=managed\n'
  printf 'ERROR route_bad\001name=missing expected=managed\n'
} >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
run_watch --once
test_start 'safe bounded interface-bearing invariant names retain dot colon and hyphen'
assert_contains "$(cat "$CASE/stderr")" 'health=unhealthy summary=route_br0.10,rule_br0:1,snat_veth-a'
test_start 'unsafe credential address control and oversized names are not summarized'
if grep -F -e 'UPDATE_PASSWORD' -e 'endpoint_2001' -e 'abcdefghijklmnop' -e 'route_bad' \
     -e "$SECRET_SENTINEL" -e "$OLD_ENDPOINT" "$CASE/stderr" "$CASE/logger.log" >/dev/null; then
  fail 'unsafe status material reached summary output'
else
  pass
fi

new_case loop_endpoint_change
printf 'ERROR tunnel_local=drift expected=managed\n' >"$CASE/status-output"
printf '1\n1\n' >"$CASE/status-sequence"
printf '%s\n' "$NEW_ENDPOINT" >"$CASE/apply-endpoint"
V6PLUS_TEST_MAX_CHECKS=2
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'loop force-notifies only after successful endpoint-changing repair'
assert_eq "$(line_count "$CASE/update.log")" 1
assert_private_output 'loop captures raw status and endpoint values privately'

new_case unsafe_state
printf 'ERROR state=invalid expected=validated\n' >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
chmod 644 "$CASE/state/last-apply.env"
run_watch --once
test_start 'unsafe last-apply state fails closed before repair'
assert_eq "$WATCH_STATUS:$(action_count apply)" '1:0'

new_case missing_state
printf 'ERROR state=missing expected=complete\n' >"$CASE/status-output"
printf '1\n' >"$CASE/status-sequence"
rm "$CASE/state/last-apply.env"
printf '%s\n' "$NEW_ENDPOINT" >"$CASE/apply-endpoint"
run_watch --once
test_start 'missing managed state can be repaired through shared apply'
assert_eq "$WATCH_STATUS:$(action_count apply):$(line_count "$CASE/update.log")" '0:1:1'

new_case status_config_error
printf 'invalid apply configuration\n' >"$CASE/status-error"
printf '2\n' >"$CASE/status-sequence"
run_watch --once
test_start 'status configuration error is fatal and never invokes apply'
assert_eq "$WATCH_STATUS:$(action_count apply)" '1:0'

new_case invalid_clock
printf '01\n' >"$CASE/clock"
printf 'ERROR tunnel_mtu=1452 expected=1460\n' >"$CASE/status-output"
printf '1\n1\n' >"$CASE/status-sequence"
V6PLUS_TEST_MAX_CHECKS=2
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'non-canonical monotonic clock fails closed without apply'
assert_eq "$WATCH_STATUS:$(action_count apply)" '1:0'

new_case invalid_test_bound
V6PLUS_TEST_MAX_CHECKS=00
export V6PLUS_TEST_MAX_CHECKS
run_watch
test_start 'non-canonical injected loop bound is usage error'
assert_eq "$WATCH_STATUS" 2

test_finish
