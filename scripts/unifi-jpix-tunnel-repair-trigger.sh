#!/bin/sh
set -u

ROOT=${V6PLUS_ROOT:-/data/unifi-jpix-tunnel-repair}
CONFIG_DIR=$ROOT/config
config_seen=0

usage() { printf 'usage: %s [--config DIR]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --config)
      [ "$config_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      CONFIG_DIR=$2
      config_seen=1
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

if [ "${V6PLUS_LIB+x}" = x ]; then LIB=$V6PLUS_LIB; else LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh; fi
[ -f "$LIB" ] || { printf 'trigger library not found\n' >&2; exit 2; }
# Trusted program code only. Configuration and state are parsed below strictly as data.
. "$LIB"

unset TRIGGER_SOURCE_V6 TRIGGER_SOURCE_FULL TRIGGER_ENDPOINT_PREFIX TRIGGER_DESIRED_V6 TRIGGER_OLD_V6 TRIGGER_POST_V6 TRIGGER_STATE_LOCAL
unset TRIGGER_ROUTE_OUTPUT TRIGGER_ADDR_OUTPUT
unset trigger_line trigger_key trigger_value trigger_first trigger_second trigger_extra trigger_record
unset trigger_state_local trigger_state_expanded trigger_preferred_full trigger_preferred_tokens
unset trigger_preferred_address trigger_preferred_token trigger_preferred_prefix
unset proc_stat_line proc_stat_pid proc_stat_rest proc_stat_tail proc_stat_state proc_stat_field
unset proc_status_line proc_status_token proc_status_first proc_status_last proc_status_seen
unset PROC_PARSED_PID PROC_PARSED_STARTTIME PROC_STATUS_SIGNAL_PID
unset process_identity_output process_identity_proc_pid process_identity_signal_pid process_identity_start
unset READY_SIGNAL_PID READY_PROC_PID READY_STARTTIME
v6_clear_ipv6_helper_scratch
v6_clear_endpoint_helper_scratch

V6PLUS_STATE_DIR=${V6PLUS_STATE_DIR:-/data/unifi-jpix-tunnel-repair/state}
V6PLUS_MONITOR_CMD=${V6PLUS_MONITOR_CMD:-ip}
V6PLUS_APPLY_CMD=${V6PLUS_APPLY_CMD:-$ROOT/scripts/unifi-jpix-tunnel-repair-apply.sh}
V6PLUS_UPDATE_CMD=${V6PLUS_UPDATE_CMD:-$ROOT/scripts/unifi-jpix-tunnel-repair-update.sh}
V6_SLEEP_CMD=${V6_SLEEP_CMD:-sleep}
V6PLUS_STARTUP_SLEEP_CMD=${V6PLUS_STARTUP_SLEEP_CMD:-sleep}
V6PLUS_STARTUP_WAIT_TICKS=${V6PLUS_STARTUP_WAIT_TICKS:-5}
V6_MKFIFO_CMD=${V6_MKFIFO_CMD:-mkfifo}
V6_KILL_CMD=${V6_KILL_CMD:-kill}
LAST_APPLY_FILE=$V6PLUS_STATE_DIR/last-apply.env
LAST_TRIGGER_FILE=$V6PLUS_STATE_DIR/last-trigger
TRIGGER_TEMP_DIR=
TRIGGER_APPLY_OUT=
TRIGGER_APPLY_ERR=
TRIGGER_MONITOR_FIFO=
TRIGGER_READY_FILE=
TRIGGER_READY_TMP=
TRIGGER_RELEASE_FILE=
TRIGGER_RELEASE_TMP=
TRIGGER_MONITOR_SIGNAL_PID=
TRIGGER_MONITOR_PROC_PID=
TRIGGER_MONITOR_STARTTIME=
TRIGGER_STARTING=0
TRIGGER_RELEASE_SENT=0
TRIGGER_SIGNAL_PENDING=
LAST_CLOCK=
LAST_ATTEMPT=

trigger_clear_monitor() {
  TRIGGER_MONITOR_SIGNAL_PID=
  TRIGGER_MONITOR_PROC_PID=
  TRIGGER_MONITOR_STARTTIME=
  TRIGGER_RELEASE_SENT=0
}

trigger_wait_monitor() {
  if [ -n "$TRIGGER_MONITOR_SIGNAL_PID" ]; then
    wait "$TRIGGER_MONITOR_SIGNAL_PID" 2>/dev/null || :
    trigger_clear_monitor
  fi
}

trigger_stop_monitor() {
  if [ -n "$TRIGGER_MONITOR_SIGNAL_PID" ]; then
    if [ -n "$TRIGGER_MONITOR_PROC_PID" ] && [ -n "$TRIGGER_MONITOR_STARTTIME" ] &&
       process_identity_matches "$TRIGGER_MONITOR_PROC_PID" "$TRIGGER_MONITOR_SIGNAL_PID" "$TRIGGER_MONITOR_STARTTIME"; then
      "$V6_KILL_CMD" -TERM "$TRIGGER_MONITOR_SIGNAL_PID" 2>/dev/null || :
      if process_identity_matches "$TRIGGER_MONITOR_PROC_PID" "$TRIGGER_MONITOR_SIGNAL_PID" "$TRIGGER_MONITOR_STARTTIME"; then
        "$V6_KILL_CMD" -KILL "$TRIGGER_MONITOR_SIGNAL_PID" 2>/dev/null || :
      fi
    fi
    trigger_wait_monitor
  fi
}

trigger_release_startup() {
  [ "$#" -eq 1 ] || return 1
  [ -n "$TRIGGER_MONITOR_SIGNAL_PID" ] || return 1
  [ "$TRIGGER_RELEASE_SENT" -eq 0 ] || return 1
  trigger_write_handshake "$TRIGGER_RELEASE_FILE" "$1" || return 1
  TRIGGER_RELEASE_SENT=1
}

trigger_abort_startup() {
  if [ -n "$TRIGGER_MONITOR_SIGNAL_PID" ]; then
    if [ "$TRIGGER_RELEASE_SENT" -eq 0 ]; then
      trigger_release_startup STOP || :
    fi
    trigger_wait_monitor
  fi
  TRIGGER_STARTING=0
}

trigger_cleanup() {
  if [ "$TRIGGER_STARTING" -eq 1 ] && [ "$TRIGGER_RELEASE_SENT" -eq 0 ]; then
    trigger_abort_startup
  else
    trigger_stop_monitor
  fi
  if [ -n "$TRIGGER_TEMP_DIR" ]; then
    [ -z "$TRIGGER_APPLY_OUT" ] || rm -f -- "$TRIGGER_APPLY_OUT" 2>/dev/null || :
    [ -z "$TRIGGER_APPLY_ERR" ] || rm -f -- "$TRIGGER_APPLY_ERR" 2>/dev/null || :
    [ -z "$TRIGGER_MONITOR_FIFO" ] || rm -f -- "$TRIGGER_MONITOR_FIFO" 2>/dev/null || :
    [ -z "$TRIGGER_READY_FILE" ] || rm -f -- "$TRIGGER_READY_FILE" 2>/dev/null || :
    [ -z "$TRIGGER_READY_TMP" ] || rm -f -- "$TRIGGER_READY_TMP" 2>/dev/null || :
    [ -z "$TRIGGER_RELEASE_FILE" ] || rm -f -- "$TRIGGER_RELEASE_FILE" 2>/dev/null || :
    [ -z "$TRIGGER_RELEASE_TMP" ] || rm -f -- "$TRIGGER_RELEASE_TMP" 2>/dev/null || :
    rmdir "$TRIGGER_TEMP_DIR" 2>/dev/null || :
  fi
}

trigger_handle_signal() {
  [ -n "$TRIGGER_SIGNAL_PENDING" ] || TRIGGER_SIGNAL_PENDING=$1
  if [ "$TRIGGER_STARTING" -eq 0 ]; then exit "$TRIGGER_SIGNAL_PENDING"; fi
}

trap 'trigger_cleanup' EXIT
trap 'trigger_handle_signal 129' HUP
trap 'trigger_handle_signal 130' INT
trap 'trigger_handle_signal 143' TERM

case $V6PLUS_STARTUP_WAIT_TICKS in ''|*[!0-9]*|0|0[0-9]*)
  printf 'invalid trigger startup wait\n' >&2
  exit 2
  ;;
esac
[ "${#V6PLUS_STARTUP_WAIT_TICKS}" -le 3 ] &&
  [ "$V6PLUS_STARTUP_WAIT_TICKS" -le 300 ] || {
    printf 'invalid trigger startup wait\n' >&2
    exit 2
  }
if ! v6_load_main_config "$CONFIG_DIR/gateway.conf" "$CONFIG_DIR/routed-networks.conf" ||
   ! v6_validate_main_config; then
  printf 'invalid trigger configuration\n' >&2
  exit 2
fi
if [ "${V6PLUS_ALLOW_NONROOT:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  v6_log 'ERROR phase=privileges'
  exit 1
fi
v6_validate_state_dir || { v6_log 'ERROR phase=state_dir'; exit 1; }
for trigger_command in "$V6PLUS_MONITOR_CMD" "$V6PLUS_APPLY_CMD" "$V6PLUS_UPDATE_CMD" "$V6_SLEEP_CMD" "$V6PLUS_STARTUP_SLEEP_CMD" "$V6_MKFIFO_CMD" "$V6_KILL_CMD"; do
  command -v "$trigger_command" >/dev/null 2>&1 || { v6_log 'ERROR phase=dependency'; exit 1; }
done
if [ "${V6PLUS_IDENTITY_PROBE_CMD+x}" = x ]; then
  command -v "$V6PLUS_IDENTITY_PROBE_CMD" >/dev/null 2>&1 || { v6_log 'ERROR phase=dependency'; exit 1; }
fi

TRIGGER_NETWORKS=$(v6_iter_networks "$V6_NETWORKS_CONFIG") || { v6_log 'ERROR phase=networks'; exit 1; }
TRIGGER_TEMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/unifi-jpix-tunnel-repair-trigger.XXXXXX") || { v6_log 'ERROR phase=temp'; exit 1; }
chmod 700 "$TRIGGER_TEMP_DIR" || exit 1
TRIGGER_APPLY_OUT=$TRIGGER_TEMP_DIR/apply.out
TRIGGER_APPLY_ERR=$TRIGGER_TEMP_DIR/apply.err
(umask 077 && : >"$TRIGGER_APPLY_OUT" && : >"$TRIGGER_APPLY_ERR") || exit 1
TRIGGER_MONITOR_FIFO=$TRIGGER_TEMP_DIR/monitor.fifo
TRIGGER_READY_FILE=$TRIGGER_TEMP_DIR/monitor-ready
TRIGGER_READY_TMP=$TRIGGER_TEMP_DIR/monitor-ready.tmp
TRIGGER_RELEASE_FILE=$TRIGGER_TEMP_DIR/monitor-release
TRIGGER_RELEASE_TMP=$TRIGGER_TEMP_DIR/monitor-release.tmp
[ ! -e "$TRIGGER_MONITOR_FIFO" ] && [ ! -L "$TRIGGER_MONITOR_FIFO" ] || { v6_log 'ERROR phase=monitor_fifo'; exit 1; }
(umask 077 && "$V6_MKFIFO_CMD" "$TRIGGER_MONITOR_FIFO") || { v6_log 'ERROR phase=monitor_fifo'; exit 1; }
chmod 600 "$TRIGGER_MONITOR_FIFO" || { v6_log 'ERROR phase=monitor_fifo'; exit 1; }

trigger_write_handshake() {
  [ "$#" -eq 2 ] || return 1
  trigger_handshake_path=$1
  trigger_handshake_value=$2
  case $trigger_handshake_path in
    "$TRIGGER_READY_FILE") trigger_handshake_tmp=$TRIGGER_READY_TMP ;;
    "$TRIGGER_RELEASE_FILE") trigger_handshake_tmp=$TRIGGER_RELEASE_TMP ;;
    *) return 1 ;;
  esac
  [ ! -e "$trigger_handshake_path" ] && [ ! -L "$trigger_handshake_path" ] || return 1
  [ ! -e "$trigger_handshake_tmp" ] && [ ! -L "$trigger_handshake_tmp" ] || return 1
  (
    umask 077
    printf '%s\n' "$trigger_handshake_value" >"$trigger_handshake_tmp" &&
      chmod 600 "$trigger_handshake_tmp" &&
      mv -f -- "$trigger_handshake_tmp" "$trigger_handshake_path"
  ) || {
    rm -f -- "$trigger_handshake_tmp" 2>/dev/null || :
    return 1
  }
}

