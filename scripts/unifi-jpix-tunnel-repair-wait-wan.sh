#!/bin/sh
set -u

ROOT=${V6PLUS_ROOT:-/data/unifi-jpix-tunnel-repair}
CONFIG_DIR=$ROOT/config
TIMEOUT=300
config_seen=0
timeout_seen=0

usage() { printf 'usage: %s [--config DIR] [--timeout SECONDS]\n' "$0" >&2; }

normalize_uint() {
  [ "$#" -eq 1 ] || return 1
  case $1 in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 10 ] || return 1
  normalized_uint=$1
  while [ "$normalized_uint" != 0 ] && [ "${normalized_uint#0}" != "$normalized_uint" ]; do
    normalized_uint=${normalized_uint#0}
  done
  [ -n "$normalized_uint" ] || normalized_uint=0
  printf '%s\n' "$normalized_uint"
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --config)
      [ "$config_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      CONFIG_DIR=$2
      config_seen=1
      shift 2
      ;;
    --timeout)
      [ "$timeout_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      TIMEOUT=$(normalize_uint "$2") || { usage; exit 2; }
      timeout_seen=1
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

if [ "${V6PLUS_LIB+x}" = x ]; then LIB=$V6PLUS_LIB; else LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh; fi
[ -f "$LIB" ] || { printf 'wait library not found\n' >&2; exit 2; }
# This is trusted program code. Main configuration remains data parsed by the library.
. "$LIB"

V6_IP_CMD=${V6_IP_CMD:-ip}
V6_IPTABLES_CMD=${V6_IPTABLES_CMD:-iptables}
V6_IP6TABLES_CMD=${V6_IP6TABLES_CMD:-ip6tables}
V6_IPTABLES_SAVE_CMD=${V6_IPTABLES_SAVE_CMD:-iptables-save}
V6_IP6TABLES_SAVE_CMD=${V6_IP6TABLES_SAVE_CMD:-ip6tables-save}
V6_CURL_CMD=${V6_CURL_CMD:-curl}
V6_SYSTEMCTL_CMD=${V6_SYSTEMCTL_CMD:-systemctl}
V6_SLEEP_CMD=${V6_SLEEP_CMD:-sleep}

append_csv() {
  if [ -n "$1" ]; then printf '%s,%s\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}

MISSING_DEPENDENCIES=
require_command() {
  if ! command -v "$2" >/dev/null 2>&1; then
    MISSING_DEPENDENCIES=$(append_csv "$MISSING_DEPENDENCIES" "$1")
  fi
}

require_command ip "$V6_IP_CMD"
require_command iptables "$V6_IPTABLES_CMD"
require_command ip6tables "$V6_IP6TABLES_CMD"
require_command iptables-save "$V6_IPTABLES_SAVE_CMD"
require_command ip6tables-save "$V6_IP6TABLES_SAVE_CMD"
require_command curl "$V6_CURL_CMD"
require_command systemctl "$V6_SYSTEMCTL_CMD"
require_command sleep "$V6_SLEEP_CMD"
if [ "${V6PLUS_NOW_CMD+x}" = x ]; then
  require_command monotonic-clock "$V6PLUS_NOW_CMD"
fi
if [ -n "$MISSING_DEPENDENCIES" ]; then
  v6_log "ERROR missing_dependencies=$MISSING_DEPENDENCIES"
  exit 1
fi

if ! v6_load_main_config "$CONFIG_DIR/gateway.conf" "$CONFIG_DIR/routed-networks.conf" ||
   ! v6_validate_main_config; then
  printf 'invalid wait configuration\n' >&2
  exit 2
fi

monotonic_now() {
  if [ "${V6PLUS_NOW_CMD+x}" = x ]; then
    monotonic_raw=$("$V6PLUS_NOW_CMD") || return 1
  else
    [ -r /proc/uptime ] || return 1
    IFS=' ' read -r monotonic_uptime _ </proc/uptime || return 1
    monotonic_raw=${monotonic_uptime%%.*}
  fi
  normalize_uint "$monotonic_raw"
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
        if ($i == "tentative" || $i == "dadfailed" || $i == "deprecated") {
          address_is_preferred = 0
        }
        if ($i == "scope" && $(i + 1) == "global") address_is_global = 1
      }
      next
    }
    have_address && $1 == "valid_lft" {
      for (i = 1; i < NF; i++) {
        if ($i == "preferred_lft" && $(i + 1) ~ /^0(sec)?$/) {
          address_is_preferred = 0
        }
      }
    }
    END { emit_address() }
  '
}

preferred_global_present() {
  unset WAIT_PREFERRED_LISTING
  WAIT_PREFERRED_LISTING=$(preferred_address_tokens) || return 1
  if [ -n "$WAIT_PREFERRED_LISTING" ]; then
    unset WAIT_PREFERRED_LISTING
    return 0
  fi
  unset WAIT_PREFERRED_LISTING
  return 1
}

