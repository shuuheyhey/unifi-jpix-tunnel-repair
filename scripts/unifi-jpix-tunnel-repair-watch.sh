#!/bin/sh
set -u

ROOT=${V6PLUS_ROOT:-/data/unifi-jpix-tunnel-repair}
CONFIG_DIR=$ROOT/config
ONCE=0
config_seen=0
once_seen=0

usage() { printf 'usage: %s [--config DIR] [--once]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --config)
      [ "$config_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      CONFIG_DIR=$2
      config_seen=1
      shift 2
      ;;
    --once)
      [ "$once_seen" -eq 0 ] || { usage; exit 2; }
      ONCE=1
      once_seen=1
      shift
      ;;
    *) usage; exit 2 ;;
  esac
done

if [ "${V6PLUS_LIB+x}" = x ]; then LIB=$V6PLUS_LIB; else LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh; fi
[ -f "$LIB" ] || { printf 'watch library not found\n' >&2; exit 2; }
# Trusted program code only. Configuration and state files are parsed strictly as data.
. "$LIB"

unset WATCH_PRE_V6 WATCH_POST_V6 WATCH_STATE_LOCAL watch_line watch_key watch_value
unset watch_state_local watch_state_expanded
v6_clear_ipv6_helper_scratch

V6PLUS_STATE_DIR=${V6PLUS_STATE_DIR:-/data/unifi-jpix-tunnel-repair/state}
V6PLUS_APPLY_CMD=${V6PLUS_APPLY_CMD:-$ROOT/scripts/unifi-jpix-tunnel-repair-apply.sh}
V6PLUS_UPDATE_CMD=${V6PLUS_UPDATE_CMD:-$ROOT/scripts/unifi-jpix-tunnel-repair-update.sh}
V6_SLEEP_CMD=${V6_SLEEP_CMD:-sleep}
LAST_APPLY_FILE=$V6PLUS_STATE_DIR/last-apply.env
WATCH_TEMP_DIR=
WATCH_STDOUT=
WATCH_STDERR=
LAST_CLOCK=
LAST_FAILURE_SUMMARY=

watch_cleanup() {
  if [ -n "$WATCH_TEMP_DIR" ]; then
    [ -z "$WATCH_STDOUT" ] || rm -f -- "$WATCH_STDOUT" 2>/dev/null || :
    [ -z "$WATCH_STDERR" ] || rm -f -- "$WATCH_STDERR" 2>/dev/null || :
    rmdir "$WATCH_TEMP_DIR" 2>/dev/null || :
  fi
}

trap 'watch_cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! v6_load_main_config "$CONFIG_DIR/gateway.conf" "$CONFIG_DIR/routed-networks.conf" ||
   ! v6_validate_main_config; then
  printf 'invalid watch configuration\n' >&2
  exit 2
