#!/bin/sh
set -u
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

SCRIPT=$ROOT/scripts/unifi-jpix-tunnel-repair-trigger.sh
STUB=$ROOT/tests/stubs/runtime
TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/unifi-jpix-tunnel-repair-trigger-test.$$
OLD_ENDPOINT=2001:0db8:1234:0030:00cb:0071:2a00:0000
NEW_ENDPOINT=2001:0db8:1234:0031:00cb:0071:2a00:0000
SECRET_SENTINEL='trigger-secret-user:p&a ss%word'
LIVE_TRIGGER_PID=
LIVE_MONITOR_PID=
UNRELATED_PID=

stop_test_pid() {
  cleanup_pid=$1
  [ -n "$cleanup_pid" ] || return 0
  if kill -0 "$cleanup_pid" 2>/dev/null; then
    kill -TERM "$cleanup_pid" 2>/dev/null || :
    if kill -0 "$cleanup_pid" 2>/dev/null; then
      kill -KILL "$cleanup_pid" 2>/dev/null || :
    fi
  fi
  wait "$cleanup_pid" 2>/dev/null || :
}

cleanup_test() {
  stop_test_pid "$LIVE_TRIGGER_PID"
  stop_test_pid "$LIVE_MONITOR_PID"
  stop_test_pid "$UNRELATED_PID"
  rm -rf "$TMP"
}

trap 'cleanup_test' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TMP"

test_start 'netlink trigger executable exists'
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
  unset TMPDIR
  CASE=$TMP/$1
  mkdir -p "$CASE/config" "$CASE/state" "$CASE/tmp"
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
  cat >"$CASE/config/routed-networks.conf" <<'EOF'
br0 192.168.20.0/24
br10 192.168.10.0/24
EOF
  printf 'UPDATE_URL=https://updates.example.invalid/path\nUPDATE_USERNAME=%s\nUPDATE_PASSWORD=%s\nALLOW_INSECURE_UPDATE_HTTP=no\nINSECURE_UPDATE_HTTP_HOST=\n' \
    "$SECRET_SENTINEL" "$SECRET_SENTINEL" >"$CASE/config/provider-update.conf"
  chmod 600 "$CASE/config/provider-update.conf"
  printf '2001:db8:ffff::1 via fe80::1 dev eth9 src 2001:db8:1234:31:abcd::1 metric 1024\n' >"$CASE/route"
  printf '    inet6 2001:db8:1234:31:abcd::1/64 scope global dynamic\n       valid_lft forever preferred_lft forever\n' >"$CASE/addr"
  : >"$CASE/monitor"
  : >"$CASE/apply.log"
  : >"$CASE/update.log"
  : >"$CASE/sleep.log"
  : >"$CASE/commands.log"
  : >"$CASE/logger.log"
  : >"$CASE/child-env.log"
  : >"$CASE/apply.count"
  : >"$CASE/status.count"
  : >"$CASE/apply-time.log"
  : >"$CASE/update-time.log"
  : >"$CASE/mkfifo.log"
  : >"$CASE/mkfifo-metadata.log"
  : >"$CASE/identity.log"
  : >"$CASE/identity.count"
  : >"$CASE/identity-base"
  : >"$CASE/signal.log"
  : >"$CASE/monitor-exit.args"
  : >"$CASE/clock"
  printf '%s\n' "$NEW_ENDPOINT" >"$CASE/apply-endpoint"

  V6PLUS_LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh
  V6PLUS_STATE_DIR=$CASE/state
  V6PLUS_LOCK_DIR=$CASE/lock
  V6_IP_CMD=$STUB/ip
  V6PLUS_MONITOR_CMD=$STUB/ip
  V6PLUS_APPLY_CMD=$STUB/apply
  V6PLUS_UPDATE_CMD=$STUB/update
  V6_SLEEP_CMD=$STUB/sleep
  V6PLUS_STARTUP_SLEEP_CMD=$STUB/startup-sleep
  V6PLUS_STARTUP_WAIT_TICKS=100
  V6_MKFIFO_CMD=$STUB/mkfifo
  V6PLUS_ALLOW_NONROOT=1
  V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
  V6PLUS_NOW=100
  RUNTIME_ROUTE_FILE=$CASE/route
  RUNTIME_ADDR_FILE=$CASE/addr
  RUNTIME_MONITOR_FILE=$CASE/monitor
  RUNTIME_MONITOR_STATUS=0
  RUNTIME_APPLY_LOG=$CASE/apply.log
  RUNTIME_UPDATE_LOG=$CASE/update.log
  RUNTIME_SLEEP_LOG=$CASE/sleep.log
  RUNTIME_COMMAND_LOG=$CASE/commands.log
  RUNTIME_LOGGER_LOG=$CASE/logger.log
  RUNTIME_CHILD_ENV_LOG=$CASE/child-env.log
  RUNTIME_APPLY_COUNTER=$CASE/apply.count
  RUNTIME_STATUS_COUNTER=$CASE/status.count
  RUNTIME_APPLY_ENDPOINT_FILE=$CASE/apply-endpoint
  RUNTIME_MKFIFO_LOG=$CASE/mkfifo.log
  RUNTIME_MKFIFO_METADATA_LOG=$CASE/mkfifo-metadata.log
  RUNTIME_APPLY_DEFAULT=0
  RUNTIME_UPDATE_STATUS=0
  PATH=$STUB:$PATH
  export V6PLUS_LIB V6PLUS_STATE_DIR V6PLUS_LOCK_DIR V6_IP_CMD
  export V6PLUS_MONITOR_CMD V6PLUS_APPLY_CMD V6PLUS_UPDATE_CMD V6_SLEEP_CMD
  export V6PLUS_STARTUP_SLEEP_CMD V6PLUS_STARTUP_WAIT_TICKS V6_MKFIFO_CMD
  export V6PLUS_ALLOW_NONROOT V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES V6PLUS_NOW
  export RUNTIME_ROUTE_FILE RUNTIME_ADDR_FILE RUNTIME_MONITOR_FILE RUNTIME_MONITOR_STATUS
  export RUNTIME_APPLY_LOG RUNTIME_UPDATE_LOG RUNTIME_SLEEP_LOG RUNTIME_COMMAND_LOG
  export RUNTIME_LOGGER_LOG RUNTIME_CHILD_ENV_LOG RUNTIME_APPLY_COUNTER RUNTIME_STATUS_COUNTER
  export RUNTIME_APPLY_ENDPOINT_FILE RUNTIME_MKFIFO_LOG RUNTIME_MKFIFO_METADATA_LOG
  export RUNTIME_APPLY_DEFAULT RUNTIME_UPDATE_STATUS PATH
  unset V6PLUS_NOW_CMD RUNTIME_CLOCK_FILE RUNTIME_APPLY_SEQUENCE
  unset RUNTIME_CLOCK_SEQUENCE RUNTIME_CLOCK_COUNTER
  unset RUNTIME_APPLY_ADVANCE RUNTIME_UPDATE_ADVANCE RUNTIME_LIVE_MONITOR_PID_FILE
  unset RUNTIME_LIVE_MONITOR_RECORD RUNTIME_LIVE_MONITOR_IGNORE_TERM
  unset RUNTIME_APPLY_TIME_LOG RUNTIME_UPDATE_TIME_LOG
  unset V6PLUS_IDENTITY_PROBE_CMD V6_KILL_CMD RUNTIME_IDENTITY_MODE
  unset RUNTIME_IDENTITY_LOG RUNTIME_IDENTITY_COUNTER RUNTIME_IDENTITY_BASE_FILE
  unset RUNTIME_SIGNAL_LOG RUNTIME_SIGNAL_PASSTHROUGH RUNTIME_SIGNAL_STATUS
  unset RUNTIME_MONITOR_EXIT_PID_FILE RUNTIME_MONITOR_EXIT_ARGS_LOG
  unset RUNTIME_MONITOR_EXIT_RECORD RUNTIME_MONITOR_EXIT_STATUS
}