preferred_snapshot_has_source() {
  [ "$#" -eq 1 ] || return 1
  unset WAIT_PREFERRED_TOKENS WAIT_PREFERRED_TOKEN WAIT_PREFERRED_ADDRESS
  unset WAIT_PREFERRED_PREFIX WAIT_PREFERRED_FULL
  WAIT_PREFERRED_TOKENS=$(preferred_address_tokens) || return 1
  while IFS= read -r WAIT_PREFERRED_TOKEN || [ -n "$WAIT_PREFERRED_TOKEN" ]; do
    case $WAIT_PREFERRED_TOKEN in */*) ;; *) continue ;; esac
    WAIT_PREFERRED_PREFIX=${WAIT_PREFERRED_TOKEN##*/}
    case $WAIT_PREFERRED_PREFIX in ''|*[!0-9]*) continue ;; esac
    [ "${#WAIT_PREFERRED_PREFIX}" -le 3 ] && [ "$WAIT_PREFERRED_PREFIX" -le 128 ] || continue
    WAIT_PREFERRED_ADDRESS=${WAIT_PREFERRED_TOKEN%/*}
    WAIT_PREFERRED_ADDRESS=${WAIT_PREFERRED_ADDRESS%%%*}
    case $WAIT_PREFERRED_ADDRESS in ''|*/*|*%*) continue ;; esac
    WAIT_PREFERRED_FULL=$(v6_expand_ipv6 "$WAIT_PREFERRED_ADDRESS") || continue
    if [ "$WAIT_PREFERRED_FULL" = "$1" ]; then
      unset WAIT_PREFERRED_TOKENS WAIT_PREFERRED_TOKEN WAIT_PREFERRED_ADDRESS
      unset WAIT_PREFERRED_PREFIX WAIT_PREFERRED_FULL
      return 0
    fi
  done <<EOF
$WAIT_PREFERRED_TOKENS
EOF
  unset WAIT_PREFERRED_TOKENS WAIT_PREFERRED_TOKEN WAIT_PREFERRED_ADDRESS
  unset WAIT_PREFERRED_PREFIX WAIT_PREFERRED_FULL
  return 1
}

route_uses_device() {
  awk -v wanted_device="$1" '
    {
      is_default = ($1 == "default")
      for (i = 1; i < NF; i++) {
        if (is_default && $i == "dev" && $(i + 1) == wanted_device) found = 1
      }
    }
    END { exit !found }
  '
}

tunnel_is_ipip6() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "ipip6" || $i == "ip/ipv6" || $i == "any/ipv6" ||
            ($i == "mode" && ($(i + 1) == "ipip6" || $(i + 1) == "any"))) found = 1
      }
    }
    END { exit !found }
  '
}

