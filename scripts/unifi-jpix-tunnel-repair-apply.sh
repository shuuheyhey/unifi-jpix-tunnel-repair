#!/bin/sh
set -u

ROOT=${V6PLUS_ROOT:-/data/unifi-jpix-tunnel-repair}
CONFIG_DIR=$ROOT/config
DRY_RUN=0
ACTION=
config_seen=0
dry_run_seen=0

usage() { printf 'usage: %s [--config DIR] [--dry-run] apply|off|status\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --config)
      [ "$config_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      CONFIG_DIR=$2
      config_seen=1
      shift 2
      ;;
    --dry-run)
      [ "$dry_run_seen" -eq 0 ] || { usage; exit 2; }
      DRY_RUN=1
      dry_run_seen=1
      shift
      ;;
    apply|off|status)
      [ -z "$ACTION" ] && [ "$#" -eq 1 ] || { usage; exit 2; }
      ACTION=$1
      shift
      ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$ACTION" ] || { usage; exit 2; }
[ "$DRY_RUN" -eq 0 ] || [ "$ACTION" = apply ] || { usage; exit 2; }

if [ "${V6PLUS_LIB+x}" = x ]; then LIB=$V6PLUS_LIB; else LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh; fi
[ -f "$LIB" ] || { printf 'apply library not found\n' >&2; exit 2; }
# This is trusted program code. Configuration, state, and rollback records are never sourced.
. "$LIB"

V6PLUS_STATE_DIR=${V6PLUS_STATE_DIR:-/data/unifi-jpix-tunnel-repair/state}
V6PLUS_LOCK_DIR=${V6PLUS_LOCK_DIR:-/run/unifi-jpix-tunnel-repair.lock}
V6_IP_CMD=${V6_IP_CMD:-ip}
V6_IPTABLES_CMD=${V6_IPTABLES_CMD:-iptables}
V6_IP6TABLES_CMD=${V6_IP6TABLES_CMD:-ip6tables}
V6_IPTABLES_SAVE_CMD=${V6_IPTABLES_SAVE_CMD:-iptables-save}
V6_IP6TABLES_SAVE_CMD=${V6_IP6TABLES_SAVE_CMD:-ip6tables-save}
export DRY_RUN V6PLUS_STATE_DIR V6_IP_CMD V6_IPTABLES_CMD V6_IP6TABLES_CMD
export V6_IPTABLES_SAVE_CMD V6_IP6TABLES_SAVE_CMD

ORIGINAL_FILE=$V6PLUS_STATE_DIR/original-tunnel.env
MANAGED_FILE=$V6PLUS_STATE_DIR/managed-networks
LAST_FILE=$V6PLUS_STATE_DIR/last-apply.env
LOCK_HELD=0
WORK_DIR=
ROLLBACK_FILE=
MUTATION_ACTIVE=0
PRESERVE_WORK=0
PHYSICAL_MUTATED=0

apply_cleanup() {
  if [ "$MUTATION_ACTIVE" -eq 1 ] && [ -n "$ROLLBACK_FILE" ] && [ -f "$ROLLBACK_FILE" ]; then
    rollback_invocation || PRESERVE_WORK=1
  fi
  if [ "$PRESERVE_WORK" -eq 0 ] && [ -n "$WORK_DIR" ]; then
    rm -f -- "$WORK_DIR"/* 2>/dev/null || :
    rmdir "$WORK_DIR" 2>/dev/null || :
  elif [ "$PRESERVE_WORK" -eq 1 ]; then
    v6_log "ERROR rollback_work_preserved=$WORK_DIR"
  fi
  [ "$LOCK_HELD" -eq 1 ] || return 0
  v6_release_lock "$V6PLUS_LOCK_DIR"
}

acquire_shared_lock() {
  trap 'apply_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  LOCK_HELD=1
  if ! v6_acquire_lock "$V6PLUS_LOCK_DIR"; then LOCK_HELD=0; return 1; fi
}

make_work_dir() {
  WORK_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/unifi-jpix-tunnel-repair-apply.XXXXXX")
}

config_error() { printf 'invalid apply configuration: %s\n' "$*" >&2; return 2; }
runtime_error() { v6_log "ERROR phase=$1"; return 1; }

load_configuration() {
  v6_load_main_config "$CONFIG_DIR/gateway.conf" "$CONFIG_DIR/routed-networks.conf" || {
    config_error parse
    return 2
  }
  v6_validate_main_config || {
    config_error validation
    return 2
  }
}

require_root() {
  [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ] && return 0
  [ "$(id -u)" -eq 0 ] || { v6_log 'ERROR root privileges required'; return 1; }
}

seen_key_add() {
  seen_path=$1
  seen_key=$2
  grep -F -x -- "$seen_key" "$seen_path" >/dev/null 2>&1 && return 1
  printf '%s\n' "$seen_key" >>"$seen_path"
}

validate_state_file() {
  state_path=$1
  [ -f "$state_path" ] && [ ! -L "$state_path" ] || return 1
  state_mode=$(stat -c %a "$state_path" 2>/dev/null) || return 1
  state_owner=$(stat -c %u "$state_path" 2>/dev/null) || return 1
  [ "$state_mode" = 600 ] || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$state_owner" = "$(id -u)" ]
  else
    [ "$state_owner" = 0 ]
  fi
}

load_original_state() {
  original_path=$1
  unset ORIGINAL_TUN_IF ORIGINAL_TUN_MODE ORIGINAL_TUN_LOCAL ORIGINAL_TUN_REMOTE ORIGINAL_TUN_IPV4 ORIGINAL_TUN_MTU ORIGINAL_TUN_UP
  original_seen=$WORK_DIR/original.seen
  : >"$original_seen" || return 1
  while IFS= read -r original_line || [ -n "$original_line" ]; do
    case $original_line in *=*) ;; *) return 1 ;; esac
    original_key=${original_line%%=*}
    original_value=${original_line#*=}
    seen_key_add "$original_seen" "$original_key" || return 1
    case $original_key in
      TUN_IF) ORIGINAL_TUN_IF=$original_value ;;
      TUN_MODE) ORIGINAL_TUN_MODE=$original_value ;;
      TUN_LOCAL) ORIGINAL_TUN_LOCAL=$original_value ;;
      TUN_REMOTE) ORIGINAL_TUN_REMOTE=$original_value ;;
      TUN_IPV4) ORIGINAL_TUN_IPV4=$original_value ;;
      TUN_MTU) ORIGINAL_TUN_MTU=$original_value ;;
      TUN_UP) ORIGINAL_TUN_UP=$original_value ;;
      *) return 1 ;;
    esac
  done <"$original_path" || return 1
  [ "${ORIGINAL_TUN_IF+x}" = x ] && [ "${ORIGINAL_TUN_MODE+x}" = x ] &&
    [ "${ORIGINAL_TUN_LOCAL+x}" = x ] && [ "${ORIGINAL_TUN_REMOTE+x}" = x ] &&
    [ "${ORIGINAL_TUN_IPV4+x}" = x ] && [ "${ORIGINAL_TUN_MTU+x}" = x ] &&
    [ "${ORIGINAL_TUN_UP+x}" = x ] || return 1
  v6_is_iface_value "$ORIGINAL_TUN_IF" && tunnel_mode_command_safe "$ORIGINAL_TUN_MODE" &&
    v6_is_ip_value "$ORIGINAL_TUN_LOCAL" && v6_is_ipv6 "$ORIGINAL_TUN_LOCAL" &&
    v6_is_ip_value "$ORIGINAL_TUN_REMOTE" && v6_is_ipv6 "$ORIGINAL_TUN_REMOTE" &&
    v6_is_ip_value "$ORIGINAL_TUN_IPV4" && v6_is_cidr "$ORIGINAL_TUN_IPV4" &&
    v6_is_uint "$ORIGINAL_TUN_MTU" || return 1
  case $ORIGINAL_TUN_UP in yes|no) ;; *) return 1 ;; esac
}

load_last_state() {
  last_path=$1
  unset LAST_LOCAL_V6 LAST_NAT_CHAIN LAST_V6_INPUT_CHAIN LAST_V6_INPUT_MANAGED LAST_APPLIED_AT
  last_seen=$WORK_DIR/last.seen
  : >"$last_seen" || return 1
  while IFS= read -r last_line || [ -n "$last_line" ]; do
    case $last_line in *=*) ;; *) return 1 ;; esac
    last_key=${last_line%%=*}
    last_value=${last_line#*=}
    seen_key_add "$last_seen" "$last_key" || return 1
    case $last_key in
      LOCAL_V6) LAST_LOCAL_V6=$last_value ;;
      NAT_CHAIN) LAST_NAT_CHAIN=$last_value ;;
      V6_INPUT_CHAIN) LAST_V6_INPUT_CHAIN=$last_value ;;
      V6_INPUT_MANAGED) LAST_V6_INPUT_MANAGED=$last_value ;;
      APPLIED_AT) LAST_APPLIED_AT=$last_value ;;
      *) return 1 ;;
    esac
  done <"$last_path" || return 1
  [ "${LAST_LOCAL_V6+x}" = x ] && [ "${LAST_NAT_CHAIN+x}" = x ] &&
    [ "${LAST_V6_INPUT_CHAIN+x}" = x ] && [ "${LAST_V6_INPUT_MANAGED+x}" = x ] &&
    [ "${LAST_APPLIED_AT+x}" = x ] || return 1
  v6_is_ip_value "$LAST_LOCAL_V6" && v6_is_ipv6 "$LAST_LOCAL_V6" && v6_is_chain_value "$LAST_NAT_CHAIN" &&
    v6_is_uint "$LAST_APPLIED_AT" || return 1
  case $LAST_V6_INPUT_CHAIN in none) ;; *) v6_is_chain_value "$LAST_V6_INPUT_CHAIN" || return 1 ;; esac
  case $LAST_V6_INPUT_MANAGED in yes|no) ;; *) return 1 ;; esac
  [ "$LAST_V6_INPUT_MANAGED" = no ] || [ "$LAST_V6_INPUT_CHAIN" != none ]
}

load_managed_state() {
  managed_path=$1
  managed_output=$2
  : >"$managed_output" || return 1
  managed_seen=$WORK_DIR/managed.seen
  : >"$managed_seen" || return 1
  managed_count=0
  while IFS='|' read -r managed_iface managed_cidr managed_pref managed_extra ||
    [ -n "${managed_iface:-}${managed_cidr:-}${managed_pref:-}${managed_extra:-}" ]; do
    [ -n "$managed_iface" ] && [ -n "$managed_cidr" ] && [ -n "$managed_pref" ] && [ -z "$managed_extra" ] || return 1
    v6_is_iface_value "$managed_iface" && v6_is_cidr "$managed_cidr" &&
      v6_is_uint "$managed_pref" && [ "$managed_pref" -ge 1 ] && [ "$managed_pref" -le 32765 ] || return 1
    seen_key_add "$managed_seen" "IFACE|$managed_iface" &&
      seen_key_add "$managed_seen" "CIDR|$managed_cidr" &&
      seen_key_add "$managed_seen" "PREF|$managed_pref" || return 1
    printf '%s|%s|%s\n' "$managed_iface" "$managed_cidr" "$managed_pref" >>"$managed_output" || return 1
    managed_count=$((managed_count + 1))
  done <"$managed_path" || return 1
  [ "$managed_count" -gt 0 ]
}

read_token_after() {
  token_name=$1
  shift
  while [ "$#" -gt 1 ]; do
    if [ "$1" = "$token_name" ]; then printf '%s\n' "$2"; return 0; fi
    shift
  done
  return 1
}

tunnel_mode_command_safe() {
  case $1 in
    any|ipip6) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_tunnel_mode() {
  case $1 in
    any|any/ipv6) printf '%s\n' any ;;
    ipip6|ip/ipv6) printf '%s\n' ipip6 ;;
    *) return 1 ;;
  esac
}

current_tunnel() {
  tunnel_output=$("$V6_IP_CMD" -d -6 tunnel show "$V6_TUN_IF" 2>/dev/null) || return 1
  set -- $tunnel_output
  [ "$#" -ge 6 ] || return 1
  CURRENT_TUN_MODE=$(normalize_tunnel_mode "$2") || return 1
  CURRENT_TUN_LOCAL=$(read_token_after local "$@") || return 1
  CURRENT_TUN_REMOTE=$(read_token_after remote "$@") || return 1
  tunnel_mode_command_safe "$CURRENT_TUN_MODE" &&
    v6_is_ip_value "$CURRENT_TUN_LOCAL" && v6_is_ip_value "$CURRENT_TUN_REMOTE"
}

ipv6_values_equal() (
  [ "$#" -eq 2 ] || exit 2
  ipv6_values_left=$(v6_expand_ipv6 "$1") || exit 2
  ipv6_values_right=$(v6_expand_ipv6 "$2") || exit 2
  [ "$ipv6_values_left" = "$ipv6_values_right" ]
)

tunnel_endpoints_equal() {
  [ "$#" -eq 4 ] || return 2
  ipv6_values_equal "$1" "$2" || return $?
  ipv6_values_equal "$3" "$4"
}

current_tunnel_link() {
  link_output=$("$V6_IP_CMD" -o link show dev "$V6_TUN_IF" 2>/dev/null) || return 1
  set -- $link_output
  CURRENT_TUN_MTU=$(read_token_after mtu "$@") || return 1
  case "$link_output" in
    *'<UP,'*|*',UP,'*|*',UP>'*|*'<UP>'*) CURRENT_TUN_UP=yes ;;
    *) CURRENT_TUN_UP=no ;;
  esac
  v6_is_uint "$CURRENT_TUN_MTU"
}

current_tunnel_ipv4() {
  "$V6_IP_CMD" -4 addr show dev "$V6_TUN_IF" >"$WORK_DIR/current-tunnel-ipv4" 2>/dev/null || return 1
  CURRENT_TUN_IPV4=$(awk '/inet / { print $2; exit }' "$WORK_DIR/current-tunnel-ipv4")
  [ -n "$CURRENT_TUN_IPV4" ] && v6_is_ip_value "$CURRENT_TUN_IPV4"
}

addr6_exists() {
  "$V6_IP_CMD" -6 addr show dev "$1" >"$WORK_DIR/query-addr6" 2>/dev/null || return 2
  case $2 in
    */128) addr6_wanted_address=${2%/128} ;;
    *) return 2 ;;
  esac
  v6_expand_ipv6 "$addr6_wanted_address" >/dev/null || return 2
  while IFS= read -r addr6_line || [ -n "$addr6_line" ]; do
    set -- $addr6_line
    [ "$#" -ge 2 ] && [ "$1" = inet6 ] || continue
    case $2 in
      */*) addr6_candidate_address=${2%/*} ;;
      *) return 2 ;;
    esac
    v6_expand_ipv6 "$addr6_candidate_address" >/dev/null || return 2
    case $2 in
      */128)
        if ipv6_values_equal "$addr6_candidate_address" "$addr6_wanted_address"; then
          return 0
        else
          addr6_match_status=$?
          [ "$addr6_match_status" -eq 1 ] || return 2
        fi
        ;;
    esac
  done <"$WORK_DIR/query-addr6"
  return 1
}