run_trigger() {
  if "$SCRIPT" --config "$CASE/config" >"$CASE/stdout" 2>"$CASE/stderr"; then
    TRIGGER_STATUS=0
  else
    TRIGGER_STATUS=$?
  fi
}

count_lines() { awk 'END { print NR+0 }' "$1"; }

pid_is_alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

wait_for_file() {
  wait_file=$1
  wait_count=0
  while [ "$wait_count" -lt 40 ]; do
    [ -s "$wait_file" ] && return 0
    /bin/sleep 0.05
    wait_count=$((wait_count + 1))
  done
  return 1
}

wait_for_exit() {
  wait_pid=$1
  wait_count=0
  while [ "$wait_count" -lt 40 ]; do
    pid_is_alive "$wait_pid" || return 0
    /bin/sleep 0.05
    wait_count=$((wait_count + 1))
  done
  return 1
}

enable_identity_fixture() {
  RUNTIME_IDENTITY_MODE=$1
  V6PLUS_IDENTITY_PROBE_CMD=$STUB/identity-probe
  V6_KILL_CMD=$STUB/signal
  RUNTIME_IDENTITY_LOG=$CASE/identity.log
  RUNTIME_IDENTITY_COUNTER=$CASE/identity.count
  RUNTIME_IDENTITY_BASE_FILE=$CASE/identity-base
  RUNTIME_SIGNAL_LOG=$CASE/signal.log
  V6PLUS_MONITOR_CMD=$STUB/monitor-exit
  RUNTIME_MONITOR_EXIT_PID_FILE=$CASE/monitor-exit.pid
  RUNTIME_MONITOR_EXIT_ARGS_LOG=$CASE/monitor-exit.args
  RUNTIME_MONITOR_EXIT_STATUS=0
  TMPDIR=$CASE/tmp
  export RUNTIME_IDENTITY_MODE V6PLUS_IDENTITY_PROBE_CMD V6_KILL_CMD
  export RUNTIME_IDENTITY_LOG RUNTIME_IDENTITY_COUNTER RUNTIME_IDENTITY_BASE_FILE
  export RUNTIME_SIGNAL_LOG V6PLUS_MONITOR_CMD RUNTIME_MONITOR_EXIT_PID_FILE
  export RUNTIME_MONITOR_EXIT_ARGS_LOG RUNTIME_MONITOR_EXIT_STATUS TMPDIR
}

enable_monitor_exit_fixture() {
  V6PLUS_MONITOR_CMD=$STUB/monitor-exit
  RUNTIME_MONITOR_EXIT_PID_FILE=$CASE/monitor-exit.pid
  RUNTIME_MONITOR_EXIT_ARGS_LOG=$CASE/monitor-exit.args
  RUNTIME_MONITOR_EXIT_STATUS=0
  TMPDIR=$CASE/tmp
  export V6PLUS_MONITOR_CMD RUNTIME_MONITOR_EXIT_PID_FILE
  export RUNTIME_MONITOR_EXIT_ARGS_LOG RUNTIME_MONITOR_EXIT_STATUS TMPDIR
}