trigger_wait_handshake() {
  [ "$#" -eq 1 ] || return 1
  trigger_handshake_path=$1
  trigger_handshake_ticks=0
  while [ "$trigger_handshake_ticks" -lt "$V6PLUS_STARTUP_WAIT_TICKS" ]; do
    if [ -e "$trigger_handshake_path" ] || [ -L "$trigger_handshake_path" ]; then
      v6_validate_private_file "$trigger_handshake_path" 600
      return $?
    fi
    "$V6PLUS_STARTUP_SLEEP_CMD" 1 || return 1
    trigger_handshake_ticks=$((trigger_handshake_ticks + 1))
  done
  if [ -e "$trigger_handshake_path" ] || [ -L "$trigger_handshake_path" ]; then
    v6_validate_private_file "$trigger_handshake_path" 600
    return $?
  fi
  return 1
}

proc_is_canonical_uint() {
  [ "$#" -eq 2 ] || return 1
  case $1 in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#1}" -le "$2" ]
}

proc_is_canonical_int() {
  [ "$#" -eq 1 ] || return 1
  proc_int_value=$1
  case $proc_int_value in
    -*)
      proc_int_value=${proc_int_value#-}
      case $proc_int_value in ''|0|*[!0-9]*|0[0-9]*) return 1 ;; esac
      [ "${#proc_int_value}" -le 20 ]
      ;;
    *) proc_is_canonical_uint "$proc_int_value" 20 ;;
  esac
}