addr4_exists() {
  "$V6_IP_CMD" -4 addr show dev "$1" >"$WORK_DIR/query-addr4" 2>/dev/null || return 2
  awk -v wanted="$2" '$1 == "inet" && $2 == wanted { found=1 } END { exit !found }' "$WORK_DIR/query-addr4"
}

static_ipv4_conflicts() {
  "$V6_IP_CMD" -4 addr show >"$WORK_DIR/current-all-ipv4" 2>/dev/null || return 2
  awk -v address="$V6_STATIC_V4" -v tunnel="$V6_TUN_IF" '
    $1 == "inet" { split($2, parts, "/"); if (parts[1] == address && $NF != tunnel) conflict=1 }
    END { exit !conflict }
  ' "$WORK_DIR/current-all-ipv4"
}

route4_exists() {
  "$V6_IP_CMD" -4 route show table "$1" >"$WORK_DIR/query-routes" 2>/dev/null || return 2
  awk -v destination="$2" -v iface="$3" '
    $1 == destination {
      for (i=2; i<NF; i++) if ($i == "dev" && $(i+1) == iface) found=1
    }
    END { exit !found }
  ' "$WORK_DIR/query-routes"
}

v6_is_route_token() {
  case $1 in
    ''|*[!A-Za-z0-9_.:/,@%+=-]*) return 1 ;;
    *) return 0 ;;
  esac
}

validate_route_vector() {
  route_vector_to_validate=$1
  set -f
  set -- $route_vector_to_validate
  set +f
  [ "$#" -ge 3 ] && v6_is_cidr_or_default "$1" || return 1
  route_vector_dev_count=0
  route_vector_previous=
  for route_vector_token in "$@"; do
    v6_is_route_token "$route_vector_token" || return 1
    if [ "$route_vector_previous" = dev ]; then
      v6_is_iface_value "$route_vector_token" || return 1
      route_vector_dev_count=$((route_vector_dev_count + 1))
    fi
    route_vector_previous=$route_vector_token
  done
  [ "$route_vector_dev_count" -eq 1 ]
}

canonical_route_vector() {
  validate_route_vector "$1" || return 1
  set -- $1
  route_vector_output=
  for route_vector_token in "$@"; do
    if [ -n "$route_vector_output" ]; then route_vector_output="$route_vector_output $route_vector_token"; else route_vector_output=$route_vector_token; fi
  done
  printf '%s\n' "$route_vector_output"
}

route_vector_matches() {
  validate_route_vector "$1" || return 2
  route_match_destination=$2
  route_match_iface=$3
  set -- $1
  [ "$1" = "$route_match_destination" ] || return 1
  route_match_actual_iface=$(read_token_after dev "$@") || return 2
  [ "$route_match_actual_iface" = "$route_match_iface" ]
}

capture_route4_vector() {
  capture_route_table=$1
  capture_route_destination=$2
  capture_route_iface=$3
  capture_route_output=$4
  "$V6_IP_CMD" -4 route show table "$capture_route_table" >"$WORK_DIR/capture-routes" 2>/dev/null || return 2
  : >"$capture_route_output" || return 2
  capture_route_found=0
  while IFS= read -r capture_route_line || [ -n "$capture_route_line" ]; do
    [ -n "$capture_route_line" ] || continue
    capture_route_canonical=$(canonical_route_vector "$capture_route_line") || return 2
    if route_vector_matches "$capture_route_canonical" "$capture_route_destination" "$capture_route_iface"; then
      capture_route_found=$((capture_route_found + 1))
      printf '%s\n' "$capture_route_canonical" >"$capture_route_output" || return 2
    else
      capture_route_status=$?
      [ "$capture_route_status" -eq 1 ] || return 2
    fi
  done <"$WORK_DIR/capture-routes"
  case $capture_route_found in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac
}

restore_route4_vector() {
  restore_route_table=$1
  restore_route_vector=$2
  v6_is_uint "$restore_route_table" && validate_route_vector "$restore_route_vector" || return 1
  set -- $restore_route_vector
  v6_run "$V6_IP_CMD" -4 route replace table "$restore_route_table" "$@"
}

rule4_exists() {
  "$V6_IP_CMD" -4 rule show >"$WORK_DIR/query-rules" 2>/dev/null || return 2
  awk -v pref="$1" -v iface="$2" -v table="$3" '
    { p=$1; sub(/:$/, "", p) }
    p == pref && $4 == "iif" && $5 == iface && $6 == "lookup" && $7 == table { found=1 }
    END { exit !found }
  ' "$WORK_DIR/query-rules"
}

rule4_count() {
  "$V6_IP_CMD" -4 rule show >"$WORK_DIR/query-rule-count" 2>/dev/null || return 2
  awk -v pref="$1" -v iface="$2" -v table="$3" '
    { p=$1; sub(/:$/, "", p) }
    NF == 7 && p == pref && $2 == "from" && $3 == "all" && $4 == "iif" &&
      $5 == iface && $6 == "lookup" && $7 == table { count++ }
    END { print count+0 }
  ' "$WORK_DIR/query-rule-count"
}

outer_unmanaged_exact_exists() {
  outer_chain=$1
  outer_local=$2
  "$V6_IP6TABLES_CMD" -S "$outer_chain" >"$WORK_DIR/outer-unmanaged-raw" 2>/dev/null || return 2
  normalize_firewall <"$WORK_DIR/outer-unmanaged-raw" >"$WORK_DIR/outer-unmanaged" || return 2
  awk -v chain="$outer_chain" -v source="$V6_BR_V6/128" -v destination="$outer_local/128" '
    $1 == "-A" && $2 == chain && $3 == "-s" && $4 == source &&
      $5 == "-d" && $6 == destination && $7 == "-p" && $8 == "4" &&
      $9 == "-j" && $10 == "ACCEPT" && NF == 10 { found=1 }
    END { exit !found }
  ' "$WORK_DIR/outer-unmanaged"
}

managed_tag_exists() {
  capture_firewall_snapshot first-target-firewall || return 2
  capture_firewall_inventory first-inventory || return 2
  extract_inventory_tagged "$WORK_DIR/first-inventory-all" "$WORK_DIR/first-inventory-tagged" || return 2
  [ -s "$WORK_DIR/first-inventory-tagged" ]
}

firewall_tag_count() {
  awk '
    {
      tagged=0
      for (i=1; i<NF; i++) if ($i == "--comment" && $(i+1) == "unifi-jpix-tunnel-repair") tagged=1
      if (tagged) count++
    }
    END { print count+0 }
  ' "$@"
}

capture_firewall_snapshot() {
  snapshot_prefix=$1
  "$V6_IPTABLES_CMD" -t nat -S >"$WORK_DIR/$snapshot_prefix-nat-raw" 2>/dev/null || return 1
  "$V6_IPTABLES_CMD" -t mangle -S >"$WORK_DIR/$snapshot_prefix-mangle-raw" 2>/dev/null || return 1
  "$V6_IP6TABLES_CMD" -S >"$WORK_DIR/$snapshot_prefix-v6-raw" 2>/dev/null || return 1
  normalize_firewall <"$WORK_DIR/$snapshot_prefix-nat-raw" >"$WORK_DIR/$snapshot_prefix-nat" || return 1
  normalize_firewall <"$WORK_DIR/$snapshot_prefix-mangle-raw" >"$WORK_DIR/$snapshot_prefix-mangle" || return 1
  normalize_firewall <"$WORK_DIR/$snapshot_prefix-v6-raw" >"$WORK_DIR/$snapshot_prefix-v6" || return 1
}

validate_tagged_subset() {
  tagged_snapshot=$1
  tagged_allowed=$2
  tagged_output=$3
  tagged_allow_duplicates=${4:-no}
  awk '{ tagged=0; for (i=1; i<NF; i++) if ($i == "--comment" && $(i+1) == "unifi-jpix-tunnel-repair") tagged=1; if (tagged) print }' \
    "$tagged_snapshot" >"$tagged_output" || return 1
  [ "$tagged_allow_duplicates" = yes ] || [ -z "$(sort "$tagged_output" | uniq -d)" ] || return 1
  while IFS= read -r tagged_line || [ -n "$tagged_line" ]; do
    grep -F -x -- "$tagged_line" "$tagged_allowed" >/dev/null 2>&1 || return 1
  done <"$tagged_output"
}

verify_present_iptables_exact() {
  present_snapshot=$1
  present_table=$2
  present_chain=$3
  shift 3
  present_expected=$(firewall_expected_line "$present_chain" "$@") || return 1
  grep -F -x -- "$present_expected" "$present_snapshot" >/dev/null 2>&1 || return 0
  require_iptables_exact "$present_table" "$present_chain" "$@"
}

verify_present_ip6tables_exact() {
  present_snapshot=$1
  present_chain=$2
  shift 2
  present_expected=$(firewall_expected_line "$present_chain" "$@") || return 1
  grep -F -x -- "$present_expected" "$present_snapshot" >/dev/null 2>&1 || return 0
  require_ip6tables_exact "$present_chain" "$@"
}

require_iptables_exact() {
  if iptables_rule_exists "$@"; then return 0; else require_status=$?; [ "$require_status" -eq 1 ] || return 2; return 1; fi
}

require_ip6tables_exact() {
  if ip6tables_rule_exists "$@"; then return 0; else require_status=$?; [ "$require_status" -eq 1 ] || return 2; return 1; fi
}

record_inverse() {
  [ -n "$ROLLBACK_FILE" ] || return 1
  inverse_to_record=$*
  inverse_record_type=${inverse_to_record%%|*}
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ] && [ "${V6PLUS_TEST_FAIL_JOURNAL_TYPE:-}" = "$inverse_record_type" ]; then
    return 1
  fi
  journal_next=$WORK_DIR/journal.next
  {
    [ ! -f "$ROLLBACK_FILE" ] || cat "$ROLLBACK_FILE"
    printf '%s\n' "$inverse_to_record"
  } >"$journal_next" || return 1
  v6_write_atomic 600 "$ROLLBACK_FILE" <"$journal_next"
}

inverse_record() {
  inverse_line=$1
  IFS='|' read -r inverse_type inverse_a inverse_b inverse_c inverse_d inverse_extra <<EOF
$inverse_line
EOF
  [ -z "$inverse_extra" ] || return 1
  case $inverse_type in
    ADDR6_ABSENT) inverse_addr6_absent "$inverse_a" "$inverse_b" ;;
    ADDR6_PRESENT) v6_is_iface_value "$inverse_a" && v6_is_ip_value "$inverse_b" && v6_run "$V6_IP_CMD" -6 addr replace "$inverse_b" dev "$inverse_a" ;;
    ADDR4_ABSENT) inverse_addr4_absent "$inverse_a" "$inverse_b" ;;
    ADDR4_PRESENT) v6_is_iface_value "$inverse_a" && v6_is_ip_value "$inverse_b" && v6_run "$V6_IP_CMD" -4 addr replace "$inverse_b" dev "$inverse_a" ;;
    TUNNEL_CHANGE)
      v6_is_iface_value "$inverse_a" && tunnel_mode_command_safe "$inverse_b" && v6_is_ip_value "$inverse_c" && v6_is_ip_value "$inverse_d" &&
        v6_run "$V6_IP_CMD" -6 tunnel change "$inverse_a" mode "$inverse_b" local "$inverse_c" remote "$inverse_d"
      ;;
    LINK_SET)
      v6_is_iface_value "$inverse_a" && v6_is_uint "$inverse_b" || return 1
      case $inverse_c in yes) inverse_link_state=up ;; no) inverse_link_state=down ;; *) return 1 ;; esac
      v6_run "$V6_IP_CMD" link set dev "$inverse_a" mtu "$inverse_b" "$inverse_link_state"
      ;;
    ROUTE4_ABSENT) inverse_route4_absent "$inverse_a" "$inverse_b" "$inverse_c" ;;
    ROUTE4_PRESENT) [ -z "$inverse_c" ] && v6_is_uint "$inverse_a" && restore_route4_vector "$inverse_a" "$inverse_b" ;;
    RULE4_ABSENT) inverse_rule4_absent "$inverse_a" "$inverse_b" "$inverse_c" ;;
    RULE4_PRESENT) inverse_rule4_present "$inverse_a" "$inverse_b" "$inverse_c" ;;
    RULE4_RESTORE) inverse_rule4_restore "$inverse_a" "$inverse_b" "$inverse_c" "$inverse_d" ;;
    SNAT_RESTORE) inverse_snat_restore "$inverse_a" "$inverse_b" "$inverse_c" ;;
    MSS_OUT_RESTORE) inverse_mss_out_restore "$inverse_a" ;;
    MSS_IN_RESTORE) inverse_mss_in_restore "$inverse_a" ;;
    MSS_OUTPUT_RESTORE) inverse_mss_output_restore "$inverse_a" ;;
    OUTER_RESTORE) inverse_outer_restore "$inverse_a" "$inverse_b" "$inverse_c" "$inverse_d" ;;
    ORIGINAL_REMOVE) [ ! -e "$ORIGINAL_FILE" ] || rm -f -- "$ORIGINAL_FILE" ;;
    STATE_MANAGED_REMOVE) [ ! -e "$MANAGED_FILE" ] || rm -f -- "$MANAGED_FILE" ;;
    STATE_MANAGED_RESTORE) [ -f "$WORK_DIR/previous-managed" ] && v6_write_atomic 600 "$MANAGED_FILE" <"$WORK_DIR/previous-managed" ;;
    STATE_LAST_REMOVE) [ ! -e "$LAST_FILE" ] || rm -f -- "$LAST_FILE" ;;
    STATE_LAST_RESTORE) [ -f "$WORK_DIR/previous-last" ] && v6_write_atomic 600 "$LAST_FILE" <"$WORK_DIR/previous-last" ;;
    *) return 1 ;;
  esac
}