new_case relevant_burst
write_last_apply "$OLD_ENDPOINT"
trigger_state_expanded=$OLD_ENDPOINT
trigger_record=$OLD_ENDPOINT
trigger_preferred_address=$NEW_ENDPOINT
export trigger_state_expanded trigger_record trigger_preferred_address
cat >"$CASE/monitor" <<'EOF'
Deleted 2001:db8:1234:30:abcd::1/64 dev eth9
2001:db8:1234:31:abcd::1/64 dev eth9 scope global
Deleted 192.0.0.2/29 dev ip6tnl1
3: ip6tnl1: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1452
192.168.20.0/24 dev br0 table 300 deleted
EOF
run_trigger
unset trigger_state_expanded trigger_record trigger_preferred_address
test_start 'monitor exhaustion makes trigger fail for systemd restart'
assert_eq "$TRIGGER_STATUS" 1
test_start 'relevant event burst invokes shared apply exactly once'
assert_eq "$(cat "$CASE/apply.log")" "--config $CASE/config apply"
test_start 'changed composed endpoint force-notifies exactly once'
assert_eq "$(cat "$CASE/update.log")" "--config $CASE/config --force"
test_start 'event burst is debounced by two seconds once'
assert_eq "$(cat "$CASE/sleep.log")" 2
test_start 'successful repair stores canonical trigger epoch'
assert_eq "$(cat "$CASE/state/last-trigger")" 100
test_start 'trigger epoch state is private'
assert_eq "$(stat -c %a "$CASE/state/last-trigger")" 600
test_start 'monitor is invoked with exact production arguments'
assert_contains "$(cat "$CASE/commands.log")" 'ip -ts monitor link address route'
test_start 'trigger creates one private monitor FIFO through its validated dependency'
assert_eq "$(count_lines "$CASE/mkfifo.log")" 1
test_start 'the monitor FIFO is owned by the service user with mode 0600'
assert_eq "$(count_lines "$CASE/mkfifo-metadata.log"):$(grep -c -v "^$(id -u):600:fifo$" "$CASE/mkfifo-metadata.log" || true)" '1:0'
test_start 'endpoint selection uses one BR route snapshot'
assert_eq "$(grep -c 'ip -6 route get 2001:db8:ffff::1' "$CASE/commands.log" || true)" 1
test_start 'endpoint selection validates the preferred WAN address snapshot'
assert_eq "$(grep -c 'ip -6 addr show dev eth9 scope global' "$CASE/commands.log" || true)" 1
test_start 'trigger output never contains update credentials or full endpoint'
if cat "$CASE/stdout" "$CASE/stderr" "$CASE/logger.log" | grep -F -e "$SECRET_SENTINEL" -e "$NEW_ENDPOINT" >/dev/null; then
  fail 'secret or full endpoint was logged'
else
  pass
fi
test_start 'inherited parser scratch cannot export a full endpoint to runtime children'
if grep -F -e "$OLD_ENDPOINT" -e "$NEW_ENDPOINT" "$CASE/child-env.log" >/dev/null; then
  fail 'full endpoint reached a runtime child environment'
else
  pass
fi

new_case irrelevant_tokens
write_last_apply "$OLD_ENDPOINT"
cat >"$CASE/monitor" <<'EOF'
Deleted 2001:db8::1/64 dev eth9evil
3: ip6tnl10: <UP> mtu 1452
192.168.20.0/24 dev br0evil table 3000 deleted
192.168.99.0/24 dev br99 table 301 deleted
EOF
run_trigger
test_start 'substring-confusable and unlisted events do not apply'
assert_eq "$(count_lines "$CASE/apply.log")" 0
test_start 'irrelevant events do not debounce or create trigger state'
if [ ! -s "$CASE/sleep.log" ] && [ ! -e "$CASE/state/last-trigger" ]; then pass; else fail 'irrelevant event caused state'; fi

for serialization_kind in wan_v6_deleted wan_v4_added tunnel_v4_deleted tunnel_v6_added; do
  new_case "serialization_$serialization_kind"
  write_last_apply "$NEW_ENDPOINT"
  case $serialization_kind in
    wan_v6_deleted)
      printf '[2026-08-22T12:34:56.000001] Deleted 2: eth9 inet6 2001:db8:1234:30:abcd::1/64 scope global\n' >"$CASE/monitor"
      ;;
    wan_v4_added)
      printf '[2026-08-22T12:34:56.000002] 2: eth9 inet 192.0.2.9/24 scope global\n' >"$CASE/monitor"
      ;;
    tunnel_v4_deleted)
      printf '[2026-08-22T12:34:56.000003] Deleted 3: ip6tnl1 inet 192.0.0.2/29 scope global\n' >"$CASE/monitor"
      ;;
    tunnel_v6_added)
      printf '[2026-08-22T12:34:56.000004] 3: ip6tnl1 inet6 2001:db8:1234:31::1/128 scope global\n' >"$CASE/monitor"
      ;;
  esac
  run_trigger
  test_start "timestamped $serialization_kind record matches its exact bare interface token"
  assert_eq "$(count_lines "$CASE/apply.log")" 1
done

new_case timestamped_interface_confusers
write_last_apply "$NEW_ENDPOINT"
cat >"$CASE/monitor" <<'EOF'
[2026-08-22T12:34:56.100001] Deleted 2: eth90 inet6 2001:db8:1234:30::1/64 scope global
[2026-08-22T12:34:56.100002] 3: ip6tnl10 inet 192.0.0.2/29 scope global
[2026-08-22T12:34:56.100003] Deleted 4: br00 inet 192.168.20.1/24 scope global
[2026-08-22T12:34:56.100004] 5: xbr10 inet6 2001:db8:1234:31::1/128 scope global
EOF
run_trigger
test_start 'timestamped bare-interface confusers do not match by substring'
assert_eq "$(count_lines "$CASE/apply.log")" 0

new_case missing_mkfifo_dependency
write_last_apply "$NEW_ENDPOINT"
V6_MKFIFO_CMD=$CASE/missing-mkfifo
export V6_MKFIFO_CMD
printf 'Deleted 3: ip6tnl1 inet 192.0.0.2/29 scope global\n' >"$CASE/monitor"
run_trigger
test_start 'missing FIFO dependency fails closed before monitor startup'
assert_contains "$(cat "$CASE/stderr")" 'ERROR phase=dependency'
test_start 'missing FIFO dependency never starts the monitor'
assert_eq "$(grep -c 'ip -ts monitor' "$CASE/commands.log" || true)" 0