parse_proc_stat_line() {
  [ "$#" -eq 1 ] || return 1
  proc_stat_line=$1
  [ "${#proc_stat_line}" -le 4096 ] || return 1
  proc_stat_pid=${proc_stat_line%% *}
  [ "$proc_stat_pid" != "$proc_stat_line" ] || return 1
  proc_is_canonical_uint "$proc_stat_pid" 10 && [ "$proc_stat_pid" -gt 0 ] || return 1
  proc_stat_rest=${proc_stat_line#* }
  case $proc_stat_rest in \(*) ;; *) return 1 ;; esac
  proc_stat_tail=${proc_stat_rest##*) }
  [ "$proc_stat_tail" != "$proc_stat_rest" ] || return 1
  set -f
  set -- $proc_stat_tail
  set +f
  [ "$#" -ge 20 ] || return 1
  proc_stat_state=$1
  case $proc_stat_state in [A-Za-z]) ;; *) return 1 ;; esac
  shift
  proc_stat_field=4
  while [ "$proc_stat_field" -le 21 ]; do
    [ "$#" -gt 0 ] && proc_is_canonical_int "$1" || return 1
    shift
    proc_stat_field=$((proc_stat_field + 1))
  done
  [ "$#" -gt 0 ] && proc_is_canonical_uint "$1" 20 || return 1
  PROC_PARSED_PID=$proc_stat_pid
  PROC_PARSED_STARTTIME=$1
}