v6_is_cidr_or_default() { [ "$1" = default ] || v6_is_cidr "$1"; }

inverse_addr6_absent() {
  v6_is_iface_value "$1" && v6_is_ip_value "$2" || return 1
  if addr6_exists "$1" "$2"; then v6_run "$V6_IP_CMD" -6 addr del "$2" dev "$1"; else inverse_status=$?; [ "$inverse_status" -eq 1 ]; fi
}
inverse_addr4_absent() {
  v6_is_iface_value "$1" && v6_is_ip_value "$2" || return 1
  if addr4_exists "$1" "$2"; then v6_run "$V6_IP_CMD" -4 addr del "$2" dev "$1"; else inverse_status=$?; [ "$inverse_status" -eq 1 ]; fi
}
inverse_route4_absent() {
  v6_is_uint "$1" && v6_is_cidr_or_default "$2" && v6_is_iface_value "$3" || return 1
  if route4_exists "$1" "$2" "$3"; then v6_run "$V6_IP_CMD" -4 route del table "$1" "$2" dev "$3"; else inverse_status=$?; [ "$inverse_status" -eq 1 ]; fi
}
inverse_rule4_absent() {
  v6_is_uint "$1" && v6_is_iface_value "$2" && v6_is_uint "$3" || return 1
  if rule4_exists "$1" "$2" "$3"; then v6_run "$V6_IP_CMD" -4 rule del pref "$1" iif "$2" lookup "$3"; else inverse_status=$?; [ "$inverse_status" -eq 1 ]; fi
}
inverse_rule4_present() {
  v6_is_uint "$1" && v6_is_iface_value "$2" && v6_is_uint "$3" || return 1
  if rule4_exists "$1" "$2" "$3"; then return 0; else inverse_status=$?; [ "$inverse_status" -eq 1 ] || return 1; fi
  v6_run "$V6_IP_CMD" -4 rule add pref "$1" iif "$2" lookup "$3"
}
inverse_rule4_restore() {
  inverse_rule_pref=$1
  inverse_rule_iface=$2
  inverse_rule_table=$3
  inverse_rule_count=$4
  v6_is_uint "$inverse_rule_pref" && v6_is_iface_value "$inverse_rule_iface" &&
    v6_is_uint "$inverse_rule_table" && v6_is_uint "$inverse_rule_count" || return 1
  while :; do
    if rule4_exists "$inverse_rule_pref" "$inverse_rule_iface" "$inverse_rule_table"; then
      v6_run "$V6_IP_CMD" -4 rule del pref "$inverse_rule_pref" iif "$inverse_rule_iface" lookup "$inverse_rule_table" || return 1
    else
      inverse_rule_status=$?
      [ "$inverse_rule_status" -eq 1 ] || return 1
      break
    fi
  done
  while [ "$inverse_rule_count" -gt 0 ]; do
    v6_run "$V6_IP_CMD" -4 rule add pref "$inverse_rule_pref" iif "$inverse_rule_iface" lookup "$inverse_rule_table" || return 1
    inverse_rule_count=$((inverse_rule_count - 1))
  done
}

normalize_firewall_addresses() (
  set -f
  while IFS= read -r normalize_line || [ -n "$normalize_line" ]; do
    normalize_output=
    normalize_previous=
    for normalize_token in $normalize_line; do
      if [ "$normalize_previous" = -s ] || [ "$normalize_previous" = -d ]; then
        case $normalize_token in
          *:*)
            normalize_address=$normalize_token
            normalize_suffix=
            case $normalize_address in
              */*)
                normalize_suffix=/${normalize_address#*/}
                normalize_address=${normalize_address%/*}
                ;;
            esac
            normalize_expanded=$(v6_expand_ipv6 "$normalize_address") || exit 1
            normalize_token=$normalize_expanded$normalize_suffix
            ;;
        esac
      fi
      if [ -n "$normalize_output" ]; then
        normalize_output="$normalize_output $normalize_token"
      else
        normalize_output=$normalize_token
      fi
      normalize_previous=$normalize_token
    done
    printf '%s\n' "$normalize_output"
  done
)

normalize_firewall() {
  awk '
    function append(value) { output = output (output == "" ? "" : " ") value }
    {
      output=""
      protocol_value=0
      for (i=1; i<=NF; i++) {
        token=$i
        if (token ~ /^"[A-Za-z0-9_.:,+%\/@=-]+"$/) {
          sub(/^"/, "", token)
          sub(/"$/, "", token)
        }
        if (token == "--protocol") token="-p"
        else if (token == "--source") token="-s"
        else if (token == "--destination") token="-d"
        else if (token == "--in-interface") token="-i"
        else if (token == "--out-interface") token="-o"
        else if (token == "--jump") token="-j"
        else if (token == "--match") token="-m"
        if (token == "-m" && i < NF) {
          module=$(i+1)
          if (module ~ /^"[A-Za-z0-9_.:,+%\/@=-]+"$/) {
            sub(/^"/, "", module)
            sub(/"$/, "", module)
          }
          if (module == "tcp") { i++; continue }
        }
        if (protocol_value && token == "6") token="tcp"
        else if (protocol_value && token == "ipencap") token="4"
        append(token)
        protocol_value=(token == "-p")
      }
      print output
    }
  ' | normalize_firewall_addresses
}

parse_firewall_save() {
  save_family=$1
  save_input=$2
  save_output=$3
  case $save_family in 4|6) ;; *) return 1 ;; esac
  save_records=$save_output.records
  LC_ALL=C awk '
    function reject() { invalid=1; exit }
    function safe_chain(value) { return value ~ /^[A-Za-z0-9_.-]+$/ }
    function safe_policy(value) {
      return value == "-" || value == "ACCEPT" || value == "DROP"
    }
    /^#/ { next }
    /^[[:space:]]*$/ { next }
    /[[:cntrl:]]/ { reject() }
    index($0, "|") { reject() }
    /^\*/ {
      if (active) reject()
      table=substr($0, 2)
      if (table == "" || table !~ /^[A-Za-z0-9_-]+$/ || seen[table]++) reject()
      active=1
      table_chains=0
      next
    }
    $0 == "COMMIT" {
      if (!active || table_chains == 0) reject()
      active=0
      tables++
      next
    }
    /^:/ {
      if (!active || NF != 3) reject()
      chain=substr($1, 2)
      if (!safe_chain(chain) || !safe_policy($2) ||
        $3 !~ /^\[[0-9]+:[0-9]+\]$/ || declared[table, chain]++) reject()
      table_chains++
      next
    }
    $1 == "-A" {
      if (!active || NF < 2 || !safe_chain($2)) reject()
      rule_table[++rules]=table
      rule_chain[rules]=$2
      print table "|" $0
      next
    }
    { reject() }
    END {
      if (invalid || active || tables == 0) exit 2
      for (i=1; i<=rules; i++) {
        if (!declared[rule_table[i], rule_chain[i]]) exit 2
      }
    }
  ' "$save_input" >"$save_records" || return 1
  : >"$save_output" || return 1
  while IFS='|' read -r save_table save_rule save_extra || [ -n "$save_table$save_rule$save_extra" ]; do
    [ -z "$save_extra" ] || return 1
    case $save_table in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    save_normalized=$(printf '%s\n' "$save_rule" | normalize_firewall) || return 1
    case $save_normalized in -A\ *) ;; *) return 1 ;; esac
    printf '%s|%s|%s\n' "$save_family" "$save_table" "$save_normalized" >>"$save_output" || return 1
  done <"$save_records"
}

capture_firewall_inventory() {
  inventory_prefix=$1
  command -v "$V6_IPTABLES_SAVE_CMD" >/dev/null 2>&1 || return 1
  command -v "$V6_IP6TABLES_SAVE_CMD" >/dev/null 2>&1 || return 1
  "$V6_IPTABLES_SAVE_CMD" >"$WORK_DIR/$inventory_prefix-v4-raw" 2>/dev/null || return 1
  "$V6_IP6TABLES_SAVE_CMD" >"$WORK_DIR/$inventory_prefix-v6-raw" 2>/dev/null || return 1
  parse_firewall_save 4 "$WORK_DIR/$inventory_prefix-v4-raw" "$WORK_DIR/$inventory_prefix-v4" || return 1
  parse_firewall_save 6 "$WORK_DIR/$inventory_prefix-v6-raw" "$WORK_DIR/$inventory_prefix-v6" || return 1
  cat "$WORK_DIR/$inventory_prefix-v4" "$WORK_DIR/$inventory_prefix-v6" >"$WORK_DIR/$inventory_prefix-all" || return 1
}

extract_inventory_tagged() {
  inventory_input=$1
  inventory_output=$2
  awk -F'|' '
    NF != 3 { exit 2 }
    {
      count=split($3, tokens, " ")
      tagged=0
      for (i=1; i<count; i++) {
        if (tokens[i] == "--comment" && tokens[i+1] == "unifi-jpix-tunnel-repair") tagged=1
      }
      if (tagged) print
    }
  ' "$inventory_input" >"$inventory_output"
}

validate_inventory_tagged_subset() {
  inventory_snapshot=$1
  inventory_allowed=$2
  inventory_tagged=$3
  inventory_allow_duplicates=${4:-no}
  extract_inventory_tagged "$inventory_snapshot" "$inventory_tagged" || return 1
  [ "$inventory_allow_duplicates" = yes ] || [ -z "$(sort "$inventory_tagged" | uniq -d)" ] || return 1
  while IFS= read -r inventory_line || [ -n "$inventory_line" ]; do
    grep -F -x -- "$inventory_line" "$inventory_allowed" >/dev/null 2>&1 || return 1
  done <"$inventory_tagged"
}

append_allowed_inventory_rule() {
  inventory_allowed_output=$1
  inventory_allowed_family=$2
  inventory_allowed_table=$3
  inventory_allowed_chain=$4
  shift 4
  inventory_allowed_rule=$(firewall_expected_line "$inventory_allowed_chain" "$@") || return 1
  printf '%s|%s|%s\n' "$inventory_allowed_family" "$inventory_allowed_table" "$inventory_allowed_rule" >>"$inventory_allowed_output"
}

iptables_rule_exists() {
  exists_table=$1
  exists_chain=$2
  shift 2
  if "$V6_IPTABLES_CMD" -t "$exists_table" -C "$exists_chain" "$@" >/dev/null 2>&1; then
    return 0
  else
    exists_status=$?
  fi
  [ "$exists_status" -eq 1 ] && return 1
  return 2
}

ip6tables_rule_exists() {
  exists_chain=$1
  shift
  if "$V6_IP6TABLES_CMD" -C "$exists_chain" "$@" >/dev/null 2>&1; then
    return 0
  else
    exists_status=$?
  fi
  [ "$exists_status" -eq 1 ] && return 1
  return 2
}

firewall_expected_line() {
  expected_chain=$1
  shift
  {
    printf '%s %s' -A "$expected_chain"
    for expected_arg in "$@"; do printf ' %s' "$expected_arg"; done
    printf '\n'
  } | normalize_firewall
}

firewall_positions_from_snapshot() {
  positions_chain=$1
  positions_expected=$2
  positions_file=$3
  awk -v chain="$positions_chain" -v expected="$positions_expected" '
    $1 == "-A" && $2 == chain {
      position++
      if ($0 == expected) {
        if (found) printf ","
        printf "%d", position
        found=1
      }
    }
    END { if (!found) printf "none"; printf "\n" }
  ' "$positions_file"
}

capture_xtables_rules() {
  capture_xtables_output=$1
  shift
  capture_xtables_attempt=1
  while :; do
    if "$@" >"$capture_xtables_output" 2>/dev/null; then
      return 0
    else
      capture_xtables_status=$?
    fi
    [ "$capture_xtables_status" -eq 4 ] || return 2
    [ "$capture_xtables_attempt" -lt 5 ] || return 2
    capture_xtables_attempt=$((capture_xtables_attempt + 1))
    sleep 1
  done
}

iptables_rule_positions() {
  positions_table=$1
  positions_chain=$2
  shift 2
  v6_is_chain_value "$positions_chain" || return 2
  capture_xtables_rules "$WORK_DIR/positions-iptables-raw" "$V6_IPTABLES_CMD" -t "$positions_table" -S || return 2
  normalize_firewall <"$WORK_DIR/positions-iptables-raw" >"$WORK_DIR/positions-iptables" || return 2
  positions_expected=$(firewall_expected_line "$positions_chain" "$@") || return 2
  firewall_positions_from_snapshot "$positions_chain" "$positions_expected" "$WORK_DIR/positions-iptables"
}