for event_kind in wan_delete wan_add tunnel_address tunnel_link network_route table_route; do
  new_case "event_$event_kind"
  write_last_apply "$NEW_ENDPOINT"
  case $event_kind in
    wan_delete) printf 'Deleted 2001:db8:1234:30:abcd::1/64 dev eth9\n' >"$CASE/monitor" ;;
    wan_add) printf '2001:db8:1234:31:abcd::1/64 dev eth9 scope global\n' >"$CASE/monitor" ;;
    tunnel_address) printf 'Deleted 192.0.0.2/29 dev ip6tnl1\n' >"$CASE/monitor" ;;
    tunnel_link) printf '3: ip6tnl1: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1452\n' >"$CASE/monitor" ;;
    network_route) printf '192.168.20.0/24 dev br0 deleted\n' >"$CASE/monitor" ;;
    table_route) printf '198.51.100.0/24 dev br99 table 300 deleted\n' >"$CASE/monitor" ;;
  esac
  run_trigger
  test_start "exact $event_kind record triggers one debounced apply"
  assert_eq "$(count_lines "$CASE/apply.log")" 1
done

new_case same_endpoint
write_last_apply "$NEW_ENDPOINT"
printf 'Deleted 192.0.0.2/29 dev ip6tnl1\n' >"$CASE/monitor"
run_trigger
test_start 'same-endpoint tunnel repair still applies once'
assert_eq "$(count_lines "$CASE/apply.log")" 1
test_start 'same-endpoint repair does not notify'
assert_eq "$(count_lines "$CASE/update.log")" 0

new_case persisted_cooldown
write_last_apply "$OLD_ENDPOINT"
printf 'Deleted 2001:db8::1/64 dev eth9\n' >"$CASE/monitor"
printf '99\n' >"$CASE/state/last-trigger"
chmod 600 "$CASE/state/last-trigger"
run_trigger
test_start 'persisted two-second cooldown suppresses repair start'
assert_eq "$(count_lines "$CASE/apply.log")" 0
test_start 'cooldown suppression leaves persisted epoch unchanged'
assert_eq "$(cat "$CASE/state/last-trigger")" 99

new_case cooldown_boundary
write_last_apply "$NEW_ENDPOINT"
printf 'Deleted 2001:db8::1/64 dev eth9\n' >"$CASE/monitor"
printf '98\n' >"$CASE/state/last-trigger"
chmod 600 "$CASE/state/last-trigger"
run_trigger
test_start 'event exactly two seconds after prior repair is allowed'
assert_eq "$(count_lines "$CASE/apply.log")" 1

new_case lock_contention
write_last_apply "$OLD_ENDPOINT"
RUNTIME_APPLY_DEFAULT=1
export RUNTIME_APPLY_DEFAULT
printf 'Deleted 192.0.0.2/29 dev ip6tnl1\n3: ip6tnl1: <UP> mtu 1452\n' >"$CASE/monitor"
run_trigger
test_start 'failed or lock-contended apply is not retried within buffered burst'
assert_eq "$(count_lines "$CASE/apply.log")" 1
test_start 'failed or lock-contended apply leaves trigger state unchanged'
if [ ! -e "$CASE/state/last-trigger" ]; then pass; else fail 'failed repair wrote trigger epoch'; fi
test_start 'failed or lock-contended apply remains monitor-nonfatal'
assert_contains "$(cat "$CASE/stderr")" 'repair=deferred'

new_case lock_retry_after_cooldown
write_last_apply "$OLD_ENDPOINT"
printf 'Deleted 192.0.0.2/29 dev ip6tnl1\n3: ip6tnl1: <UP> mtu 1452\n' >"$CASE/monitor"
printf '1\n0\n' >"$CASE/apply-sequence"
printf '0\n2\n4\n6\n' >"$CASE/clock-sequence"
: >"$CASE/clock-counter"
RUNTIME_APPLY_SEQUENCE=$CASE/apply-sequence
RUNTIME_CLOCK_SEQUENCE=$CASE/clock-sequence
RUNTIME_CLOCK_COUNTER=$CASE/clock-counter
V6PLUS_NOW_CMD=$STUB/now
unset V6PLUS_NOW
export RUNTIME_APPLY_SEQUENCE RUNTIME_CLOCK_SEQUENCE RUNTIME_CLOCK_COUNTER V6PLUS_NOW_CMD
run_trigger
test_start 'lock contention defers but a later event retries after cooldown'
assert_eq "$(count_lines "$CASE/apply.log")" 2
test_start 'successful retry after contention records its later epoch'
assert_eq "$(cat "$CASE/state/last-trigger")" 6
test_start 'successful endpoint-changing retry force-notifies once'
assert_eq "$(count_lines "$CASE/update.log")" 1