br_route_source_from_snapshot() {
  awk -v wanted_device="$1" '
    {
      record_device = ""
      record_source = ""
      device_count = 0
      source_count = 0
      for (i = 1; i < NF; i++) {
        if ($i == "dev") {
          device_count++
          record_device = $(i + 1)
        }
        if ($i == "src") {
          source_count++
          record_source = $(i + 1)
        }
      }
      if (device_count == 1 && source_count == 1 && record_device == wanted_device && record_source != "") {
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

global_unicast_source() {
  [ "$#" -eq 1 ] || return 1
  case $1 in ''|*/*|*%*) return 1 ;; esac
  unset WAIT_GLOBAL_SOURCE_FULL WAIT_GLOBAL_SOURCE_FIRST
  WAIT_GLOBAL_SOURCE_FULL=$(v6_expand_ipv6 "$1") || return 1
  WAIT_GLOBAL_SOURCE_FIRST=${WAIT_GLOBAL_SOURCE_FULL%%:*}
  case $WAIT_GLOBAL_SOURCE_FIRST in
    [23][0-9a-f][0-9a-f][0-9a-f])
      case $WAIT_GLOBAL_SOURCE_FULL in
        2001:0db8:*)
          if [ "${V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES:-0}" != 1 ]; then
            unset WAIT_GLOBAL_SOURCE_FULL WAIT_GLOBAL_SOURCE_FIRST
            return 1
          fi
          ;;
      esac
      if ! printf '%s\n' "$WAIT_GLOBAL_SOURCE_FULL"; then
        unset WAIT_GLOBAL_SOURCE_FULL WAIT_GLOBAL_SOURCE_FIRST
        return 1
      fi
      unset WAIT_GLOBAL_SOURCE_FULL WAIT_GLOBAL_SOURCE_FIRST
      ;;
    *)
      unset WAIT_GLOBAL_SOURCE_FULL WAIT_GLOBAL_SOURCE_FIRST
      return 1
      ;;
  esac
}

poll_readiness() {
  MISSING_SET=

  WAIT_LINK_OUTPUT=$("$V6_IP_CMD" -o link show dev "$V6_WAN_IF" 2>/dev/null)
  WAIT_LINK_STATUS=$?
  if [ "$WAIT_LINK_STATUS" -ne 0 ]; then
    MISSING_SET=$(append_csv "$MISSING_SET" wan_link)
  else
    case $WAIT_LINK_OUTPUT in
      *'state UP'*|*LOWER_UP*) ;;
      *) MISSING_SET=$(append_csv "$MISSING_SET" wan_link) ;;
    esac
  fi

  WAIT_ADDR_OUTPUT=$("$V6_IP_CMD" -6 addr show dev "$V6_WAN_IF" scope global 2>/dev/null)
  WAIT_ADDR_STATUS=$?
  if [ "$WAIT_ADDR_STATUS" -ne 0 ] || ! preferred_global_present <<EOF
$WAIT_ADDR_OUTPUT
EOF
  then
    MISSING_SET=$(append_csv "$MISSING_SET" wan_global_v6)
  fi

  WAIT_DEFAULT_OUTPUT=$("$V6_IP_CMD" -6 route show default 2>/dev/null)
  WAIT_DEFAULT_STATUS=$?
  if [ "$WAIT_DEFAULT_STATUS" -ne 0 ] || ! route_uses_device "$V6_WAN_IF" <<EOF
$WAIT_DEFAULT_OUTPUT
EOF
  then
    MISSING_SET=$(append_csv "$MISSING_SET" wan_default_route)
  fi

  WAIT_TUNNEL_OUTPUT=$("$V6_IP_CMD" -d -6 tunnel show "$V6_TUN_IF" 2>/dev/null)
  WAIT_TUNNEL_STATUS=$?
  if [ "$WAIT_TUNNEL_STATUS" -ne 0 ] || ! tunnel_is_ipip6 <<EOF
$WAIT_TUNNEL_OUTPUT
EOF
  then
    MISSING_SET=$(append_csv "$MISSING_SET" tunnel_ipip6)
  fi

  WAIT_BR_OUTPUT=$("$V6_IP_CMD" -6 route get "$V6_BR_V6" 2>/dev/null)
  WAIT_BR_STATUS=$?
  WAIT_BR_SOURCE=$(br_route_source_from_snapshot "$V6_WAN_IF" <<EOF
$WAIT_BR_OUTPUT
EOF
  )
  WAIT_BR_SOURCE_STATUS=$?
  WAIT_BR_SOURCE_FULL=$(global_unicast_source "$WAIT_BR_SOURCE" 2>/dev/null)
  WAIT_BR_GLOBAL_STATUS=$?
  if [ "$WAIT_BR_STATUS" -ne 0 ] || [ "$WAIT_BR_SOURCE_STATUS" -ne 0 ] ||
     [ "$WAIT_BR_GLOBAL_STATUS" -ne 0 ] ||
     ! preferred_snapshot_has_source "$WAIT_BR_SOURCE_FULL" <<EOF
$WAIT_ADDR_OUTPUT
EOF
  then
    MISSING_SET=$(append_csv "$MISSING_SET" br_route_source)
  fi
}

START_TIME=$(monotonic_now) || { v6_log 'ERROR phase=monotonic_clock'; exit 1; }
PREVIOUS_MISSING=
POLL_ROUNDS=0

while :; do
  NOW_TIME=$(monotonic_now) || { v6_log 'ERROR phase=monotonic_clock'; exit 1; }
  [ "$NOW_TIME" -ge "$START_TIME" ] || { v6_log 'ERROR phase=monotonic_clock'; exit 1; }
  ELAPSED=$((NOW_TIME - START_TIME))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    if [ -n "$PREVIOUS_MISSING" ]; then TIMEOUT_MISSING=$PREVIOUS_MISSING; else TIMEOUT_MISSING=not_polled; fi
    v6_log "readiness timeout=$TIMEOUT missing=$TIMEOUT_MISSING"
    exit 1
  fi

  poll_readiness
  POLL_ROUNDS=$((POLL_ROUNDS + 1))
  NOW_TIME=$(monotonic_now) || { v6_log 'ERROR phase=monotonic_clock'; exit 1; }
  [ "$NOW_TIME" -ge "$START_TIME" ] || { v6_log 'ERROR phase=monotonic_clock'; exit 1; }
  ELAPSED=$((NOW_TIME - START_TIME))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    if [ -n "$MISSING_SET" ]; then TIMEOUT_MISSING=$MISSING_SET; else TIMEOUT_MISSING=none; fi
    v6_log "readiness timeout=$TIMEOUT missing=$TIMEOUT_MISSING"
    exit 1
  fi
  if [ -z "$MISSING_SET" ]; then
    v6_log "readiness ready elapsed=$ELAPSED rounds=$POLL_ROUNDS"
    exit 0
  fi
  if [ "$MISSING_SET" != "$PREVIOUS_MISSING" ]; then
    v6_log "readiness missing=$MISSING_SET"
    PREVIOUS_MISSING=$MISSING_SET
  fi
  "$V6_SLEEP_CMD" 1 || { v6_log 'ERROR phase=poll_sleep'; exit 1; }
done