ip6tables_rule_positions() {
  positions_chain=$1
  shift
  v6_is_chain_value "$positions_chain" || return 2
  capture_xtables_rules "$WORK_DIR/positions-ip6tables-raw" "$V6_IP6TABLES_CMD" -S || return 2
  normalize_firewall <"$WORK_DIR/positions-ip6tables-raw" >"$WORK_DIR/positions-ip6tables" || return 2
  positions_expected=$(firewall_expected_line "$positions_chain" "$@") || return 2
  firewall_positions_from_snapshot "$positions_chain" "$positions_expected" "$WORK_DIR/positions-ip6tables"
}

validate_firewall_positions() {
  validate_positions=$1
  [ "$validate_positions" != none ] || return 0
  validate_previous=0
  while :; do
    case $validate_positions in
      *,*) validate_position=${validate_positions%%,*}; validate_positions=${validate_positions#*,} ;;
      *) validate_position=$validate_positions; validate_positions= ;;
    esac
    v6_is_uint "$validate_position" && [ "$validate_position" -gt "$validate_previous" ] || return 1
    validate_previous=$validate_position
    [ -n "$validate_positions" ] || break
  done
}

restore_iptables_positions() {
  restore_positions=$1
  restore_table=$2
  restore_chain=$3
  shift 3
  validate_firewall_positions "$restore_positions" && v6_is_chain_value "$restore_chain" && v6_has_managed_comment "$@" || return 1
  v6_iptables_delete "$restore_table" "$restore_chain" "$@" || return 1
  [ "$restore_positions" != none ] || return 0
  while :; do
    case $restore_positions in
      *,*) restore_position=${restore_positions%%,*}; restore_positions=${restore_positions#*,} ;;
      *) restore_position=$restore_positions; restore_positions= ;;
    esac
    v6_run "$V6_IPTABLES_CMD" -t "$restore_table" -I "$restore_chain" "$restore_position" "$@" || return 1
    [ -n "$restore_positions" ] || break
  done
}

restore_ip6tables_positions() {
  restore_positions=$1
  restore_chain=$2
  shift 2
  validate_firewall_positions "$restore_positions" && v6_is_chain_value "$restore_chain" && v6_has_managed_comment "$@" || return 1
  v6_ip6tables_delete "$restore_chain" "$@" || return 1
  [ "$restore_positions" != none ] || return 0
  while :; do
    case $restore_positions in
      *,*) restore_position=${restore_positions%%,*}; restore_positions=${restore_positions#*,} ;;
      *) restore_position=$restore_positions; restore_positions= ;;
    esac
    v6_run "$V6_IP6TABLES_CMD" -I "$restore_chain" "$restore_position" "$@" || return 1
    [ -n "$restore_positions" ] || break
  done
}

inverse_snat_restore() { v6_is_chain_value "$1" && v6_is_cidr "$2" && restore_iptables_positions "$3" nat "$1" -s "$2" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4"; }
inverse_mss_out_restore() { restore_iptables_positions "$1" mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
inverse_mss_in_restore() { restore_iptables_positions "$1" mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
inverse_mss_output_restore() { restore_iptables_positions "$1" mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
inverse_outer_restore() { v6_is_chain_value "$1" && v6_is_ip_value "$2" && v6_is_ip_value "$3" && restore_ip6tables_positions "$4" "$1" -s "$2/128" -d "$3/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT; }

start_transaction() {
  ROLLBACK_FILE=$V6PLUS_STATE_DIR/rollback.$$.records
  : | v6_write_atomic 600 "$ROLLBACK_FILE" || return 1
  MUTATION_ACTIVE=1
  PHYSICAL_MUTATED=0
}

commit_transaction() {
  rm -f -- "$ROLLBACK_FILE" || return 1
  [ ! -e "$ROLLBACK_FILE" ] || return 1
  MUTATION_ACTIVE=0
}

rollback_invocation() {
  [ -f "$ROLLBACK_FILE" ] || return 0
  awk '{ records[NR]=$0 } END { for (i=NR; i>=1; i--) print records[i] }' "$ROLLBACK_FILE" >"$WORK_DIR/rollback.reverse" || return 1
  rollback_failed=0
  while IFS= read -r rollback_line || [ -n "$rollback_line" ]; do
    inverse_record "$rollback_line" || rollback_failed=1
  done <"$WORK_DIR/rollback.reverse"
  if [ "$rollback_failed" -eq 0 ]; then
    rm -f -- "$ROLLBACK_FILE" || rollback_failed=1
  fi
  if [ "$rollback_failed" -eq 0 ]; then MUTATION_ACTIVE=0; return 0; fi
  PRESERVE_WORK=1
  v6_log "ERROR rollback=incomplete evidence=$ROLLBACK_FILE"
  return 1
}

mutation_failed() {
  failed_phase=$1
  v6_log "ERROR phase=$failed_phase rollback=starting"
  rollback_invocation || :
  return 1
}

prepare_plan() {
  NEW_NETWORKS=$WORK_DIR/new-networks
  : >"$NEW_NETWORKS" || return 1
  network_index=0
  v6_iter_networks "$V6_NETWORKS_CONFIG" >"$WORK_DIR/network-pairs" || return 2
  while IFS='|' read -r plan_iface plan_cidr plan_extra || [ -n "${plan_iface:-}${plan_cidr:-}${plan_extra:-}" ]; do
    [ -n "$plan_iface" ] && [ -n "$plan_cidr" ] && [ -z "$plan_extra" ] || return 2
    plan_pref=$((V6_RULE_PREF_BASE + network_index))
    [ "$plan_pref" -le 32765 ] || return 2
    printf '%s|%s|%s\n' "$plan_iface" "$plan_cidr" "$plan_pref" >>"$NEW_NETWORKS" || return 1
    network_index=$((network_index + 1))
  done <"$WORK_DIR/network-pairs"
  [ "$network_index" -gt 0 ] || return 2

  ROUTE_SOURCE=$(v6_route_source_v6 "$V6_BR_V6") || return 1
  LOCAL_V6=$(v6_compose_local_v6 "$ROUTE_SOURCE" "$V6_IID") || return 1
  v6_is_ip_value "$LOCAL_V6" || return 1
  NAT_CHAIN=$(v6_detect_nat_chain) || return 1
  V6_INPUT_CHAIN=$(v6_detect_v6_input_chain) || return 1
  v6_is_chain_value "$NAT_CHAIN" && v6_is_chain_value "$V6_INPUT_CHAIN" || return 1

  current_tunnel || return 1
  tunnel_mode_command_safe "$CURRENT_TUN_MODE" || return 1
  current_tunnel_ipv4 || return 1
  current_tunnel_link || return 1
  ipv6_values_equal "$CURRENT_TUN_REMOTE" "$V6_BR_V6" || return 1

  probe_output=$("$V6_IP_CMD" -4 route get 192.0.2.1 2>/dev/null) || return 1
  set -- $probe_output
  probe_dev=$(read_token_after dev "$@") || return 1
  [ "$probe_dev" = "$V6_TUN_IF" ] || return 1
  static_ipv4_conflicts
  conflict_status=$?
  case $conflict_status in 0) return 1 ;; 1) ;; *) return 1 ;; esac

  OLD_NETWORKS=$WORK_DIR/old-networks
  : >"$OLD_NETWORKS" || return 1
  HAVE_MANAGED=0
  if [ -f "$MANAGED_FILE" ] || [ -f "$LAST_FILE" ]; then
    [ -f "$MANAGED_FILE" ] && [ -f "$LAST_FILE" ] && [ -f "$ORIGINAL_FILE" ] || return 1
    validate_state_file "$MANAGED_FILE" && validate_state_file "$LAST_FILE" && validate_state_file "$ORIGINAL_FILE" || return 1
    load_managed_state "$MANAGED_FILE" "$OLD_NETWORKS" && load_last_state "$LAST_FILE" || return 1
    load_original_state "$ORIGINAL_FILE" || return 1
    [ "$ORIGINAL_TUN_IF" = "$V6_TUN_IF" ] && tunnel_mode_command_safe "$ORIGINAL_TUN_MODE" || return 1
    cp "$MANAGED_FILE" "$WORK_DIR/previous-managed" && cp "$LAST_FILE" "$WORK_DIR/previous-last" || return 1
    HAVE_MANAGED=1
  elif [ -f "$ORIGINAL_FILE" ]; then
    validate_state_file "$ORIGINAL_FILE" || return 1
    load_original_state "$ORIGINAL_FILE" || return 1
    [ "$ORIGINAL_TUN_IF" = "$V6_TUN_IF" ] && tunnel_mode_command_safe "$ORIGINAL_TUN_MODE" || return 1
  fi

  if [ "$HAVE_MANAGED" -eq 0 ]; then
    first_apply_reservations || return 1
  else
    later_apply_ownership || return 1
  fi
}

first_apply_reservations() {
  addr6_exists "$V6_WAN_IF" "$LOCAL_V6/128"
  reserve_address_status=$?
  case $reserve_address_status in 0) return 1 ;; 1) ;; *) return 1 ;; esac
  "$V6_IP_CMD" -4 route show table "$V6_ROUTE_TABLE" >"$WORK_DIR/reserve-routes" 2>/dev/null || return 1
  [ ! -s "$WORK_DIR/reserve-routes" ] || return 1
  rules_snapshot=$("$V6_IP_CMD" -4 rule show 2>/dev/null) || return 1
  while IFS='|' read -r reserve_iface reserve_cidr reserve_pref; do
    printf '%s\n' "$rules_snapshot" | awk -v pref="$reserve_pref" '{ p=$1; sub(/:$/, "", p); if (p == pref) found=1 } END { exit !found }' && return 1
  done <"$NEW_NETWORKS"
  managed_tag_exists
  reserve_tag_status=$?
  case $reserve_tag_status in 0) return 1 ;; 1) return 0 ;; *) return 1 ;; esac
}

old_row_exact() {
  old_wanted=$1
  grep -F -x -- "$old_wanted" "$OLD_NETWORKS" >/dev/null 2>&1
}