new_case slow_successful_burst
write_last_apply "$OLD_ENDPOINT"
printf '0\n' >"$CASE/clock"
RUNTIME_CLOCK_FILE=$CASE/clock
RUNTIME_APPLY_TIME_LOG=$CASE/apply-time.log
RUNTIME_UPDATE_TIME_LOG=$CASE/update-time.log
RUNTIME_APPLY_ADVANCE=10
RUNTIME_UPDATE_ADVANCE=10
V6PLUS_NOW_CMD=$STUB/now
unset V6PLUS_NOW
export RUNTIME_CLOCK_FILE RUNTIME_APPLY_TIME_LOG RUNTIME_UPDATE_TIME_LOG
export RUNTIME_APPLY_ADVANCE RUNTIME_UPDATE_ADVANCE V6PLUS_NOW_CMD
cat >"$CASE/monitor" <<'EOF'
Deleted 2001:db8:1234:30::1/64 dev eth9 scope global
Deleted 192.0.0.2/29 dev ip6tnl1 scope global
EOF
run_trigger
test_start 'slow successful apply and update consume one buffered burst'
assert_eq "$(count_lines "$CASE/apply.log"):$(count_lines "$CASE/update.log")" '1:1'
test_start 'successful trigger epoch is recorded after apply and update completion'
assert_eq "$(cat "$CASE/state/last-trigger"):$(cat "$CASE/clock")" '22:22'
test_start 'slow successful operation start times are independently observable'
assert_eq "$(cat "$CASE/apply-time.log"):$(cat "$CASE/update-time.log")" '2:12'

new_case slow_failed_burst
write_last_apply "$OLD_ENDPOINT"
printf '5\n' >"$CASE/clock"
printf '0\n' >"$CASE/state/last-trigger"
chmod 600 "$CASE/state/last-trigger"
RUNTIME_CLOCK_FILE=$CASE/clock
RUNTIME_APPLY_TIME_LOG=$CASE/apply-time.log
RUNTIME_APPLY_ADVANCE=10
RUNTIME_APPLY_DEFAULT=1
V6PLUS_NOW_CMD=$STUB/now
unset V6PLUS_NOW
export RUNTIME_CLOCK_FILE RUNTIME_APPLY_TIME_LOG RUNTIME_APPLY_ADVANCE
export RUNTIME_APPLY_DEFAULT V6PLUS_NOW_CMD
cat >"$CASE/monitor" <<'EOF'
Deleted 2001:db8:1234:30::1/64 dev eth9 scope global
Deleted 192.0.0.2/29 dev ip6tnl1 scope global
EOF
run_trigger
test_start 'slow failed apply refreshes in-memory completion and suppresses buffered retry'
assert_eq "$(count_lines "$CASE/apply.log"):$(cat "$CASE/apply-time.log")" '1:7'
test_start 'failed apply leaves the prior persistent completion unchanged'
assert_eq "$(cat "$CASE/state/last-trigger")" 0
test_start 'failed apply completion is sampled from the monotonic clock'
assert_eq "$(cat "$CASE/clock")" 17

new_case slow_failed_update_burst
write_last_apply "$OLD_ENDPOINT"
printf '0\n' >"$CASE/clock"
RUNTIME_CLOCK_FILE=$CASE/clock
RUNTIME_APPLY_TIME_LOG=$CASE/apply-time.log
RUNTIME_UPDATE_TIME_LOG=$CASE/update-time.log
RUNTIME_APPLY_ADVANCE=3
RUNTIME_UPDATE_ADVANCE=7
RUNTIME_UPDATE_STATUS=1
V6PLUS_NOW_CMD=$STUB/now
unset V6PLUS_NOW
export RUNTIME_CLOCK_FILE RUNTIME_APPLY_TIME_LOG RUNTIME_UPDATE_TIME_LOG
export RUNTIME_APPLY_ADVANCE RUNTIME_UPDATE_ADVANCE RUNTIME_UPDATE_STATUS V6PLUS_NOW_CMD
cat >"$CASE/monitor" <<'EOF'
Deleted 2001:db8:1234:30::1/64 dev eth9 scope global
Deleted 192.0.0.2/29 dev ip6tnl1 scope global
EOF
run_trigger
test_start 'failed notification does not negate or duplicate a successful repair'
assert_eq "$(count_lines "$CASE/apply.log"):$(count_lines "$CASE/update.log")" '1:1'
test_start 'notification failure still persists successful repair completion'
assert_eq "$(cat "$CASE/state/last-trigger"):$(cat "$CASE/clock")" '12:12'
test_start 'notification failure remains a safe nonfatal deferral'
assert_contains "$(cat "$CASE/stderr")" 'update=deferred reason=notification'

for completion_kind in successful_apply failed_apply; do
  new_case "nonmonotonic_completion_$completion_kind"
  write_last_apply "$NEW_ENDPOINT"
  printf '10\n12\n11\n' >"$CASE/clock-sequence"
  : >"$CASE/clock-counter"
  RUNTIME_CLOCK_SEQUENCE=$CASE/clock-sequence
  RUNTIME_CLOCK_COUNTER=$CASE/clock-counter
  V6PLUS_NOW_CMD=$STUB/now
  unset V6PLUS_NOW
  export RUNTIME_CLOCK_SEQUENCE RUNTIME_CLOCK_COUNTER V6PLUS_NOW_CMD
  if [ "$completion_kind" = failed_apply ]; then
    RUNTIME_APPLY_DEFAULT=1
    export RUNTIME_APPLY_DEFAULT
  fi
  printf 'Deleted 192.0.0.2/29 dev ip6tnl1 scope global\n' >"$CASE/monitor"
  run_trigger
  test_start "$completion_kind samples and rejects a regressing completion clock"
  assert_eq "$(cat "$CASE/clock-counter"):$(grep -c 'ERROR phase=clock' "$CASE/stderr" || true)" '3:1'
  test_start "$completion_kind never persists a pre-completion timestamp"
  if [ ! -e "$CASE/state/last-trigger" ]; then pass; else fail 'pre-completion epoch persisted'; fi
done