parse_proc_status_file() {
  [ "$#" -eq 2 ] || return 1
  process_identity_status_path=$1
  process_identity_status_proc_pid=$2
  proc_status_seen=0
  while IFS= read -r proc_status_line || [ -n "$proc_status_line" ]; do
    case $proc_status_line in NSpid:*) ;; *) continue ;; esac
    [ "$proc_status_seen" -eq 0 ] || return 1
    [ "${#proc_status_line}" -le 128 ] || return 1
    set -f
    set -- $proc_status_line
    set +f
    [ "$#" -ge 2 ] && [ "$1" = NSpid: ] || return 1
    shift
    proc_status_first=$1
    proc_status_last=
    for proc_status_token in "$@"; do
      proc_is_canonical_uint "$proc_status_token" 10 &&
        [ "$proc_status_token" -gt 0 ] || return 1
      proc_status_last=$proc_status_token
    done
    [ "$proc_status_first" = "$process_identity_status_proc_pid" ] || return 1
    proc_status_seen=1
  done <"$process_identity_status_path" 2>/dev/null || return 1
  [ "$proc_status_seen" -eq 1 ] || return 1
  PROC_STATUS_SIGNAL_PID=$proc_status_last
}

read_process_identity_files() {
  [ "$#" -eq 2 ] || return 1
  process_identity_stat_path=$1
  process_identity_status_path=$2
  IFS= read -r process_identity_output <"$process_identity_stat_path" 2>/dev/null || return 1
  parse_proc_stat_line "$process_identity_output" || return 1
  process_identity_proc_pid=$PROC_PARSED_PID
  process_identity_start=$PROC_PARSED_STARTTIME
  parse_proc_status_file "$process_identity_status_path" "$process_identity_proc_pid" || return 1
  process_identity_signal_pid=$PROC_STATUS_SIGNAL_PID
  PROCESS_IDENTITY_PROC_PID=$process_identity_proc_pid
  PROCESS_IDENTITY_SIGNAL_PID=$process_identity_signal_pid
  PROCESS_IDENTITY_STARTTIME=$process_identity_start
}

read_self_process_identity() {
  read_process_identity_files /proc/self/stat /proc/self/status
}

read_process_identity() {
  [ "$#" -eq 2 ] || return 1
  process_identity_wanted_proc_pid=$1
  process_identity_wanted_signal_pid=$2
  proc_is_canonical_uint "$process_identity_wanted_proc_pid" 10 &&
    [ "$process_identity_wanted_proc_pid" -gt 0 ] || return 1
  proc_is_canonical_uint "$process_identity_wanted_signal_pid" 10 &&
    [ "$process_identity_wanted_signal_pid" -gt 0 ] || return 1
  if [ "${V6PLUS_IDENTITY_PROBE_CMD+x}" = x ]; then
    process_identity_output=$("$V6PLUS_IDENTITY_PROBE_CMD" "$process_identity_wanted_proc_pid" "$process_identity_wanted_signal_pid" "$$") || return 1
    [ "${#process_identity_output}" -le 96 ] || return 1
    set -f
    set -- $process_identity_output
    set +f
    [ "$#" -eq 3 ] && [ "$process_identity_output" = "$1 $2 $3" ] || return 1
    process_identity_proc_pid=$1
    process_identity_signal_pid=$2
    process_identity_start=$3
    proc_is_canonical_uint "$process_identity_proc_pid" 10 && [ "$process_identity_proc_pid" -gt 0 ] || return 1
    proc_is_canonical_uint "$process_identity_signal_pid" 10 && [ "$process_identity_signal_pid" -gt 0 ] || return 1
    proc_is_canonical_uint "$process_identity_start" 20 || return 1
    PROCESS_IDENTITY_PROC_PID=$process_identity_proc_pid
    PROCESS_IDENTITY_SIGNAL_PID=$process_identity_signal_pid
    PROCESS_IDENTITY_STARTTIME=$process_identity_start
  else
    read_process_identity_files "/proc/$process_identity_wanted_proc_pid/stat" "/proc/$process_identity_wanted_proc_pid/status" || return 1
  fi
}

process_identity_matches() {
  [ "$#" -eq 3 ] || return 1
  process_identity_expected_proc_pid=$1
  process_identity_expected_signal_pid=$2
  process_identity_expected_start=$3
  read_process_identity "$process_identity_expected_proc_pid" "$process_identity_expected_signal_pid" || return 1
  [ "$PROCESS_IDENTITY_PROC_PID" = "$process_identity_expected_proc_pid" ] &&
    [ "$PROCESS_IDENTITY_SIGNAL_PID" = "$process_identity_expected_signal_pid" ] &&
    [ "$PROCESS_IDENTITY_STARTTIME" = "$process_identity_expected_start" ]
}