later_apply_ownership() {
  # Every route in the owned table must be either our default or represented by validated prior state.
  "$V6_IP_CMD" -4 route show table "$V6_ROUTE_TABLE" 2>/dev/null >"$WORK_DIR/current.routes" || return 1
  : >"$WORK_DIR/current-routes-normalized" || return 1
  while IFS= read -r owned_route || [ -n "$owned_route" ]; do
    [ -n "$owned_route" ] || continue
    owned_route=$(canonical_route_vector "$owned_route") || return 1
    set -- $owned_route
    owned_destination=$1
    owned_iface=$(read_token_after dev "$@") || return 1
    printf '%s|%s\n' "$owned_destination" "$owned_iface" >>"$WORK_DIR/current-routes-normalized" || return 1
    if [ "$owned_destination" = default ] && [ "$owned_iface" = "$V6_TUN_IF" ]; then continue; fi
    awk -F'|' -v cidr="$owned_destination" -v iface="$owned_iface" '$1 == iface && $2 == cidr { found=1 } END { exit !found }' "$OLD_NETWORKS" || return 1
  done <"$WORK_DIR/current.routes"
  [ -z "$(sort "$WORK_DIR/current-routes-normalized" | uniq -d)" ] || return 1

  "$V6_IP_CMD" -4 rule show 2>/dev/null >"$WORK_DIR/current.rules" || return 1
  cat "$OLD_NETWORKS" "$NEW_NETWORKS" | awk -F'|' '!seen[$3]++ { print $3 }' >"$WORK_DIR/owned-prefs" || return 1
  while IFS= read -r current_rule || [ -n "$current_rule" ]; do
    [ -n "$current_rule" ] || continue
    set -- $current_rule
    current_pref=${1%:}
    grep -F -x -- "$current_pref" "$WORK_DIR/owned-prefs" >/dev/null 2>&1 || continue
    [ "$#" -eq 7 ] && [ "$2" = from ] && [ "$3" = all ] && [ "$4" = iif ] && [ "$6" = lookup ] || return 1
    current_iface=$5
    current_table=$7
    awk -F'|' -v pref="$current_pref" -v iface="$current_iface" -v table="$current_table" -v owned="$V6_ROUTE_TABLE" '
      $3 == pref && $1 == iface && table == owned { found++ }
      END { exit !(found == 1) }
    ' "$OLD_NETWORKS" || return 1
    current_pref_count=$(awk -v pref="$current_pref" '{ p=$1; sub(/:$/, "", p); if (p == pref) count++ } END { print count+0 }' "$WORK_DIR/current.rules")
    [ "$current_pref_count" -eq 1 ] || return 1
  done <"$WORK_DIR/current.rules"

  : >"$WORK_DIR/later-allowed-nat" || return 1
  : >"$WORK_DIR/later-allowed-mangle" || return 1
  : >"$WORK_DIR/later-allowed-v6" || return 1
  : >"$WORK_DIR/later-allowed-global" || return 1
  while IFS='|' read -r owned_iface owned_cidr owned_pref; do
    append_allowed_firewall_rule "$WORK_DIR/later-allowed-nat" "$LAST_NAT_CHAIN" -s "$owned_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
    append_allowed_inventory_rule "$WORK_DIR/later-allowed-global" 4 nat "$LAST_NAT_CHAIN" -s "$owned_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
  done <"$OLD_NETWORKS"
  append_allowed_firewall_rule "$WORK_DIR/later-allowed-mangle" FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_firewall_rule "$WORK_DIR/later-allowed-mangle" FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_firewall_rule "$WORK_DIR/later-allowed-mangle" OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/later-allowed-global" 4 mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/later-allowed-global" 4 mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/later-allowed-global" 4 mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  if [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    append_allowed_firewall_rule "$WORK_DIR/later-allowed-v6" "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
    append_allowed_inventory_rule "$WORK_DIR/later-allowed-global" 6 filter "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
  fi
  capture_firewall_snapshot current-firewall || return 1
  capture_firewall_inventory current-inventory || return 1
  validate_tagged_subset "$WORK_DIR/current-firewall-nat" "$WORK_DIR/later-allowed-nat" "$WORK_DIR/later-tagged-nat" || return 1
  validate_tagged_subset "$WORK_DIR/current-firewall-mangle" "$WORK_DIR/later-allowed-mangle" "$WORK_DIR/later-tagged-mangle" || return 1
  validate_tagged_subset "$WORK_DIR/current-firewall-v6" "$WORK_DIR/later-allowed-v6" "$WORK_DIR/later-tagged-v6" || return 1
  validate_inventory_tagged_subset "$WORK_DIR/current-inventory-all" "$WORK_DIR/later-allowed-global" "$WORK_DIR/later-tagged-global" || return 1
  actual_tag_count=$(awk 'END { print NR+0 }' "$WORK_DIR/later-tagged-global") || return 1
  recognized_tag_count=$(awk 'END { print NR+0 }' "$WORK_DIR/later-tagged-nat" "$WORK_DIR/later-tagged-mangle" "$WORK_DIR/later-tagged-v6") || return 1
  [ "$actual_tag_count" -eq "$recognized_tag_count" ] || return 1
  while IFS='|' read -r owned_iface owned_cidr owned_pref; do
    verify_present_iptables_exact "$WORK_DIR/current-firewall-nat" nat "$LAST_NAT_CHAIN" -s "$owned_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
  done <"$OLD_NETWORKS"
  verify_present_iptables_exact "$WORK_DIR/current-firewall-mangle" mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  verify_present_iptables_exact "$WORK_DIR/current-firewall-mangle" mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  verify_present_iptables_exact "$WORK_DIR/current-firewall-mangle" mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  if [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    verify_present_ip6tables_exact "$WORK_DIR/current-firewall-v6" "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
  fi

  if addr6_exists "$V6_WAN_IF" "$LOCAL_V6/128"; then
    ipv6_values_equal "$LAST_LOCAL_V6" "$LOCAL_V6" || return 1
  else
    owned_address_status=$?
    [ "$owned_address_status" -eq 1 ] || return 1
  fi
  return 0
}

write_original_snapshot() {
  [ -f "$ORIGINAL_FILE" ] && return 0
  record_inverse ORIGINAL_REMOVE || return 1
  {
    printf 'TUN_IF=%s\n' "$V6_TUN_IF"
    printf 'TUN_MODE=%s\n' "$CURRENT_TUN_MODE"
    printf 'TUN_LOCAL=%s\n' "$CURRENT_TUN_LOCAL"
    printf 'TUN_REMOTE=%s\n' "$CURRENT_TUN_REMOTE"
    printf 'TUN_IPV4=%s\n' "$CURRENT_TUN_IPV4"
    printf 'TUN_MTU=%s\n' "$CURRENT_TUN_MTU"
    printf 'TUN_UP=%s\n' "$CURRENT_TUN_UP"
  } | v6_write_atomic 600 "$ORIGINAL_FILE"
}

ensure_state_dir() {
  if [ ! -e "$V6PLUS_STATE_DIR" ]; then
    (umask 077 && mkdir -- "$V6PLUS_STATE_DIR") || return 1
  fi
  v6_validate_state_dir
}

dry_run_plan() {
  V6_REDACT_FIXED_V4=$V6_STATIC_V4
  V6_REDACT_BR_V6=$V6_BR_V6
  V6_REDACT_LOCAL_V6=$LOCAL_V6
  V6_REDACT_ORIGINAL_V4=${CURRENT_TUN_IPV4%/*}
  V6_REDACT_OLD_LOCAL_V6=${LAST_LOCAL_V6:-}
  if addr6_exists "$V6_WAN_IF" "$LOCAL_V6/128"; then
    :
  else
    dry_status=$?
    [ "$dry_status" -eq 1 ] || return 1
    v6_run "$V6_IP_CMD" -6 addr replace "$LOCAL_V6/128" dev "$V6_WAN_IF" || return 1
  fi
  if [ "$CURRENT_TUN_MODE" != ipip6 ]; then
    v6_run "$V6_IP_CMD" -6 tunnel change "$V6_TUN_IF" mode ipip6 local "$LOCAL_V6" remote "$V6_BR_V6" || return 1
  elif tunnel_endpoints_equal "$CURRENT_TUN_LOCAL" "$LOCAL_V6" "$CURRENT_TUN_REMOTE" "$V6_BR_V6"; then
    :
  else
    dry_tunnel_status=$?
    [ "$dry_tunnel_status" -eq 1 ] || return 1
    v6_run "$V6_IP_CMD" -6 tunnel change "$V6_TUN_IF" mode ipip6 local "$LOCAL_V6" remote "$V6_BR_V6" || return 1
  fi
  if [ "$CURRENT_TUN_MTU" != "$V6_TUN_MTU" ] || [ "$CURRENT_TUN_UP" != yes ]; then
    v6_run "$V6_IP_CMD" link set dev "$V6_TUN_IF" mtu "$V6_TUN_MTU" up || return 1
  fi
  if [ "$CURRENT_TUN_IPV4" != "$V6_STATIC_V4/32" ]; then
    v6_run "$V6_IP_CMD" -4 addr del "$CURRENT_TUN_IPV4" dev "$V6_TUN_IF" || return 1
    v6_run "$V6_IP_CMD" -4 addr replace "$V6_STATIC_V4/32" dev "$V6_TUN_IF" || return 1
  fi
  if route4_exists "$V6_ROUTE_TABLE" default "$V6_TUN_IF"; then
    :
  else
    dry_status=$?
    [ "$dry_status" -eq 1 ] || return 1
    v6_run "$V6_IP_CMD" -4 route replace table "$V6_ROUTE_TABLE" default dev "$V6_TUN_IF" || return 1
  fi
  if [ "$HAVE_MANAGED" -eq 1 ]; then
    while IFS='|' read -r dry_old_iface dry_old_cidr dry_old_pref; do
      dry_old_current=0
      grep -F -x -- "$dry_old_iface|$dry_old_cidr|$dry_old_pref" "$NEW_NETWORKS" >/dev/null 2>&1 && dry_old_current=1
      if [ "$dry_old_current" -eq 0 ] || [ "$LAST_NAT_CHAIN" != "$NAT_CHAIN" ]; then
        if iptables_rule_exists nat "$LAST_NAT_CHAIN" -s "$dry_old_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4"; then
          v6_run "$V6_IPTABLES_CMD" -t nat -D "$LAST_NAT_CHAIN" -s "$dry_old_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
        else
          dry_status=$?
          [ "$dry_status" -eq 1 ] || return 1
        fi
      fi
      [ "$dry_old_current" -eq 0 ] || continue
      if rule4_exists "$dry_old_pref" "$dry_old_iface" "$V6_ROUTE_TABLE"; then
        v6_run "$V6_IP_CMD" -4 rule del pref "$dry_old_pref" iif "$dry_old_iface" lookup "$V6_ROUTE_TABLE" || return 1
      else
        dry_status=$?
        [ "$dry_status" -eq 1 ] || return 1
      fi
      if route4_exists "$V6_ROUTE_TABLE" "$dry_old_cidr" "$dry_old_iface"; then
        v6_run "$V6_IP_CMD" -4 route del table "$V6_ROUTE_TABLE" "$dry_old_cidr" dev "$dry_old_iface" || return 1
      else
        dry_status=$?
        [ "$dry_status" -eq 1 ] || return 1
      fi
    done <"$OLD_NETWORKS"
  fi
  while IFS='|' read -r plan_iface plan_cidr plan_pref; do
    if route4_exists "$V6_ROUTE_TABLE" "$plan_cidr" "$plan_iface"; then :; else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
      v6_run "$V6_IP_CMD" -4 route replace table "$V6_ROUTE_TABLE" "$plan_cidr" dev "$plan_iface" || return 1
    fi
    if rule4_exists "$plan_pref" "$plan_iface" "$V6_ROUTE_TABLE"; then :; else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
      v6_run "$V6_IP_CMD" -4 rule add pref "$plan_pref" iif "$plan_iface" lookup "$V6_ROUTE_TABLE" || return 1
    fi
    if iptables_rule_exists nat "$NAT_CHAIN" -s "$plan_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4"; then :; else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
      v6_run "$V6_IPTABLES_CMD" -t nat -A "$NAT_CHAIN" -s "$plan_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
    fi
  done <"$NEW_NETWORKS"
  for dry_mss_kind in out in output; do
    case $dry_mss_kind in
      out) set -- FORWARD -o ;;
      in) set -- FORWARD -i ;;
      output) set -- OUTPUT -o ;;
    esac
    dry_mss_chain=$1
    dry_mss_direction=$2
    if iptables_rule_exists mangle "$dry_mss_chain" "$dry_mss_direction" "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; then :; else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
      v6_run "$V6_IPTABLES_CMD" -t mangle -A "$dry_mss_chain" "$dry_mss_direction" "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
    fi
  done
  if [ "$V6_OUTER_IPIP_ALLOW" = yes ]; then
    if ip6tables_rule_exists "$V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT; then :; else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
      v6_run "$V6_IP6TABLES_CMD" -A "$V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
    fi
  elif [ "$V6_OUTER_IPIP_ALLOW" = auto ]; then
    if outer_unmanaged_exact_exists "$V6_INPUT_CHAIN" "$LOCAL_V6"; then :; else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
      printf '%s\n' 'WARN outer_ipip=unconfirmed set OUTER_IPIP_ALLOW=yes only after traffic verification' >&2
    fi
  fi
  if [ "$HAVE_MANAGED" -eq 1 ] && [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    ipv6_values_equal "$LAST_LOCAL_V6" "$LOCAL_V6"
    dry_last_local_status=$?
    [ "$dry_last_local_status" -ne 2 ] || return 1
    if [ "$dry_last_local_status" -eq 1 ] || [ "$V6_OUTER_IPIP_ALLOW" != yes ] || [ "$LAST_V6_INPUT_CHAIN" != "$V6_INPUT_CHAIN" ]; then
      if ip6tables_rule_exists "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT; then
        v6_run "$V6_IP6TABLES_CMD" -D "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
      else
        dry_status=$?
        [ "$dry_status" -eq 1 ] || return 1
      fi
    fi
  fi
  if [ "$HAVE_MANAGED" -eq 1 ]; then
    ipv6_values_equal "$LAST_LOCAL_V6" "$LOCAL_V6"
    dry_last_local_status=$?
    [ "$dry_last_local_status" -ne 2 ] || return 1
  fi
  if [ "$HAVE_MANAGED" -eq 1 ] && [ "$dry_last_local_status" -eq 1 ]; then
    if addr6_exists "$V6_WAN_IF" "$LAST_LOCAL_V6/128"; then
      v6_run "$V6_IP_CMD" -6 addr del "$LAST_LOCAL_V6/128" dev "$V6_WAN_IF" || return 1
    else
      dry_status=$?
      [ "$dry_status" -eq 1 ] || return 1
    fi
  fi
}

mutate_addr6_add() {
  if addr6_exists "$1" "$2"; then return 0; else mutate_status=$?; [ "$mutate_status" -eq 1 ] || return 1; fi
  record_inverse "ADDR6_ABSENT|$1|$2" || return 1
  v6_run "$V6_IP_CMD" -6 addr replace "$2" dev "$1" || return 1
  PHYSICAL_MUTATED=1
}
mutate_addr6_del() {
  if addr6_exists "$1" "$2"; then :; else mutate_status=$?; [ "$mutate_status" -eq 1 ] && return 0; return 1; fi
  record_inverse "ADDR6_PRESENT|$1|$2" || return 1
  v6_run "$V6_IP_CMD" -6 addr del "$2" dev "$1" || return 1
  PHYSICAL_MUTATED=1
}
mutate_addr4_add() {
  if addr4_exists "$1" "$2"; then return 0; else mutate_status=$?; [ "$mutate_status" -eq 1 ] || return 1; fi
  record_inverse "ADDR4_ABSENT|$1|$2" || return 1
  v6_run "$V6_IP_CMD" -4 addr replace "$2" dev "$1" || return 1
  PHYSICAL_MUTATED=1
}
mutate_addr4_del() {
  if addr4_exists "$1" "$2"; then :; else mutate_status=$?; [ "$mutate_status" -eq 1 ] && return 0; return 1; fi
  record_inverse "ADDR4_PRESENT|$1|$2" || return 1
  v6_run "$V6_IP_CMD" -4 addr del "$2" dev "$1" || return 1
  PHYSICAL_MUTATED=1
}
mutate_route_add() {
  if route4_exists "$1" "$2" "$3"; then return 0; else mutate_status=$?; [ "$mutate_status" -eq 1 ] || return 1; fi
  record_inverse "ROUTE4_ABSENT|$1|$2|$3" || return 1
  v6_run "$V6_IP_CMD" -4 route replace table "$1" "$2" dev "$3" || return 1
  PHYSICAL_MUTATED=1
}
mutate_route_del() {
  mutate_route_table=$1
  mutate_route_destination=$2
  mutate_route_iface=$3
  if capture_route4_vector "$mutate_route_table" "$mutate_route_destination" "$mutate_route_iface" "$WORK_DIR/mutate-route-vector"; then
    mutate_route_vector=$(cat "$WORK_DIR/mutate-route-vector") || return 1
  else
    mutate_status=$?
    [ "$mutate_status" -eq 1 ] && return 0
    return 1
  fi
  record_inverse "ROUTE4_PRESENT|$mutate_route_table|$mutate_route_vector" || return 1
  set -- $mutate_route_vector
  v6_run "$V6_IP_CMD" -4 route del table "$mutate_route_table" "$@" || return 1
  PHYSICAL_MUTATED=1
}
mutate_rule_add() {
  mutate_rule_count=$(rule4_count "$1" "$2" "$3") || return 1
  [ "$mutate_rule_count" -eq 0 ] || return 0
  record_inverse "RULE4_RESTORE|$1|$2|$3|$mutate_rule_count" || return 1
  v6_run "$V6_IP_CMD" -4 rule add pref "$1" iif "$2" lookup "$3" || return 1
  PHYSICAL_MUTATED=1
}
mutate_rule_del() {
  mutate_rule_count=$(rule4_count "$1" "$2" "$3") || return 1
  [ "$mutate_rule_count" -gt 0 ] || return 0
  record_inverse "RULE4_RESTORE|$1|$2|$3|$mutate_rule_count" || return 1
  while [ "$mutate_rule_count" -gt 0 ]; do
    v6_run "$V6_IP_CMD" -4 rule del pref "$1" iif "$2" lookup "$3" || return 1
    mutate_rule_count=$((mutate_rule_count - 1))
  done
  PHYSICAL_MUTATED=1
}

mutate_snat_add() {
  mutate_positions=$(iptables_rule_positions nat "$1" -s "$2" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4") || return 1
  [ "$mutate_positions" = none ] || return 0
  record_inverse "SNAT_RESTORE|$1|$2|$mutate_positions" || return 1
  v6_iptables_ensure nat "$1" -s "$2" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
  PHYSICAL_MUTATED=1
}
mutate_snat_del() {
  mutate_positions=$(iptables_rule_positions nat "$1" -s "$2" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4") || return 1
  [ "$mutate_positions" != none ] || return 0
  record_inverse "SNAT_RESTORE|$1|$2|$mutate_positions" || return 1
  v6_iptables_delete nat "$1" -s "$2" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
  PHYSICAL_MUTATED=1
}

mutate_mss_rule() {
  mutate_action=$1; mutate_type=$2; mutate_table=$3; mutate_chain=$4; shift 4
  mutate_positions=$(iptables_rule_positions "$mutate_table" "$mutate_chain" "$@") || return 1
  if [ "$mutate_action" = add ]; then [ "$mutate_positions" = none ] || return 0; else [ "$mutate_positions" != none ] || return 0; fi
  record_inverse "${mutate_type}_RESTORE|$mutate_positions" || return 1
  if [ "$mutate_action" = add ]; then
    v6_iptables_ensure "$mutate_table" "$mutate_chain" "$@" || return 1
  else
    v6_iptables_delete "$mutate_table" "$mutate_chain" "$@" || return 1
  fi
  PHYSICAL_MUTATED=1
}
mutate_mss_out_add() { mutate_mss_rule add MSS_OUT mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
mutate_mss_in_add() { mutate_mss_rule add MSS_IN mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
mutate_mss_output_add() { mutate_mss_rule add MSS_OUTPUT mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
mutate_mss_out_del() { mutate_mss_rule del MSS_OUT mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
mutate_mss_in_del() { mutate_mss_rule del MSS_IN mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
mutate_mss_output_del() { mutate_mss_rule del MSS_OUTPUT mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS"; }
mutate_outer_add() {
  mutate_positions=$(ip6tables_rule_positions "$1" -s "$2/128" -d "$3/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT) || return 1
  [ "$mutate_positions" = none ] || return 0
  record_inverse "OUTER_RESTORE|$1|$2|$3|$mutate_positions" || return 1
  v6_ip6tables_ensure "$1" -s "$2/128" -d "$3/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
  PHYSICAL_MUTATED=1
}
mutate_outer_del() {
  mutate_positions=$(ip6tables_rule_positions "$1" -s "$2/128" -d "$3/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT) || return 1
  [ "$mutate_positions" != none ] || return 0
  record_inverse "OUTER_RESTORE|$1|$2|$3|$mutate_positions" || return 1
  v6_ip6tables_delete "$1" -s "$2/128" -d "$3/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
  PHYSICAL_MUTATED=1
}

apply_mutations() {
  ensure_state_dir || return 1
  start_transaction || return 1
  write_original_snapshot || { mutation_failed original_snapshot; return 1; }

  mutate_addr6_add "$V6_WAN_IF" "$LOCAL_V6/128" || { mutation_failed wan_address; return 1; }
  if [ "$CURRENT_TUN_MODE" != ipip6 ]; then
    record_inverse "TUNNEL_CHANGE|$V6_TUN_IF|$CURRENT_TUN_MODE|$CURRENT_TUN_LOCAL|$CURRENT_TUN_REMOTE" &&
      v6_run "$V6_IP_CMD" -6 tunnel change "$V6_TUN_IF" mode ipip6 local "$LOCAL_V6" remote "$V6_BR_V6" || { mutation_failed tunnel; return 1; }
    PHYSICAL_MUTATED=1
  elif tunnel_endpoints_equal "$CURRENT_TUN_LOCAL" "$LOCAL_V6" "$CURRENT_TUN_REMOTE" "$V6_BR_V6"; then
    :
  else
    mutate_tunnel_status=$?
    [ "$mutate_tunnel_status" -eq 1 ] || { mutation_failed tunnel; return 1; }
    record_inverse "TUNNEL_CHANGE|$V6_TUN_IF|$CURRENT_TUN_MODE|$CURRENT_TUN_LOCAL|$CURRENT_TUN_REMOTE" &&
      v6_run "$V6_IP_CMD" -6 tunnel change "$V6_TUN_IF" mode ipip6 local "$LOCAL_V6" remote "$V6_BR_V6" || { mutation_failed tunnel; return 1; }
    PHYSICAL_MUTATED=1
  fi
  if [ "$CURRENT_TUN_MTU" != "$V6_TUN_MTU" ] || [ "$CURRENT_TUN_UP" != yes ]; then
    record_inverse "LINK_SET|$V6_TUN_IF|$CURRENT_TUN_MTU|$CURRENT_TUN_UP" &&
      v6_run "$V6_IP_CMD" link set dev "$V6_TUN_IF" mtu "$V6_TUN_MTU" up || { mutation_failed link; return 1; }
    PHYSICAL_MUTATED=1
  fi
  if [ "$CURRENT_TUN_IPV4" != "$V6_STATIC_V4/32" ]; then
    mutate_addr4_del "$V6_TUN_IF" "$CURRENT_TUN_IPV4" || { mutation_failed old_ipv4; return 1; }
  fi
  mutate_addr4_add "$V6_TUN_IF" "$V6_STATIC_V4/32" || { mutation_failed fixed_ipv4; return 1; }
  mutate_route_add "$V6_ROUTE_TABLE" default "$V6_TUN_IF" || { mutation_failed default_route; return 1; }

  if [ "$HAVE_MANAGED" -eq 1 ]; then
    while IFS='|' read -r old_iface old_cidr old_pref; do
      old_row_current=0
      grep -F -x -- "$old_iface|$old_cidr|$old_pref" "$NEW_NETWORKS" >/dev/null 2>&1 && old_row_current=1
      if [ "$old_row_current" -eq 0 ] || [ "$LAST_NAT_CHAIN" != "$NAT_CHAIN" ]; then
        mutate_snat_del "$LAST_NAT_CHAIN" "$old_cidr" || { mutation_failed stale_snat; return 1; }
      fi
      [ "$old_row_current" -eq 1 ] && continue
      mutate_rule_del "$old_pref" "$old_iface" "$V6_ROUTE_TABLE" &&
        mutate_route_del "$V6_ROUTE_TABLE" "$old_cidr" "$old_iface" || { mutation_failed stale_network; return 1; }
    done <"$OLD_NETWORKS"
  fi

  while IFS='|' read -r new_iface new_cidr new_pref; do
    mutate_route_add "$V6_ROUTE_TABLE" "$new_cidr" "$new_iface" &&
      mutate_rule_add "$new_pref" "$new_iface" "$V6_ROUTE_TABLE" &&
      mutate_snat_add "$NAT_CHAIN" "$new_cidr" || { mutation_failed managed_network; return 1; }
  done <"$NEW_NETWORKS"

  mutate_mss_out_add && mutate_mss_in_add && mutate_mss_output_add || { mutation_failed mss; return 1; }

  DESIRED_V6_INPUT_CHAIN=$V6_INPUT_CHAIN
  DESIRED_V6_INPUT_MANAGED=no
  case $V6_OUTER_IPIP_ALLOW in
    yes)
      mutate_outer_add "$V6_INPUT_CHAIN" "$V6_BR_V6" "$LOCAL_V6" || { mutation_failed outer_add; return 1; }
      DESIRED_V6_INPUT_MANAGED=yes
      ;;
    no) DESIRED_V6_INPUT_CHAIN=none ;;
    auto)
      outer_unmanaged_exact_exists "$V6_INPUT_CHAIN" "$LOCAL_V6"
      outer_confirmation_status=$?
      case $outer_confirmation_status in
        0) ;;
        1) printf '%s\n' 'WARN outer_ipip=unconfirmed set OUTER_IPIP_ALLOW=yes only after traffic verification' >&2 ;;
        *) mutation_failed outer_inspection; return 1 ;;
      esac
      ;;
  esac

  if [ "$HAVE_MANAGED" -eq 1 ] && [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    ipv6_values_equal "$LAST_LOCAL_V6" "$LOCAL_V6"
    mutate_last_local_status=$?
    [ "$mutate_last_local_status" -ne 2 ] || { mutation_failed old_outer; return 1; }
    if [ "$mutate_last_local_status" -eq 1 ] || [ "$DESIRED_V6_INPUT_MANAGED" != yes ] || [ "$LAST_V6_INPUT_CHAIN" != "$V6_INPUT_CHAIN" ]; then
      mutate_outer_del "$LAST_V6_INPUT_CHAIN" "$V6_BR_V6" "$LAST_LOCAL_V6" || { mutation_failed old_outer; return 1; }
    fi
  fi
  if [ "$HAVE_MANAGED" -eq 1 ]; then
    ipv6_values_equal "$LAST_LOCAL_V6" "$LOCAL_V6"
    mutate_last_local_status=$?
    [ "$mutate_last_local_status" -ne 2 ] || { mutation_failed old_endpoint; return 1; }
  fi
  if [ "$HAVE_MANAGED" -eq 1 ] && [ "$mutate_last_local_status" -eq 1 ]; then
    mutate_addr6_del "$V6_WAN_IF" "$LAST_LOCAL_V6/128" || { mutation_failed old_endpoint; return 1; }
  fi

  state_content_changed=1
  if [ "$HAVE_MANAGED" -eq 1 ] && cmp -s "$NEW_NETWORKS" "$WORK_DIR/previous-managed" &&
    [ "$mutate_last_local_status" -eq 0 ] && [ "$LAST_NAT_CHAIN" = "$NAT_CHAIN" ] &&
    [ "$LAST_V6_INPUT_CHAIN" = "$DESIRED_V6_INPUT_CHAIN" ] && [ "$LAST_V6_INPUT_MANAGED" = "$DESIRED_V6_INPUT_MANAGED" ]; then
    state_content_changed=0
  fi
  if [ "$HAVE_MANAGED" -eq 1 ] && [ "$PHYSICAL_MUTATED" -eq 0 ] && [ "$state_content_changed" -eq 0 ]; then
    applied_at=$LAST_APPLIED_AT
  else
    applied_at=${V6PLUS_NOW:-$(date +%s)}
  fi
  v6_is_uint "$applied_at" || { mutation_failed timestamp; return 1; }
  {
    printf 'LOCAL_V6=%s\n' "$LOCAL_V6"
    printf 'NAT_CHAIN=%s\n' "$NAT_CHAIN"
    printf 'V6_INPUT_CHAIN=%s\n' "$DESIRED_V6_INPUT_CHAIN"
    printf 'V6_INPUT_MANAGED=%s\n' "$DESIRED_V6_INPUT_MANAGED"
    printf 'APPLIED_AT=%s\n' "$applied_at"
  } >"$WORK_DIR/new-last" || { mutation_failed state_prepare; return 1; }
  cp "$NEW_NETWORKS" "$WORK_DIR/new-managed" || { mutation_failed state_prepare; return 1; }

  if [ ! -f "$MANAGED_FILE" ] || ! cmp -s "$WORK_DIR/new-managed" "$MANAGED_FILE"; then
    if [ "$HAVE_MANAGED" -eq 1 ]; then record_inverse STATE_MANAGED_RESTORE; else record_inverse STATE_MANAGED_REMOVE; fi || { mutation_failed state_managed_inverse; return 1; }
    v6_write_atomic 600 "$MANAGED_FILE" <"$WORK_DIR/new-managed" || { mutation_failed state_managed; return 1; }
  fi
  if [ ! -f "$LAST_FILE" ] || ! cmp -s "$WORK_DIR/new-last" "$LAST_FILE"; then
    if [ "$HAVE_MANAGED" -eq 1 ]; then record_inverse STATE_LAST_RESTORE; else record_inverse STATE_LAST_REMOVE; fi || { mutation_failed state_last_inverse; return 1; }
    v6_write_atomic 600 "$LAST_FILE" <"$WORK_DIR/new-last" || { mutation_failed state_last; return 1; }
  fi
  commit_transaction || { mutation_failed commit; return 1; }
  return 0
}

status_line() {
  status_name=$1
  status_actual=$2
  status_expected=$3
  if [ "$status_actual" = "$status_expected" ]; then
    printf 'OK %s=%s\n' "$status_name" "$status_actual"
  else
    printf 'ERROR %s=%s expected=%s\n' "$status_name" "$status_actual" "$status_expected"
    STATUS_FAILED=1
  fi
}

status_ipv6_line() {
  status_name=$1
  status_actual=$2
  status_expected=$3
  if ipv6_values_equal "$status_actual" "$status_expected"; then
    printf 'OK %s=%s\n' "$status_name" "$status_actual"
  else
    status_ipv6_status=$?
    if [ "$status_ipv6_status" -eq 1 ]; then
      printf 'ERROR %s=%s expected=%s\n' "$status_name" "$status_actual" "$status_expected"
    else
      printf 'ERROR %s=inspection_failed expected=%s\n' "$status_name" "$status_expected"
    fi
    STATUS_FAILED=1
  fi
}

check_material_status() {
  if "$V6_IP_CMD" -4 addr show dev "$V6_TUN_IF" >"$WORK_DIR/status-ipv4-set" 2>/dev/null; then
    awk '$1 == "inet" { print $2 }' "$WORK_DIR/status-ipv4-set" | sort >"$WORK_DIR/status-ipv4-actual"
    printf '%s\n' "$V6_STATIC_V4/32" >"$WORK_DIR/status-ipv4-expected"
    if cmp -s "$WORK_DIR/status-ipv4-actual" "$WORK_DIR/status-ipv4-expected"; then
      status_line tunnel_ipv4_set current current
    else
      status_line tunnel_ipv4_set drift current
    fi
  else
    status_line tunnel_ipv4_set inspection_failed current
  fi

  : >"$WORK_DIR/status-obsolete-wan" || return 1
  if "$V6_IP_CMD" -6 addr show dev "$V6_WAN_IF" >"$WORK_DIR/status-wan-v6" 2>/dev/null; then
    expanded_status_local=$(v6_expand_ipv6 "$LOCAL_V6") || return 1
    status_iid_suffix=$(printf '%s\n' "$expanded_status_local" | cut -d: -f5-8)
    awk '$1 == "inet6" { print $2 }' "$WORK_DIR/status-wan-v6" |
      while IFS= read -r status_wan_cidr; do
        case $status_wan_cidr in */128) ;; *) continue ;; esac
        status_wan_address=${status_wan_cidr%/128}
        expanded_status_wan=$(v6_expand_ipv6 "$status_wan_address") || continue
        status_wan_suffix=$(printf '%s\n' "$expanded_status_wan" | cut -d: -f5-8)
        if [ "$status_wan_suffix" = "$status_iid_suffix" ] && [ "$expanded_status_wan" != "$expanded_status_local" ]; then
          printf '%s\n' "$status_wan_cidr"
        fi
      done >"$WORK_DIR/status-obsolete-wan"
    if [ -s "$WORK_DIR/status-obsolete-wan" ]; then status_line obsolete_wan_address present absent; else status_line obsolete_wan_address absent absent; fi
  else
    status_line obsolete_wan_address inspection_failed absent
  fi

  {
    printf 'default|%s\n' "$V6_TUN_IF"
    awk -F'|' '{ print $2 "|" $1 }' "$WORK_DIR/status-desired"
  } | sort >"$WORK_DIR/status-routes-expected" || return 1
  if "$V6_IP_CMD" -4 route show table "$V6_ROUTE_TABLE" >"$WORK_DIR/status-routes-raw" 2>/dev/null; then
    awk '{ iface=""; for (i=2; i<NF; i++) if ($i == "dev") iface=$(i+1); if (iface == "") print "INVALID|" $0; else print $1 "|" iface }' \
      "$WORK_DIR/status-routes-raw" | sort >"$WORK_DIR/status-routes-actual"
    if cmp -s "$WORK_DIR/status-routes-actual" "$WORK_DIR/status-routes-expected"; then status_line reserved_routes current current; else status_line reserved_routes drift current; fi
  else
    status_line reserved_routes inspection_failed current
  fi

  awk -F'|' -v table="$V6_ROUTE_TABLE" '{ print $3 "|" $1 "|" table }' "$WORK_DIR/status-desired" | sort >"$WORK_DIR/status-rules-expected" || return 1
  if "$V6_IP_CMD" -4 rule show >"$WORK_DIR/status-rules-raw" 2>/dev/null; then
    awk -v desired="$WORK_DIR/status-desired" 'FILENAME == desired { split($0, fields, "|"); wanted[fields[3]]=1; next }
      { p=$1; sub(/:$/, "", p); if (!(p in wanted)) next;
        if (NF == 7 && $2 == "from" && $3 == "all" && $4 == "iif" && $6 == "lookup") print p "|" $5 "|" $7;
        else print "INVALID|" $0 }
    ' "$WORK_DIR/status-desired" "$WORK_DIR/status-rules-raw" | sort >"$WORK_DIR/status-rules-actual"
    if cmp -s "$WORK_DIR/status-rules-actual" "$WORK_DIR/status-rules-expected"; then status_line reserved_rules current current; else status_line reserved_rules drift current; fi
  else
    status_line reserved_rules inspection_failed current
  fi

  : >"$WORK_DIR/status-allowed-global" || return 1
  while IFS='|' read -r status_owned_iface status_owned_cidr status_owned_pref; do
    append_allowed_inventory_rule "$WORK_DIR/status-allowed-global" 4 nat "$LAST_NAT_CHAIN" -s "$status_owned_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
  done <"$WORK_DIR/status-networks"
  append_allowed_inventory_rule "$WORK_DIR/status-allowed-global" 4 mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/status-allowed-global" 4 mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/status-allowed-global" 4 mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  if [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    append_allowed_inventory_rule "$WORK_DIR/status-allowed-global" 6 filter "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
  fi

  if capture_firewall_snapshot status-fw && capture_firewall_inventory status-inventory; then
    extract_inventory_tagged "$WORK_DIR/status-inventory-all" "$WORK_DIR/status-tagged-global" || return 1
    sort "$WORK_DIR/status-tagged-global" | uniq -d >"$WORK_DIR/status-fw-duplicates" || return 1
    if [ -s "$WORK_DIR/status-fw-duplicates" ]; then status_line tagged_duplicates present absent; else status_line tagged_duplicates absent absent; fi
    status_expected_tags=$(awk 'END { print NR+0 }' "$WORK_DIR/status-allowed-global") || return 1
    status_actual_tags=$(awk 'END { print NR+0 }' "$WORK_DIR/status-tagged-global") || return 1
    if validate_inventory_tagged_subset "$WORK_DIR/status-inventory-all" "$WORK_DIR/status-allowed-global" "$WORK_DIR/status-owned-tags" &&
      [ "$status_actual_tags" -eq "$status_expected_tags" ]; then
      status_line tagged_rules exact exact
    else
      status_line tagged_rules drift exact
    fi
  else
    status_line tagged_duplicates inspection_failed absent
    status_line tagged_rules inspection_failed exact
  fi
}

check_status() {
  load_configuration || return $?
  make_work_dir || return 1
  v6_validate_state_dir || { printf 'ERROR state_dir=invalid expected=secure\n'; return 1; }
  [ -f "$MANAGED_FILE" ] && [ -f "$LAST_FILE" ] && [ -f "$ORIGINAL_FILE" ] || { printf 'ERROR state=missing expected=complete\n'; return 1; }
  validate_state_file "$MANAGED_FILE" && validate_state_file "$LAST_FILE" && validate_state_file "$ORIGINAL_FILE" || { printf 'ERROR state=invalid expected=validated\n'; return 1; }
  load_managed_state "$MANAGED_FILE" "$WORK_DIR/status-networks" && load_last_state "$LAST_FILE" && load_original_state "$ORIGINAL_FILE" || {
    printf 'ERROR state=invalid expected=validated\n'
    return 1
  }
  : >"$WORK_DIR/status-desired" || return 1
  v6_iter_networks "$V6_NETWORKS_CONFIG" >"$WORK_DIR/status-pairs" || return 1
  status_index=0
  while IFS='|' read -r status_desired_iface status_desired_cidr; do
    status_desired_pref=$((V6_RULE_PREF_BASE + status_index))
    [ "$status_desired_pref" -le 32765 ] || return 1
    printf '%s|%s|%s\n' "$status_desired_iface" "$status_desired_cidr" "$status_desired_pref" >>"$WORK_DIR/status-desired" || return 1
    status_index=$((status_index + 1))
  done <"$WORK_DIR/status-pairs"
  ROUTE_SOURCE=$(v6_route_source_v6 "$V6_BR_V6" 2>/dev/null || :)
  LOCAL_V6=$(v6_compose_local_v6 "$ROUTE_SOURCE" "$V6_IID" 2>/dev/null || :)
  STATUS_FAILED=0
  status_ipv6_line state_local "$LAST_LOCAL_V6" "$LOCAL_V6"
  if status_current_nat_chain=$(v6_detect_nat_chain); then
    NAT_CHAIN=$status_current_nat_chain
    status_line nat_chain "$status_current_nat_chain" "$LAST_NAT_CHAIN"
  else
    NAT_CHAIN=$LAST_NAT_CHAIN
    status_line nat_chain inspection_failed "$LAST_NAT_CHAIN"
  fi
  if [ "$LAST_V6_INPUT_CHAIN" != none ]; then
    if status_current_v6_chain=$(v6_detect_v6_input_chain); then
      status_line v6_input_chain "$status_current_v6_chain" "$LAST_V6_INPUT_CHAIN"
    else
      status_line v6_input_chain inspection_failed "$LAST_V6_INPUT_CHAIN"
    fi
  fi

  if [ "$(cat "$WORK_DIR/status-networks")" = "$(cat "$WORK_DIR/status-desired")" ]; then
    status_line managed_networks current current
  else
    status_line managed_networks stale current
  fi

  if addr6_exists "$V6_WAN_IF" "$LOCAL_V6/128"; then status_line wan_address "$LOCAL_V6/128" "$LOCAL_V6/128"; else status_line wan_address missing "$LOCAL_V6/128"; fi
  if current_tunnel; then
    status_line tunnel_mode "$CURRENT_TUN_MODE" ipip6
    status_ipv6_line tunnel_local "$CURRENT_TUN_LOCAL" "$LOCAL_V6"
    status_ipv6_line tunnel_remote "$CURRENT_TUN_REMOTE" "$V6_BR_V6"
  else
    status_line tunnel missing present
  fi
  if addr4_exists "$V6_TUN_IF" "$V6_STATIC_V4/32"; then status_line tunnel_ipv4 "$V6_STATIC_V4/32" "$V6_STATIC_V4/32"; else status_line tunnel_ipv4 missing "$V6_STATIC_V4/32"; fi
  if current_tunnel_link; then status_line tunnel_mtu "$CURRENT_TUN_MTU" "$V6_TUN_MTU"; status_line tunnel_up "$CURRENT_TUN_UP" yes; else status_line tunnel_link missing present; fi
  probe_output=$("$V6_IP_CMD" -4 route get 192.0.2.1 2>/dev/null || :)
  set -- $probe_output
  probe_status_dev=$(read_token_after dev "$@" 2>/dev/null || :)
  probe_status_src=$(read_token_after src "$@" 2>/dev/null || :)
  if [ "$probe_status_dev" = "$V6_TUN_IF" ] && [ "$probe_status_src" = "$V6_STATIC_V4" ]; then
    status_line router_probe "$V6_TUN_IF/$V6_STATIC_V4" "$V6_TUN_IF/$V6_STATIC_V4"
  else
    status_line router_probe "${probe_output:-missing}" "$V6_TUN_IF/$V6_STATIC_V4"
  fi
  if route4_exists "$V6_ROUTE_TABLE" default "$V6_TUN_IF"; then status_line route_default "$V6_TUN_IF" "$V6_TUN_IF"; else status_line route_default missing "$V6_TUN_IF"; fi
  while IFS='|' read -r status_iface status_cidr status_pref; do
    if route4_exists "$V6_ROUTE_TABLE" "$status_cidr" "$status_iface"; then status_line "route_$status_iface" "$status_cidr" "$status_cidr"; else status_line "route_$status_iface" missing "$status_cidr"; fi
    if rule4_exists "$status_pref" "$status_iface" "$V6_ROUTE_TABLE"; then status_line "rule_$status_iface" "$status_pref" "$status_pref"; else status_line "rule_$status_iface" missing "$status_pref"; fi
    if "$V6_IPTABLES_CMD" -t nat -C "$NAT_CHAIN" -s "$status_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" >/dev/null 2>&1; then status_line "snat_$status_iface" present present; else status_line "snat_$status_iface" missing present; fi
  done <"$WORK_DIR/status-desired"
  if "$V6_IPTABLES_CMD" -t mangle -C FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" >/dev/null 2>&1; then status_line mss_forward_out present present; else status_line mss_forward_out missing present; fi
  if "$V6_IPTABLES_CMD" -t mangle -C FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" >/dev/null 2>&1; then status_line mss_forward_in present present; else status_line mss_forward_in missing present; fi
  if "$V6_IPTABLES_CMD" -t mangle -C OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" >/dev/null 2>&1; then status_line mss_output present present; else status_line mss_output missing present; fi
  if [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    if "$V6_IP6TABLES_CMD" -C "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT >/dev/null 2>&1; then status_line outer_rule present present; else status_line outer_rule missing present; fi
  else
    if [ "$LAST_V6_INPUT_CHAIN" != none ] && "$V6_IP6TABLES_CMD" -C "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT >/dev/null 2>&1; then status_line outer_rule present absent; else status_line outer_rule absent absent; fi
  fi
  check_material_status || STATUS_FAILED=1
  [ "$STATUS_FAILED" -eq 0 ]
}

automation_active() {
  for unit in unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.service unifi-jpix-tunnel-repair-update.timer; do
    systemctl is-active --quiet "$unit" >/dev/null 2>&1
    automation_status=$?
    case $automation_status in 0) return 0 ;; 3) ;; *) return 2 ;; esac
  done
  return 1
}