for invalid_identity_mode in proc_pid_mismatch_first signal_pid_mismatch_first leading_zero_proc leading_zero_start extra_fields; do
  new_case "startup_identity_$invalid_identity_mode"
  write_last_apply "$NEW_ENDPOINT"
  enable_identity_fixture "$invalid_identity_mode"
  RUNTIME_MONITOR_EXIT_RECORD='Deleted 2001:db8::1/64 dev eth9evil scope global'
  export RUNTIME_MONITOR_EXIT_RECORD
  run_trigger
  test_start "startup $invalid_identity_mode identity fails closed after one typed probe"
  assert_eq "$TRIGGER_STATUS:$(cat "$CASE/identity.count" 2>/dev/null || true):$(grep -c 'ERROR phase=monitor_identity' "$CASE/stderr" || true)" '1:1:1'
  test_start "startup $invalid_identity_mode releases and reaps without any signal"
  assert_eq "$(count_lines "$CASE/signal.log"):$(count_lines "$CASE/monitor-exit.args")" '0:0'
  test_start "startup $invalid_identity_mode removes all private handshake artifacts"
  if [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]; then pass; else fail 'startup handshake artifacts remain'; fi
done

new_case startup_signal_pending
write_last_apply "$NEW_ENDPOINT"
enable_identity_fixture signal_first
RUNTIME_MONITOR_EXIT_RECORD='Deleted 2001:db8::1/64 dev eth9evil scope global'
export RUNTIME_MONITOR_EXIT_RECORD
/bin/sleep 30 &
UNRELATED_PID=$!
run_trigger
if pid_is_alive "$UNRELATED_PID"; then startup_unrelated_survived=yes; else startup_unrelated_survived=no; fi
stop_test_pid "$UNRELATED_PID"
UNRELATED_PID=
startup_wrapper_pid=$(awk 'NR == 1 { print $3 }' "$CASE/identity.log")
test_start 'signal during identity readiness is deferred until wrapper identity is stable'
assert_eq "$TRIGGER_STATUS:$(cat "$CASE/identity.count" 2>/dev/null || true):$(count_lines "$CASE/monitor-exit.args")" '143:1:0'
test_start 'deferred startup signal releases and reaps without signaling any PID'
assert_eq "$(count_lines "$CASE/signal.log"):$startup_unrelated_survived" '0:yes'
test_start 'deferred startup signal leaves no wrapper process or private artifacts'
if ! pid_is_alive "$startup_wrapper_pid" && [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]; then
  pass
else
  fail 'startup wrapper or artifacts remain'
fi

new_case normal_eof_identity
write_last_apply "$NEW_ENDPOINT"
unset V6PLUS_IDENTITY_PROBE_CMD
enable_monitor_exit_fixture
RUNTIME_MONITOR_EXIT_RECORD='Deleted 2001:db8::1/64 dev eth9evil scope global'
export RUNTIME_MONITOR_EXIT_RECORD
run_trigger
normal_monitor_pid=$(cat "$CASE/monitor-exit.pid" 2>/dev/null || true)
test_start 'default nested-namespace identity starts the exact monitor and returns restart status'
assert_eq "$TRIGGER_STATUS:$(count_lines "$CASE/identity.log"):$(cat "$CASE/monitor-exit.args")" '1:0:-ts monitor link address route'
test_start 'default nested-namespace identity emits no raw proc path diagnostic'
if grep -E '/proc/[0-9]+/(stat|status)|ERROR phase=monitor_identity' "$CASE/stderr" >/dev/null; then
  fail 'default proc identity failed or leaked an inner proc path'
else
  pass
fi
test_start 'normal monitor EOF reaps with wait and never sends TERM or KILL'
if [ "$(count_lines "$CASE/signal.log")" -eq 0 ] && ! pid_is_alive "$normal_monitor_pid"; then pass; else fail 'normal EOF signaled or left producer'; fi
test_start 'normal monitor EOF removes all private handshake artifacts'
if [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]; then pass; else fail 'normal EOF artifacts remain'; fi

new_case exited_monitor_identity_mismatch
write_last_apply "$OLD_ENDPOINT"
printf '100\n' >"$CASE/trigger-target"
ln -s "$CASE/trigger-target" "$CASE/state/last-trigger"
enable_identity_fixture mismatch_after_first
RUNTIME_MONITOR_EXIT_RECORD='Deleted 2001:db8:1234:30::1/64 dev eth9 scope global'
export RUNTIME_MONITOR_EXIT_RECORD
run_trigger
exited_monitor_pid=$(cat "$CASE/monitor-exit.pid" 2>/dev/null || true)
test_start 'fatal handling re-probes a write-close-exited monitor and detects identity reuse'
assert_eq "$(cat "$CASE/identity.count" 2>/dev/null || true):$(grep -c 'ERROR phase=trigger_state' "$CASE/stderr" || true)" '2:1'
test_start 'mismatched cached PID is never sent TERM or KILL and direct child is reaped'
if [ "$(count_lines "$CASE/signal.log")" -eq 0 ] && ! pid_is_alive "$exited_monitor_pid"; then pass; else fail 'mismatched PID signaled or child remains'; fi
test_start 'identity-mismatch cleanup removes all exact private artifacts'
if [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]; then pass; else fail 'identity mismatch artifacts remain'; fi

new_case live_monitor_fatal_state
write_last_apply "$OLD_ENDPOINT"
unset V6PLUS_IDENTITY_PROBE_CMD
printf '100\n' >"$CASE/trigger-target"
ln -s "$CASE/trigger-target" "$CASE/state/last-trigger"
V6PLUS_MONITOR_CMD=$STUB/monitor-live
RUNTIME_LIVE_MONITOR_PID_FILE=$CASE/live-monitor.pid
RUNTIME_LIVE_MONITOR_RECORD='Deleted 2001:db8:1234:30::1/64 dev eth9 scope global'
RUNTIME_LIVE_MONITOR_IGNORE_TERM=1
TMPDIR=$CASE/tmp
export V6PLUS_MONITOR_CMD RUNTIME_LIVE_MONITOR_PID_FILE RUNTIME_LIVE_MONITOR_RECORD
export RUNTIME_LIVE_MONITOR_IGNORE_TERM TMPDIR
/bin/sleep 30 &
UNRELATED_PID=$!
"$SCRIPT" --config "$CASE/config" >"$CASE/stdout" 2>"$CASE/stderr" &
LIVE_TRIGGER_PID=$!
if wait_for_file "$RUNTIME_LIVE_MONITOR_PID_FILE"; then
  producer_observed=yes
  LIVE_MONITOR_PID=$(cat "$RUNTIME_LIVE_MONITOR_PID_FILE")