fi
if [ "${V6PLUS_ALLOW_NONROOT:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  v6_log 'ERROR phase=privileges'
  exit 1
fi
v6_validate_state_dir || { v6_log 'ERROR phase=state_dir'; exit 1; }

if [ "${V6PLUS_TEST_MAX_CHECKS+x}" = x ]; then
  v6_is_canonical_uint10 "$V6PLUS_TEST_MAX_CHECKS" && [ "$V6PLUS_TEST_MAX_CHECKS" -gt 0 ] || { usage; exit 2; }
  WATCH_MAX_CHECKS=$V6PLUS_TEST_MAX_CHECKS
else
  WATCH_MAX_CHECKS=0
fi

for watch_command in "$V6PLUS_APPLY_CMD" "$V6PLUS_UPDATE_CMD" "$V6_SLEEP_CMD"; do
  command -v "$watch_command" >/dev/null 2>&1 || { v6_log 'ERROR phase=dependency'; exit 1; }
done
if [ "${V6PLUS_NOW_CMD+x}" = x ]; then
  command -v "$V6PLUS_NOW_CMD" >/dev/null 2>&1 || { v6_log 'ERROR phase=dependency'; exit 1; }
fi

WATCH_TEMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/unifi-jpix-tunnel-repair-watch.XXXXXX") || { v6_log 'ERROR phase=temp'; exit 1; }
chmod 700 "$WATCH_TEMP_DIR" || exit 1
WATCH_STDOUT=$WATCH_TEMP_DIR/command.out
WATCH_STDERR=$WATCH_TEMP_DIR/command.err
(umask 077 && : >"$WATCH_STDOUT" && : >"$WATCH_STDERR") || exit 1

clock_now() {
  unset watch_clock_raw watch_clock_uptime
  if [ "${V6PLUS_NOW+x}" = x ]; then
    watch_clock_raw=$V6PLUS_NOW
  elif [ "${V6PLUS_NOW_CMD+x}" = x ]; then
    watch_clock_raw=$("$V6PLUS_NOW_CMD") || return 1
  else
    [ -r /proc/uptime ] || return 1
    IFS=' ' read -r watch_clock_uptime _ </proc/uptime || return 1
    watch_clock_raw=${watch_clock_uptime%%.*}
  fi
  v6_is_canonical_uint10 "$watch_clock_raw" || return 1
  if [ -n "$LAST_CLOCK" ] && [ "$watch_clock_raw" -lt "$LAST_CLOCK" ]; then return 1; fi
  LAST_CLOCK=$watch_clock_raw
  WATCH_NOW=$watch_clock_raw
}

load_last_apply_local() {
  [ "$#" -eq 1 ] || return 2
  watch_state_path=$1
  v6_validate_private_file "$watch_state_path" 600 || return 2
  unset watch_state_local watch_state_nat watch_state_v6_chain watch_state_v6_managed watch_state_applied
  watch_seen_local=0
  watch_seen_nat=0
  watch_seen_chain=0
  watch_seen_managed=0
  watch_seen_applied=0
  while IFS= read -r watch_line || [ -n "$watch_line" ]; do
    case $watch_line in *=*) ;; *) return 2 ;; esac
    watch_key=${watch_line%%=*}
    watch_value=${watch_line#*=}
    v6_has_no_control_character "$watch_key" && v6_has_no_control_character "$watch_value" || return 2
    case $watch_key in
      LOCAL_V6) [ "$watch_seen_local" -eq 0 ] || return 2; watch_state_local=$watch_value; watch_seen_local=1 ;;
      NAT_CHAIN) [ "$watch_seen_nat" -eq 0 ] || return 2; watch_state_nat=$watch_value; watch_seen_nat=1 ;;
      V6_INPUT_CHAIN) [ "$watch_seen_chain" -eq 0 ] || return 2; watch_state_v6_chain=$watch_value; watch_seen_chain=1 ;;
      V6_INPUT_MANAGED) [ "$watch_seen_managed" -eq 0 ] || return 2; watch_state_v6_managed=$watch_value; watch_seen_managed=1 ;;
      APPLIED_AT) [ "$watch_seen_applied" -eq 0 ] || return 2; watch_state_applied=$watch_value; watch_seen_applied=1 ;;
      *) return 2 ;;
    esac
  done <"$watch_state_path" || return 2
  [ "$watch_seen_local$watch_seen_nat$watch_seen_chain$watch_seen_managed$watch_seen_applied" = 11111 ] || return 2
  watch_state_expanded=$(v6_expand_ipv6 "$watch_state_local") || return 2
  [ "$watch_state_expanded" = "$watch_state_local" ] || return 2
  v6_is_chain_value "$watch_state_nat" || return 2
  case $watch_state_v6_chain in none) ;; *) v6_is_chain_value "$watch_state_v6_chain" || return 2 ;; esac
  case $watch_state_v6_managed in yes|no) ;; *) return 2 ;; esac
  [ "$watch_state_v6_managed" = no ] || [ "$watch_state_v6_chain" != none ] || return 2
  v6_is_canonical_uint10 "$watch_state_applied" || return 2
  WATCH_STATE_LOCAL=$watch_state_local
  unset watch_state_local watch_state_expanded
}