validate_off_routes() {
  "$V6_IP_CMD" -4 route show table "$V6_ROUTE_TABLE" >"$WORK_DIR/off-preflight-routes" 2>/dev/null || return 1
  : >"$WORK_DIR/off-route-identities" || return 1
  while IFS= read -r off_route_line || [ -n "$off_route_line" ]; do
    [ -n "$off_route_line" ] || continue
    off_route_line=$(canonical_route_vector "$off_route_line") || return 1
    set -- $off_route_line
    off_route_destination=$1
    off_route_iface=$(read_token_after dev "$@") || return 1
    if [ "$off_route_destination" = default ] && [ "$off_route_iface" = "$V6_TUN_IF" ]; then
      :
    else
      awk -F'|' -v cidr="$off_route_destination" -v iface="$off_route_iface" \
        '$1 == iface && $2 == cidr { found=1 } END { exit !found }' "$OLD_NETWORKS" || return 1
    fi
    printf '%s|%s\n' "$off_route_destination" "$off_route_iface" >>"$WORK_DIR/off-route-identities" || return 1
  done <"$WORK_DIR/off-preflight-routes"
  [ -z "$(sort "$WORK_DIR/off-route-identities" | uniq -d)" ]
}

validate_off_rules() {
  "$V6_IP_CMD" -4 rule show >"$WORK_DIR/off-preflight-rules" 2>/dev/null || return 1
  awk -F'|' '{ print $3 }' "$OLD_NETWORKS" >"$WORK_DIR/off-owned-prefs" || return 1
  while IFS= read -r off_rule_line || [ -n "$off_rule_line" ]; do
    [ -n "$off_rule_line" ] || continue
    set -- $off_rule_line
    off_rule_pref=${1%:}
    grep -F -x -- "$off_rule_pref" "$WORK_DIR/off-owned-prefs" >/dev/null 2>&1 || continue
    [ "$#" -eq 7 ] && [ "$2" = from ] && [ "$3" = all ] && [ "$4" = iif ] && [ "$6" = lookup ] || return 1
    awk -F'|' -v pref="$off_rule_pref" -v iface="$5" -v table="$7" -v owned="$V6_ROUTE_TABLE" '
      $3 == pref && $1 == iface && table == owned { found=1 }
      END { exit !found }
    ' "$OLD_NETWORKS" || return 1
  done <"$WORK_DIR/off-preflight-rules"
}