else
  producer_observed=no
fi
if wait_for_exit "$LIVE_TRIGGER_PID"; then
  prompt_exit=yes
else
  prompt_exit=no
fi
if [ -n "$LIVE_MONITOR_PID" ] && pid_is_alive "$LIVE_MONITOR_PID"; then
  producer_reaped=no
  stop_test_pid "$LIVE_MONITOR_PID"
  LIVE_MONITOR_PID=
else
  producer_reaped=yes
fi
if pid_is_alive "$LIVE_TRIGGER_PID"; then
  stop_test_pid "$LIVE_TRIGGER_PID"
  live_status=terminated_by_test
else
  if wait "$LIVE_TRIGGER_PID"; then live_status=0; else live_status=$?; fi
fi
LIVE_TRIGGER_PID=
if pid_is_alive "$UNRELATED_PID"; then unrelated_survived=yes; else unrelated_survived=no; fi
stop_test_pid "$UNRELATED_PID"
UNRELATED_PID=
test_start 'fatal reader state exits promptly while a live monitor keeps its stream open'
assert_eq "$producer_observed:$prompt_exit" 'yes:yes'
test_start 'fatal live-monitor reader returns nonzero without test intervention'
case $live_status in 0|terminated_by_test) fail "unexpected status $live_status" ;; *) pass ;; esac
test_start 'fatal reader state terminates and reaps only its owned monitor PID'
assert_eq "$producer_reaped:$unrelated_survived" 'yes:yes'
test_start 'fatal live-monitor cleanup removes the exact private startup artifacts'
if [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]; then pass; else fail 'private monitor artifacts remain'; fi

new_case live_monitor_signal
write_last_apply "$OLD_ENDPOINT"
unset V6PLUS_IDENTITY_PROBE_CMD
V6PLUS_MONITOR_CMD=$STUB/monitor-live
RUNTIME_LIVE_MONITOR_PID_FILE=$CASE/live-monitor.pid
RUNTIME_LIVE_MONITOR_RECORD='Deleted 2001:db8::1/64 dev eth9evil scope global'
RUNTIME_LIVE_MONITOR_IGNORE_TERM=1
TMPDIR=$CASE/tmp
export V6PLUS_MONITOR_CMD RUNTIME_LIVE_MONITOR_PID_FILE RUNTIME_LIVE_MONITOR_RECORD
export RUNTIME_LIVE_MONITOR_IGNORE_TERM TMPDIR
/bin/sleep 30 &
UNRELATED_PID=$!
"$SCRIPT" --config "$CASE/config" >"$CASE/stdout" 2>"$CASE/stderr" &
LIVE_TRIGGER_PID=$!
if wait_for_file "$RUNTIME_LIVE_MONITOR_PID_FILE"; then
  signal_producer_observed=yes
  LIVE_MONITOR_PID=$(cat "$RUNTIME_LIVE_MONITOR_PID_FILE")
else
  signal_producer_observed=no
fi
signal_ready_file=$(find "$CASE/tmp" -type f -name monitor-ready -print -quit)
signal_release_file=$(find "$CASE/tmp" -type f -name monitor-release -print -quit)
test_start 'startup handshake records are private regular mode-0600 files'
if [ -n "$signal_ready_file" ] && [ -n "$signal_release_file" ] &&
   [ ! -L "$signal_ready_file" ] && [ ! -L "$signal_release_file" ] &&
   [ "$(stat -c %a "$signal_ready_file")" = 600 ] &&
   [ "$(stat -c %a "$signal_release_file")" = 600 ]; then
  pass
else
  fail 'startup handshake files are absent, unsafe, or not private'