read_pre_endpoint() {
  WATCH_PRE_V6=
  if [ ! -e "$LAST_APPLY_FILE" ] && [ ! -L "$LAST_APPLY_FILE" ]; then return 0; fi
  load_last_apply_local "$LAST_APPLY_FILE" || return 2
  WATCH_PRE_V6=$WATCH_STATE_LOCAL
}

read_post_endpoint() {
  load_last_apply_local "$LAST_APPLY_FILE" || return 2
  WATCH_POST_V6=$WATCH_STATE_LOCAL
}

failure_summary() {
  WATCH_FAILURE_SUMMARY=$(awk '
    function is_iface(value) {
      return length(value) >= 1 && length(value) <= 15 && value ~ /^[A-Za-z0-9_.:-]+$/
    }
    function is_fixed(name) {
      return name == "state_dir" || name == "state" || name == "state_local" ||
             name == "nat_chain" || name == "v6_input_chain" || name == "managed_networks" ||
             name == "wan_address" || name == "tunnel_mode" || name == "tunnel_local" ||
             name == "tunnel_remote" || name == "tunnel" || name == "tunnel_ipv4" ||
             name == "tunnel_ipv4_set" || name == "tunnel_mtu" || name == "tunnel_up" ||
             name == "tunnel_link" || name == "router_probe" || name == "route_default" ||
             name == "mss_forward_out" || name == "mss_forward_in" || name == "mss_output" ||
             name == "outer_rule" || name == "obsolete_wan_address" ||
             name == "reserved_routes" || name == "reserved_rules" ||
             name == "tagged_duplicates" || name == "tagged_rules"
    }
    function is_network_name(name, prefix, suffix) {
      prefix = name
      sub(/_.*/, "", prefix)
      if (prefix != "route" && prefix != "rule" && prefix != "snat") return 0
      suffix = substr(name, length(prefix) + 2)
      return is_iface(suffix)
    }
    $1 == "ERROR" {
      name=$2
      sub(/=.*/, "", name)
      if (length(name) <= 32 && (is_fixed(name) || is_network_name(name)) && !seen[name]++) {
        candidate = summary (summary == "" ? "" : ",") name
        if (length(candidate) <= 255) summary = candidate
      }
    }
    END { print summary == "" ? "unknown" : summary }
  ' "$WATCH_STDOUT") || return 1
}

run_status() {
  : >"$WATCH_STDOUT" || return 2
  : >"$WATCH_STDERR" || return 2
  "$V6PLUS_APPLY_CMD" --config "$CONFIG_DIR" status >"$WATCH_STDOUT" 2>"$WATCH_STDERR"
  WATCH_STATUS=$?
  case $WATCH_STATUS in
    0) WATCH_FAILURE_SUMMARY=healthy; return 0 ;;
    2) return 2 ;;
    *) failure_summary || return 2; return 1 ;;
  esac
}

run_repair() {
  WATCH_REPAIR_FAILURE_KIND=state
  read_pre_endpoint || return 2
  : >"$WATCH_STDOUT" || return 2
  : >"$WATCH_STDERR" || return 2
  WATCH_REPAIR_FAILURE_KIND=apply
  "$V6PLUS_APPLY_CMD" --config "$CONFIG_DIR" apply >"$WATCH_STDOUT" 2>"$WATCH_STDERR"
  watch_apply_status=$?
  [ "$watch_apply_status" -eq 0 ] || return "$watch_apply_status"
  WATCH_REPAIR_FAILURE_KIND=state
  read_post_endpoint || return 2
  if [ "$WATCH_PRE_V6" != "$WATCH_POST_V6" ]; then
    : >"$WATCH_STDOUT" || return 2
    : >"$WATCH_STDERR" || return 2
    if ! "$V6PLUS_UPDATE_CMD" --config "$CONFIG_DIR" --force >"$WATCH_STDOUT" 2>"$WATCH_STDERR"; then
      v6_log 'update=deferred reason=notification'
    fi
  fi
  unset WATCH_PRE_V6 WATCH_POST_V6 WATCH_STATE_LOCAL
  return 0
}