append_allowed_firewall_rule() {
  allowed_output=$1
  allowed_chain=$2
  shift 2
  firewall_expected_line "$allowed_chain" "$@" >>"$allowed_output"
}

validate_off_firewall() {
  : >"$WORK_DIR/off-allowed-nat" || return 1
  : >"$WORK_DIR/off-allowed-mangle" || return 1
  : >"$WORK_DIR/off-allowed-v6" || return 1
  : >"$WORK_DIR/off-allowed-global" || return 1
  while IFS='|' read -r off_iface off_cidr off_pref; do
    append_allowed_firewall_rule "$WORK_DIR/off-allowed-nat" "$LAST_NAT_CHAIN" -s "$off_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
    append_allowed_inventory_rule "$WORK_DIR/off-allowed-global" 4 nat "$LAST_NAT_CHAIN" -s "$off_cidr" -o "$V6_TUN_IF" -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source "$V6_STATIC_V4" || return 1
  done <"$OLD_NETWORKS"
  append_allowed_firewall_rule "$WORK_DIR/off-allowed-mangle" FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_firewall_rule "$WORK_DIR/off-allowed-mangle" FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_firewall_rule "$WORK_DIR/off-allowed-mangle" OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/off-allowed-global" 4 mangle FORWARD -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/off-allowed-global" 4 mangle FORWARD -i "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  append_allowed_inventory_rule "$WORK_DIR/off-allowed-global" 4 mangle OUTPUT -o "$V6_TUN_IF" -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss "$V6_TCP_MSS" || return 1
  if [ "$LAST_V6_INPUT_MANAGED" = yes ]; then
    append_allowed_firewall_rule "$WORK_DIR/off-allowed-v6" "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
    append_allowed_inventory_rule "$WORK_DIR/off-allowed-global" 6 filter "$LAST_V6_INPUT_CHAIN" -s "$V6_BR_V6/128" -d "$LAST_LOCAL_V6/128" -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT || return 1
  fi
  capture_firewall_snapshot off-firewall || return 1
  capture_firewall_inventory off-inventory || return 1
  validate_tagged_subset "$WORK_DIR/off-firewall-nat" "$WORK_DIR/off-allowed-nat" "$WORK_DIR/off-tagged-nat" yes || return 1
  validate_tagged_subset "$WORK_DIR/off-firewall-mangle" "$WORK_DIR/off-allowed-mangle" "$WORK_DIR/off-tagged-mangle" yes || return 1
  validate_tagged_subset "$WORK_DIR/off-firewall-v6" "$WORK_DIR/off-allowed-v6" "$WORK_DIR/off-tagged-v6" yes || return 1
  validate_inventory_tagged_subset "$WORK_DIR/off-inventory-all" "$WORK_DIR/off-allowed-global" "$WORK_DIR/off-tagged-global" yes || return 1
}