clock_now() {
  unset trigger_clock_raw trigger_clock_uptime
  if [ "${V6PLUS_NOW+x}" = x ]; then
    trigger_clock_raw=$V6PLUS_NOW
  elif [ "${V6PLUS_NOW_CMD+x}" = x ]; then
    trigger_clock_raw=$("$V6PLUS_NOW_CMD") || return 1
  else
    [ -r /proc/uptime ] || return 1
    IFS=' ' read -r trigger_clock_uptime _ </proc/uptime || return 1
    trigger_clock_raw=${trigger_clock_uptime%%.*}
  fi
  v6_is_canonical_uint10 "$trigger_clock_raw" || return 1
  if [ -n "$LAST_CLOCK" ] && [ "$trigger_clock_raw" -lt "$LAST_CLOCK" ]; then return 1; fi
  LAST_CLOCK=$trigger_clock_raw
  TRIGGER_NOW=$trigger_clock_raw
}

load_trigger_epoch() {
  TRIGGER_STORED=
  if [ ! -e "$LAST_TRIGGER_FILE" ] && [ ! -L "$LAST_TRIGGER_FILE" ]; then return 1; fi
  v6_validate_private_file "$LAST_TRIGGER_FILE" 600 || return 2
  trigger_epoch_count=0
  while IFS= read -r trigger_epoch_line || [ -n "$trigger_epoch_line" ]; do
    trigger_epoch_count=$((trigger_epoch_count + 1))
    [ "$trigger_epoch_count" -eq 1 ] || return 2
    v6_is_canonical_uint10 "$trigger_epoch_line" || return 2
    TRIGGER_STORED=$trigger_epoch_line
  done <"$LAST_TRIGGER_FILE" || return 2
  [ "$trigger_epoch_count" -eq 1 ] || return 2
}

load_last_apply_local() {
  [ "$#" -eq 1 ] || return 2
  trigger_state_path=$1
  v6_validate_private_file "$trigger_state_path" 600 || return 2
  unset trigger_state_local trigger_state_nat trigger_state_v6_chain trigger_state_v6_managed trigger_state_applied
  trigger_seen_local=0
  trigger_seen_nat=0
  trigger_seen_chain=0
  trigger_seen_managed=0
  trigger_seen_applied=0
  while IFS= read -r trigger_line || [ -n "$trigger_line" ]; do
    case $trigger_line in *=*) ;; *) return 2 ;; esac
    trigger_key=${trigger_line%%=*}
    trigger_value=${trigger_line#*=}
    v6_has_no_control_character "$trigger_key" && v6_has_no_control_character "$trigger_value" || return 2
    case $trigger_key in
      LOCAL_V6) [ "$trigger_seen_local" -eq 0 ] || return 2; trigger_state_local=$trigger_value; trigger_seen_local=1 ;;
      NAT_CHAIN) [ "$trigger_seen_nat" -eq 0 ] || return 2; trigger_state_nat=$trigger_value; trigger_seen_nat=1 ;;
      V6_INPUT_CHAIN) [ "$trigger_seen_chain" -eq 0 ] || return 2; trigger_state_v6_chain=$trigger_value; trigger_seen_chain=1 ;;
      V6_INPUT_MANAGED) [ "$trigger_seen_managed" -eq 0 ] || return 2; trigger_state_v6_managed=$trigger_value; trigger_seen_managed=1 ;;
      APPLIED_AT) [ "$trigger_seen_applied" -eq 0 ] || return 2; trigger_state_applied=$trigger_value; trigger_seen_applied=1 ;;
      *) return 2 ;;
    esac
  done <"$trigger_state_path" || return 2
  [ "$trigger_seen_local$trigger_seen_nat$trigger_seen_chain$trigger_seen_managed$trigger_seen_applied" = 11111 ] || return 2
  trigger_state_expanded=$(v6_expand_ipv6 "$trigger_state_local") || return 2
  [ "$trigger_state_expanded" = "$trigger_state_local" ] || return 2
  v6_is_chain_value "$trigger_state_nat" || return 2
  case $trigger_state_v6_chain in none) ;; *) v6_is_chain_value "$trigger_state_v6_chain" || return 2 ;; esac
  case $trigger_state_v6_managed in yes|no) ;; *) return 2 ;; esac
  [ "$trigger_state_v6_managed" = no ] || [ "$trigger_state_v6_chain" != none ] || return 2
  v6_is_canonical_uint10 "$trigger_state_applied" || return 2
  TRIGGER_STATE_LOCAL=$trigger_state_local
  unset trigger_state_local trigger_state_expanded
}

route_source_from_snapshot() {
  awk -v wanted_device="$1" '
    {
      record_device = ""
      record_source = ""
      device_count = 0
      source_count = 0
      for (i = 1; i < NF; i++) {
        if ($i == "dev") { device_count++; record_device = $(i + 1) }
        if ($i == "src") { source_count++; record_source = $(i + 1) }
      }
      if (device_count == 1 && source_count == 1 &&
          record_device == wanted_device && record_source != "") {
        matching_records++
        selected_source = record_source
      }
    }
    END {
      if (matching_records == 1) print selected_source
      else exit 1
    }
  '
}

preferred_address_tokens() {
  awk '
    function emit_address() {
      if (have_address && address_is_preferred && address_is_global) print address
    }
    $1 == "inet6" {
      emit_address()
      have_address = 1
      address = $2
      address_is_preferred = 1
      address_is_global = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "tentative" || $i == "dadfailed" || $i == "deprecated") address_is_preferred = 0
        if ($i == "scope" && $(i + 1) == "global") address_is_global = 1
      }
      next
    }
    have_address && $1 == "valid_lft" {
      for (i = 1; i < NF; i++) {
        if ($i == "preferred_lft" && $(i + 1) ~ /^0(sec)?$/) address_is_preferred = 0
      }
    }
    END { emit_address() }
  '
}