if [ "$ONCE" -eq 1 ]; then
  run_status
  once_status=$?
  case $once_status in
    0) exit 0 ;;
    1)
      failure_summary || { v6_log 'ERROR phase=status_summary'; exit 1; }
      v6_log "health=unhealthy summary=$WATCH_FAILURE_SUMMARY"
      run_repair
      once_repair=$?
      case $once_repair in
        0) v6_log 'repair=complete endpoint_change=checked'; exit 0 ;;
        1) v6_log 'repair=deferred reason=apply'; exit 1 ;;
        *)
          if [ "$WATCH_REPAIR_FAILURE_KIND" = apply ]; then
            v6_log 'ERROR phase=repair_apply'
            exit "$once_repair"
          fi
          v6_log 'ERROR phase=repair_state'
          exit 1
          ;;
      esac
      ;;
    *) v6_log 'ERROR phase=status'; exit 1 ;;
  esac
fi

WATCH_CHECKS=0
WATCH_FAILURES=0
WATCH_LAST_REPAIR=
while :; do
  clock_now || { v6_log 'ERROR phase=clock'; exit 1; }
  WATCH_CHECKS=$((WATCH_CHECKS + 1))
  run_status
  loop_status=$?
  case $loop_status in
    0)
      WATCH_FAILURES=0
      WATCH_LAST_REPAIR=
      if [ -n "$LAST_FAILURE_SUMMARY" ]; then v6_log 'health=ok'; fi
      LAST_FAILURE_SUMMARY=
      ;;
    1)
      if [ "$WATCH_FAILURE_SUMMARY" != "$LAST_FAILURE_SUMMARY" ]; then
        v6_log "health=unhealthy summary=$WATCH_FAILURE_SUMMARY"
        LAST_FAILURE_SUMMARY=$WATCH_FAILURE_SUMMARY
      fi
      [ "$WATCH_FAILURES" -ge 2 ] || WATCH_FAILURES=$((WATCH_FAILURES + 1))
      if [ "$WATCH_FAILURES" -ge 2 ]; then
        repair_due=1
        if [ -n "$WATCH_LAST_REPAIR" ] && [ "$WATCH_LAST_REPAIR" -le "$WATCH_NOW" ] &&
           [ $((WATCH_NOW - WATCH_LAST_REPAIR)) -lt 60 ]; then
          repair_due=0
        fi
        if [ "$repair_due" -eq 1 ]; then
          run_repair
          repair_status=$?
          case $repair_status in
            0) WATCH_FAILURES=0; WATCH_LAST_REPAIR=; v6_log 'repair=complete endpoint_change=checked' ;;
            1)
              clock_now || { v6_log 'ERROR phase=clock'; exit 1; }
              WATCH_LAST_REPAIR=$WATCH_NOW
              v6_log 'repair=deferred reason=apply'
              ;;
            *)
              if [ "$WATCH_REPAIR_FAILURE_KIND" = apply ]; then
                v6_log 'ERROR phase=repair_apply'
                exit "$repair_status"
              fi
              v6_log 'ERROR phase=repair_state'
              exit 1
              ;;
          esac
        fi
      fi
      ;;
    *) v6_log 'ERROR phase=status'; exit 1 ;;
  esac

  if [ "$WATCH_MAX_CHECKS" -gt 0 ] && [ "$WATCH_CHECKS" -ge "$WATCH_MAX_CHECKS" ]; then exit 0; fi
  "$V6_SLEEP_CMD" "$V6_WATCH_INTERVAL_SECONDS" || { v6_log 'ERROR phase=sleep'; exit 1; }
done