fi
signal_ready_values=$(awk -F= '
  function canonical(value, maximum) {
    return value ~ /^(0|[1-9][0-9]*)$/ && length(value) <= maximum
  }
  NF != 2 { bad=1; next }
  $1 == "SIGNAL_PID" && canonical($2, 10) && $2 != "0" && !signal_seen++ { signal_pid=$2; next }
  $1 == "PROC_PID" && canonical($2, 10) && $2 != "0" && !proc_seen++ { proc_pid=$2; next }
  $1 == "STARTTIME" && canonical($2, 20) && !start_seen++ { starttime=$2; next }
  { bad=1 }
  END {
    if (NR != 3 || signal_seen != 1 || proc_seen != 1 || start_seen != 1 || bad) exit 1
    print signal_pid, proc_pid, starttime
  }
' "$signal_ready_file" 2>/dev/null || true)
set -f
set -- $signal_ready_values
set +f
signal_ready_shape=bad
if [ "$#" -eq 3 ] && [ "$signal_ready_values" = "$1 $2 $3" ] &&
   [ "$1" = "$LIVE_MONITOR_PID" ] && [ "$(wc -c <"$signal_ready_file")" -le 160 ]; then
  ready_signal_pid=$1
  ready_proc_pid=$2
  ready_starttime=$3
  if IFS= read -r ready_stat_line <"/proc/$ready_proc_pid/stat" 2>/dev/null; then
    ready_stat_pid=${ready_stat_line%% *}
    ready_stat_tail=${ready_stat_line##*) }
    set -f
    set -- $ready_stat_tail
    set +f
    if [ "$#" -ge 20 ]; then
      shift 19
      ready_stat_start=$1
      ready_status_first=
      ready_status_last=
      while IFS= read -r ready_status_line; do
        case $ready_status_line in
          NSpid:*)
            set -f
            set -- $ready_status_line
            set +f
            shift
            ready_status_first=$1
            for ready_status_pid in "$@"; do ready_status_last=$ready_status_pid; done
            ;;
        esac
      done <"/proc/$ready_proc_pid/status"
      if [ "$ready_stat_pid:$ready_stat_start:$ready_status_first:$ready_status_last" = "$ready_proc_pid:$ready_starttime:$ready_proc_pid:$ready_signal_pid" ]; then
        signal_ready_shape=valid
      fi
    fi
  fi
fi
test_start 'READY has unique typed proc signal and starttime fields mapped through NSpid'
assert_eq "$signal_ready_shape" valid
kill -TERM "$LIVE_TRIGGER_PID" 2>/dev/null || :
if wait_for_exit "$LIVE_TRIGGER_PID"; then signal_prompt_exit=yes; else signal_prompt_exit=no; fi
if [ -n "$LIVE_MONITOR_PID" ] && pid_is_alive "$LIVE_MONITOR_PID"; then
  signal_producer_reaped=no
  stop_test_pid "$LIVE_MONITOR_PID"
  LIVE_MONITOR_PID=
else
  signal_producer_reaped=yes
fi
if pid_is_alive "$LIVE_TRIGGER_PID"; then
  stop_test_pid "$LIVE_TRIGGER_PID"
  signal_status=terminated_by_test
else
  if wait "$LIVE_TRIGGER_PID"; then signal_status=0; else signal_status=$?; fi
fi
LIVE_TRIGGER_PID=
if pid_is_alive "$UNRELATED_PID"; then signal_unrelated_survived=yes; else signal_unrelated_survived=no; fi
stop_test_pid "$UNRELATED_PID"
UNRELATED_PID=
test_start 'signal cleanup exits promptly with a non-cooperative owned monitor'
assert_eq "$signal_producer_observed:$signal_prompt_exit:$signal_status" 'yes:yes:143'
test_start 'signal cleanup reaps only the exact owned producer PID'
assert_eq "$signal_producer_reaped:$signal_unrelated_survived" 'yes:yes'
test_start 'signal cleanup removes its exact private monitor artifacts'
if [ -z "$(find "$CASE/tmp" -mindepth 1 -print -quit)" ]; then pass; else fail 'signal monitor artifacts remain'; fi

new_case unsafe_trigger_state
write_last_apply "$OLD_ENDPOINT"
printf 'Deleted 192.0.0.2/29 dev ip6tnl1\n3: ip6tnl1: <UP> mtu 1452\n' >"$CASE/monitor"
printf '100\n' >"$CASE/trigger-target"
ln -s "$CASE/trigger-target" "$CASE/state/last-trigger"
run_trigger
test_start 'symlink trigger state fails closed before apply'
assert_eq "$(count_lines "$CASE/apply.log")" 0
test_start 'fatal trigger state stops the monitor reader without repeated hot-loop logs'
assert_eq "$(grep -c 'ERROR phase=trigger_state' "$CASE/stderr" || true)" 1

new_case unsafe_apply_state
write_last_apply "$OLD_ENDPOINT" 644
printf 'Deleted 192.0.0.2/29 dev ip6tnl1\n' >"$CASE/monitor"
run_trigger
test_start 'insecure last-apply state fails closed before apply'
assert_eq "$(count_lines "$CASE/apply.log")" 0

new_case malformed_route
write_last_apply "$OLD_ENDPOINT"
printf '2001:db8:ffff::1 dev eth9 src not-an-ip\n' >"$CASE/route"
printf 'Deleted 2001:db8::1/64 dev eth9\n' >"$CASE/monitor"
run_trigger
test_start 'malformed route-selected endpoint prevents apply'
assert_eq "$(count_lines "$CASE/apply.log")" 0

new_case wrong_route_device
write_last_apply "$OLD_ENDPOINT"
printf '2001:db8:ffff::1 via fe80::1 dev br99 src 2001:db8:1234:31:abcd::1\n' >"$CASE/route"
printf 'Deleted 2001:db8::1/64 dev eth9\n' >"$CASE/monitor"
run_trigger
test_start 'route source from a different device fails closed before apply'
assert_eq "$(count_lines "$CASE/apply.log")" 0

new_case source_not_preferred
write_last_apply "$OLD_ENDPOINT"
printf '    inet6 2001:db8:1234:31:abcd::1/64 scope global tentative\n       valid_lft forever preferred_lft forever\n' >"$CASE/addr"
printf 'Deleted 2001:db8::1/64 dev eth9\n' >"$CASE/monitor"
run_trigger
test_start 'route source absent from preferred WAN addresses fails closed'
assert_eq "$(count_lines "$CASE/apply.log")" 0

new_case production_documentation_source
write_last_apply "$OLD_ENDPOINT"
sed -e 's/STATIC_V4=203\.0\.113\.42/STATIC_V4=198.18.0.42/' \
    -e 's/BR_V6=2001:db8:ffff::1/BR_V6=2400:1234:ffff::1/' \
    "$CASE/config/gateway.conf" >"$CASE/config/gateway.conf.new"
mv "$CASE/config/gateway.conf.new" "$CASE/config/gateway.conf"
printf '2400:1234:ffff::1 via fe80::1 dev eth9 src 2001:db8:1234:31:abcd::1\n' >"$CASE/route"
printf 'Deleted 2400:1234::1/64 dev eth9\n' >"$CASE/monitor"
unset V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
run_trigger
V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
test_start 'production mode rejects route-selected RFC 3849 source'
assert_eq "$(count_lines "$CASE/apply.log")" 0

test_finish