preferred_snapshot_has_source() {
  [ "$#" -eq 1 ] || return 1
  unset trigger_preferred_tokens trigger_preferred_token trigger_preferred_address
  unset trigger_preferred_prefix trigger_preferred_full
  trigger_preferred_tokens=$(preferred_address_tokens) || return 1
  while IFS= read -r trigger_preferred_token || [ -n "$trigger_preferred_token" ]; do
    case $trigger_preferred_token in */*) ;; *) continue ;; esac
    trigger_preferred_prefix=${trigger_preferred_token##*/}
    case $trigger_preferred_prefix in ''|*[!0-9]*) continue ;; esac
    [ "${#trigger_preferred_prefix}" -le 3 ] && [ "$trigger_preferred_prefix" -le 128 ] || continue
    trigger_preferred_address=${trigger_preferred_token%/*}
    trigger_preferred_address=${trigger_preferred_address%%%*}
    case $trigger_preferred_address in ''|*/*|*%*) continue ;; esac
    trigger_preferred_full=$(v6_expand_ipv6 "$trigger_preferred_address") || continue
    if [ "$trigger_preferred_full" = "$1" ]; then
      unset trigger_preferred_tokens trigger_preferred_token trigger_preferred_address
      unset trigger_preferred_prefix trigger_preferred_full
      return 0
    fi
  done <<EOF
$trigger_preferred_tokens
EOF
  unset trigger_preferred_tokens trigger_preferred_token trigger_preferred_address
  unset trigger_preferred_prefix trigger_preferred_full
  return 1
}