validate_off_ownership() {
  validate_off_routes && validate_off_rules && validate_off_firewall
}

remove_managed_state() {
  remove_kind=$1
  remove_path=$2
  remove_inverse=$3
  [ -e "$remove_path" ] || return 0
  record_inverse "$remove_inverse" || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ] && [ "${V6PLUS_TEST_FAIL_OFF_REMOVE:-}" = "$remove_kind" ]; then
    return 1
  fi
  rm -f -- "$remove_path" || return 1
  [ ! -e "$remove_path" ] || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ] && [ "${V6PLUS_TEST_SIGNAL_AFTER_STATE_REMOVE:-}" = "$remove_kind" ]; then
    kill -TERM "$$"
    sleep 1
  fi
}

off_mutations() {
  ensure_state_dir || return 1
  [ -f "$ORIGINAL_FILE" ] || { v6_log 'ERROR original snapshot missing'; return 1; }
  validate_state_file "$ORIGINAL_FILE" || return 1
  load_original_state "$ORIGINAL_FILE" || return 1
  [ "$ORIGINAL_TUN_IF" = "$V6_TUN_IF" ] || { v6_log 'ERROR tunnel identity mismatch'; return 1; }
  HAVE_MANAGED=0
  OLD_NETWORKS=$WORK_DIR/off-networks
  : >"$OLD_NETWORKS" || return 1
  if [ -f "$MANAGED_FILE" ] || [ -f "$LAST_FILE" ]; then
    [ -f "$MANAGED_FILE" ] && [ -f "$LAST_FILE" ] || return 1
    validate_state_file "$MANAGED_FILE" && validate_state_file "$LAST_FILE" || return 1
    load_managed_state "$MANAGED_FILE" "$OLD_NETWORKS" && load_last_state "$LAST_FILE" || return 1
    cp "$MANAGED_FILE" "$WORK_DIR/previous-managed" && cp "$LAST_FILE" "$WORK_DIR/previous-last" || return 1
    HAVE_MANAGED=1
  fi
  if [ "${V6PLUS_FORCE_OFF:-0}" != 1 ]; then
    automation_active
    automation_check=$?
    case $automation_check in
      0) v6_log 'ERROR active automation prevents off'; return 1 ;;
      1) ;;
      *) v6_log 'ERROR automation inspection failed'; return 1 ;;
    esac
  fi
  current_tunnel || return 1
  tunnel_mode_command_safe "$CURRENT_TUN_MODE" || return 1
  if [ "$HAVE_MANAGED" -eq 1 ]; then [ "$CURRENT_TUN_MODE" = ipip6 ] || return 1; fi
  current_tunnel_link || return 1
  current_tunnel_ipv4 || return 1
  if [ "$HAVE_MANAGED" -eq 1 ]; then
    "$V6_IP_CMD" -6 addr show dev "$V6_WAN_IF" >"$WORK_DIR/off-preflight-addr6" 2>/dev/null || return 1
    validate_off_ownership || { v6_log 'ERROR managed state identity mismatch'; return 1; }
  fi

  start_transaction || return 1
  if [ "$HAVE_MANAGED" -eq 1 ]; then
    mutate_mss_output_del && mutate_mss_in_del && mutate_mss_out_del || { mutation_failed off_mss; return 1; }
    awk '{ rows[NR]=$0 } END { for (i=NR; i>=1; i--) print rows[i] }' "$OLD_NETWORKS" >"$WORK_DIR/off-networks-reverse" || { mutation_failed off_prepare; return 1; }
    while IFS='|' read -r off_iface off_cidr off_pref; do
      mutate_snat_del "$LAST_NAT_CHAIN" "$off_cidr" && mutate_rule_del "$off_pref" "$off_iface" "$V6_ROUTE_TABLE" && mutate_route_del "$V6_ROUTE_TABLE" "$off_cidr" "$off_iface" || { mutation_failed off_network; return 1; }
    done <"$WORK_DIR/off-networks-reverse"
    if [ "$LAST_V6_INPUT_MANAGED" = yes ]; then mutate_outer_del "$LAST_V6_INPUT_CHAIN" "$V6_BR_V6" "$LAST_LOCAL_V6" || { mutation_failed off_outer; return 1; }; fi
    mutate_route_del "$V6_ROUTE_TABLE" default "$V6_TUN_IF" || { mutation_failed off_default; return 1; }
    mutate_addr6_del "$V6_WAN_IF" "$LAST_LOCAL_V6/128" || { mutation_failed off_wan; return 1; }
  fi
  mutate_addr4_del "$V6_TUN_IF" "$V6_STATIC_V4/32" || { mutation_failed off_fixed_ipv4; return 1; }
  mutate_addr4_add "$ORIGINAL_TUN_IF" "$ORIGINAL_TUN_IPV4" || { mutation_failed off_original_ipv4; return 1; }
  if [ "$CURRENT_TUN_MODE" != "$ORIGINAL_TUN_MODE" ]; then
    record_inverse "TUNNEL_CHANGE|$V6_TUN_IF|$CURRENT_TUN_MODE|$CURRENT_TUN_LOCAL|$CURRENT_TUN_REMOTE" &&
      v6_run "$V6_IP_CMD" -6 tunnel change "$ORIGINAL_TUN_IF" mode "$ORIGINAL_TUN_MODE" local "$ORIGINAL_TUN_LOCAL" remote "$ORIGINAL_TUN_REMOTE" || { mutation_failed off_tunnel; return 1; }
    PHYSICAL_MUTATED=1
  elif tunnel_endpoints_equal "$CURRENT_TUN_LOCAL" "$ORIGINAL_TUN_LOCAL" "$CURRENT_TUN_REMOTE" "$ORIGINAL_TUN_REMOTE"; then
    :
  else
    off_tunnel_status=$?
    [ "$off_tunnel_status" -eq 1 ] || { mutation_failed off_tunnel; return 1; }
    record_inverse "TUNNEL_CHANGE|$V6_TUN_IF|$CURRENT_TUN_MODE|$CURRENT_TUN_LOCAL|$CURRENT_TUN_REMOTE" &&
      v6_run "$V6_IP_CMD" -6 tunnel change "$ORIGINAL_TUN_IF" mode "$ORIGINAL_TUN_MODE" local "$ORIGINAL_TUN_LOCAL" remote "$ORIGINAL_TUN_REMOTE" || { mutation_failed off_tunnel; return 1; }
    PHYSICAL_MUTATED=1
  fi
  if [ "$CURRENT_TUN_MTU" != "$ORIGINAL_TUN_MTU" ] || [ "$CURRENT_TUN_UP" != "$ORIGINAL_TUN_UP" ]; then
    case $ORIGINAL_TUN_UP in yes) off_link_state=up ;; no) off_link_state=down ;; esac
    record_inverse "LINK_SET|$V6_TUN_IF|$CURRENT_TUN_MTU|$CURRENT_TUN_UP" &&
      v6_run "$V6_IP_CMD" link set dev "$ORIGINAL_TUN_IF" mtu "$ORIGINAL_TUN_MTU" "$off_link_state" || { mutation_failed off_link; return 1; }
    PHYSICAL_MUTATED=1
  fi
  if [ "$HAVE_MANAGED" -eq 1 ]; then
    remove_managed_state managed "$MANAGED_FILE" STATE_MANAGED_RESTORE || { mutation_failed off_state_managed; return 1; }
    remove_managed_state last "$LAST_FILE" STATE_LAST_RESTORE || { mutation_failed off_state_last; return 1; }
  fi
  commit_transaction || { mutation_failed off_commit; return 1; }
}

case $ACTION in
  status)
    trap 'apply_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    check_status
    exit $?
    ;;
  apply)
    load_configuration || exit $?
    require_root || exit 1
    acquire_shared_lock || exit 1
    if [ -e "$V6PLUS_STATE_DIR" ]; then v6_validate_state_dir || { runtime_error state_dir; exit 1; }; fi
    make_work_dir || { runtime_error workdir; exit 1; }
    prepare_plan
    prepare_status=$?
    if [ "$prepare_status" -eq 2 ]; then config_error plan; exit 2; fi
    [ "$prepare_status" -eq 0 ] || { runtime_error preflight; exit 1; }
    if [ "$DRY_RUN" -eq 1 ]; then dry_run_plan || { runtime_error dry_run; exit 1; }; exit 0; fi
    apply_mutations || exit 1
    exit 0
    ;;
  off)
    load_configuration || exit $?
    require_root || exit 1
    acquire_shared_lock || exit 1
    make_work_dir || { runtime_error workdir; exit 1; }
    off_mutations || exit 1
    exit 0
    ;;
esac