validated_desired_endpoint() {
  unset TRIGGER_SOURCE_V6 TRIGGER_SOURCE_FULL TRIGGER_ENDPOINT_PREFIX TRIGGER_DESIRED_V6
  unset TRIGGER_ROUTE_OUTPUT TRIGGER_ADDR_OUTPUT
  TRIGGER_ADDR_OUTPUT=$("$V6_IP_CMD" -6 addr show dev "$V6_WAN_IF" scope global 2>/dev/null) || return 1
  TRIGGER_ROUTE_OUTPUT=$("$V6_IP_CMD" -6 route get "$V6_BR_V6" 2>/dev/null) || return 1
  TRIGGER_SOURCE_V6=$(route_source_from_snapshot "$V6_WAN_IF" <<EOF
$TRIGGER_ROUTE_OUTPUT
EOF
  ) || return 1
  case $TRIGGER_SOURCE_V6 in ''|*/*|*%*) return 1 ;; esac
  TRIGGER_SOURCE_FULL=$(v6_expand_ipv6 "$TRIGGER_SOURCE_V6") || return 1
  case ${TRIGGER_SOURCE_FULL%%:*} in [23][0-9a-f][0-9a-f][0-9a-f]) ;; *) return 1 ;; esac
  if [ "${V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES:-0}" != 1 ]; then
    case $TRIGGER_SOURCE_FULL in 2001:0db8:*) return 1 ;; esac
  fi
  preferred_snapshot_has_source "$TRIGGER_SOURCE_FULL" <<EOF
$TRIGGER_ADDR_OUTPUT
EOF
  [ "$?" -eq 0 ] || return 1
  TRIGGER_ENDPOINT_PREFIX=$(v6_endpoint_prefix64 "$V6_ENDPOINT_IF") || return 1
  TRIGGER_DESIRED_V6=$(v6_compose_local_v6 "$TRIGGER_ENDPOINT_PREFIX" "$V6_IID") || return 1
  unset TRIGGER_SOURCE_V6 TRIGGER_SOURCE_FULL TRIGGER_ENDPOINT_PREFIX TRIGGER_ROUTE_OUTPUT TRIGGER_ADDR_OUTPUT
}

record_has_interface() {
  wanted_interface=$1
  shift
  previous_token=
  previous_previous_token=
  for current_token in "$@"; do
    if [ "$previous_token" = dev ] && [ "$current_token" = "$wanted_interface" ]; then return 0; fi
    case $previous_previous_token in
      *:)
        interface_index=${previous_previous_token%:}
        case $interface_index in
          ''|*[!0-9]*) ;;
          *)
            if [ "$previous_token" = "$wanted_interface" ]; then
              case $current_token in inet|inet6) return 0 ;; esac
            fi
            ;;
        esac
        ;;
    esac
    case $current_token in
      *:)
        link_token=${current_token%:}
        [ "$link_token" = "$wanted_interface" ] && return 0
        ;;
    esac
    previous_previous_token=$previous_token
    previous_token=$current_token
  done
  return 1
}

record_has_table() {
  previous_token=
  for current_token in "$@"; do
    if [ "$previous_token" = table ] && [ "$current_token" = "$V6_ROUTE_TABLE" ]; then return 0; fi
    previous_token=$current_token
  done
  return 1
}

record_is_relevant() {
  trigger_record=$1
  set -f
  set -- $trigger_record
  set +f
  [ "$#" -gt 0 ] || return 1
  record_has_interface "$V6_WAN_IF" "$@" && return 0
  record_has_interface "$V6_TUN_IF" "$@" && return 0
  record_has_table "$@" && return 0
  while IFS='|' read -r trigger_iface trigger_cidr; do
    [ -n "$trigger_iface" ] || continue
    record_has_interface "$trigger_iface" "$@" && return 0
  done <<EOF
$TRIGGER_NETWORKS
EOF
  return 1
}

within_cooldown() {
  [ "$#" -eq 2 ] || return 2
  trigger_previous=$1
  trigger_current=$2
  [ -n "$trigger_previous" ] || return 1
  [ "$trigger_previous" -le "$trigger_current" ] || return 1
  [ $((trigger_current - trigger_previous)) -lt 2 ]
}

write_trigger_epoch() {
  printf '%s\n' "$1" | v6_write_atomic 600 "$LAST_TRIGGER_FILE"
}

record_attempt_completion() {
  [ "$#" -eq 1 ] || return 2
  clock_now || { v6_log 'ERROR phase=clock'; return 2; }
  LAST_ATTEMPT=$TRIGGER_NOW
  if [ "$1" = persistent ]; then
    write_trigger_epoch "$TRIGGER_NOW" || { v6_log 'ERROR phase=trigger_state_write'; return 2; }
  fi
}

handle_relevant_event() {
  clock_now || { v6_log 'ERROR phase=clock'; return 2; }
  if within_cooldown "$LAST_ATTEMPT" "$TRIGGER_NOW"; then return 0; fi
  if load_trigger_epoch; then
    if within_cooldown "$TRIGGER_STORED" "$TRIGGER_NOW"; then return 0; fi
  else
    trigger_epoch_status=$?
    [ "$trigger_epoch_status" -eq 1 ] || { v6_log 'ERROR phase=trigger_state'; return 2; }
  fi

  "$V6_SLEEP_CMD" 2 || { v6_log 'ERROR phase=debounce'; return 2; }
  clock_now || { v6_log 'ERROR phase=clock'; return 2; }
  load_last_apply_local "$LAST_APPLY_FILE" || { v6_log 'ERROR phase=apply_state'; return 2; }
  TRIGGER_OLD_V6=$TRIGGER_STATE_LOCAL
  validated_desired_endpoint || { v6_log 'ERROR phase=endpoint'; return 2; }

  : >"$TRIGGER_APPLY_OUT" || return 2
  : >"$TRIGGER_APPLY_ERR" || return 2
  if ! "$V6PLUS_APPLY_CMD" --config "$CONFIG_DIR" apply >"$TRIGGER_APPLY_OUT" 2>"$TRIGGER_APPLY_ERR"; then
    record_attempt_completion transient || return $?
    v6_log 'repair=deferred reason=apply'
    return 0
  fi
  load_last_apply_local "$LAST_APPLY_FILE" || { v6_log 'ERROR phase=post_apply_state'; return 2; }
  TRIGGER_POST_V6=$TRIGGER_STATE_LOCAL
  if [ "$TRIGGER_POST_V6" != "$TRIGGER_DESIRED_V6" ]; then
    record_attempt_completion transient || return $?
    v6_log 'repair=deferred reason=endpoint_state'
    return 0
  fi
  if [ "$TRIGGER_OLD_V6" != "$TRIGGER_POST_V6" ]; then
    : >"$TRIGGER_APPLY_OUT" || return 2
    : >"$TRIGGER_APPLY_ERR" || return 2
    if ! "$V6PLUS_UPDATE_CMD" --config "$CONFIG_DIR" --force >"$TRIGGER_APPLY_OUT" 2>"$TRIGGER_APPLY_ERR"; then
      v6_log 'update=deferred reason=notification'
    fi
  fi
  record_attempt_completion persistent || return $?
  v6_log 'repair=complete endpoint_change=checked'
  unset TRIGGER_OLD_V6 TRIGGER_POST_V6 TRIGGER_DESIRED_V6 TRIGGER_STATE_LOCAL
  return 0
}

load_ready_identity() {
  [ "$#" -eq 1 ] || return 1
  ready_identity_path=$1
  READY_SIGNAL_PID=
  READY_PROC_PID=
  READY_STARTTIME=
  ready_signal_seen=0
  ready_proc_seen=0
  ready_start_seen=0
  ready_record_count=0
  ready_total_size=0
  while IFS= read -r ready_record || [ -n "$ready_record" ]; do
    ready_record_count=$((ready_record_count + 1))
    [ "$ready_record_count" -le 3 ] || return 1
    [ "${#ready_record}" -le 48 ] || return 1
    ready_total_size=$((ready_total_size + ${#ready_record} + 1))
    [ "$ready_total_size" -le 160 ] || return 1
    case $ready_record in *=*) ;; *) return 1 ;; esac
    ready_key=${ready_record%%=*}
    ready_value=${ready_record#*=}
    case $ready_value in *=*) return 1 ;; esac
    case $ready_key in
      SIGNAL_PID)
        [ "$ready_signal_seen" -eq 0 ] || return 1
        proc_is_canonical_uint "$ready_value" 10 && [ "$ready_value" -gt 0 ] || return 1
        READY_SIGNAL_PID=$ready_value
        ready_signal_seen=1
        ;;
      PROC_PID)
        [ "$ready_proc_seen" -eq 0 ] || return 1
        proc_is_canonical_uint "$ready_value" 10 && [ "$ready_value" -gt 0 ] || return 1
        READY_PROC_PID=$ready_value
        ready_proc_seen=1
        ;;
      STARTTIME)
        [ "$ready_start_seen" -eq 0 ] || return 1
        proc_is_canonical_uint "$ready_value" 20 || return 1
        READY_STARTTIME=$ready_value
        ready_start_seen=1
        ;;
      *) return 1 ;;
    esac
  done <"$ready_identity_path" || return 1
  [ "$ready_record_count" -eq 3 ] &&
    [ "$ready_signal_seen$ready_proc_seen$ready_start_seen" = 111 ]
}

start_monitor() {
  TRIGGER_STARTING=1
  TRIGGER_RELEASE_SENT=0
  (
    trap - 0
    trap '' 1 2 15
    monitor_child_ready=ERROR
    if read_self_process_identity; then
      monitor_child_ready="SIGNAL_PID=$PROCESS_IDENTITY_SIGNAL_PID
PROC_PID=$PROCESS_IDENTITY_PROC_PID
STARTTIME=$PROCESS_IDENTITY_STARTTIME"
    fi
    trigger_write_handshake "$TRIGGER_READY_FILE" "$monitor_child_ready" || exit 1
    trigger_wait_handshake "$TRIGGER_RELEASE_FILE" || exit 1
    monitor_child_release_count=0
    monitor_child_release=
    while IFS= read -r monitor_child_release_line || [ -n "$monitor_child_release_line" ]; do
      monitor_child_release_count=$((monitor_child_release_count + 1))
      [ "$monitor_child_release_count" -eq 1 ] || exit 1
      monitor_child_release=$monitor_child_release_line
    done <"$TRIGGER_RELEASE_FILE" || exit 1
    [ "$monitor_child_release_count" -eq 1 ] || exit 1
    [ "$monitor_child_release" = GO ] || exit 0
    trap - 1 2 15
    exec "$V6PLUS_MONITOR_CMD" -ts monitor link address route >"$TRIGGER_MONITOR_FIFO"
  ) &
  TRIGGER_MONITOR_SIGNAL_PID=$!

  monitor_start_valid=1
  if ! trigger_wait_handshake "$TRIGGER_READY_FILE"; then
    monitor_start_valid=0
  fi
  if [ "$monitor_start_valid" -eq 1 ]; then
    load_ready_identity "$TRIGGER_READY_FILE" || monitor_start_valid=0
  fi
  if [ "$monitor_start_valid" -eq 1 ]; then
    if [ "$READY_SIGNAL_PID" != "$TRIGGER_MONITOR_SIGNAL_PID" ]; then
      monitor_start_valid=0
    fi
  fi
  if [ "$monitor_start_valid" -eq 1 ]; then
    if ! process_identity_matches "$READY_PROC_PID" "$READY_SIGNAL_PID" "$READY_STARTTIME"; then
      monitor_start_valid=0
    fi
  fi
  if [ "$monitor_start_valid" -ne 1 ]; then
    trigger_abort_startup
    if [ -n "$TRIGGER_SIGNAL_PENDING" ]; then exit "$TRIGGER_SIGNAL_PENDING"; fi
    v6_log 'ERROR phase=monitor_identity'
    return 1
  fi

  TRIGGER_MONITOR_PROC_PID=$READY_PROC_PID
  TRIGGER_MONITOR_STARTTIME=$READY_STARTTIME
  monitor_start_decision=GO
  [ -z "$TRIGGER_SIGNAL_PENDING" ] || monitor_start_decision=STOP
  if ! trigger_release_startup "$monitor_start_decision"; then
    trigger_abort_startup
    if [ -n "$TRIGGER_SIGNAL_PENDING" ]; then exit "$TRIGGER_SIGNAL_PENDING"; fi
    v6_log 'ERROR phase=monitor_handshake'
    return 1
  fi
  if [ "$monitor_start_decision" = STOP ]; then
    trigger_wait_monitor
    TRIGGER_STARTING=0
    exit "$TRIGGER_SIGNAL_PENDING"
  fi
  TRIGGER_STARTING=0
  if [ -n "$TRIGGER_SIGNAL_PENDING" ]; then exit "$TRIGGER_SIGNAL_PENDING"; fi
}

start_monitor || exit 1
TRIGGER_READER_STATUS=0
while IFS= read -r trigger_record || [ -n "$trigger_record" ]; do
  record_is_relevant "$trigger_record" || continue
  handle_relevant_event
  trigger_event_status=$?
  if [ "$trigger_event_status" -ne 0 ]; then
    TRIGGER_READER_STATUS=$trigger_event_status
    break
  fi
done <"$TRIGGER_MONITOR_FIFO"

if [ "$TRIGGER_READER_STATUS" -ne 0 ]; then
  trigger_stop_monitor
  exit "$TRIGGER_READER_STATUS"
fi
trigger_wait_monitor
v6_log 'ERROR monitor=exited'
exit 1
