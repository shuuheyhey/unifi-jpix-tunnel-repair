#!/bin/sh
set -eu

ROOT=${V6PLUS_ROOT:-/data/unifi-jpix-tunnel-repair}
CONFIG_DIR=$ROOT/config
DIAG_SKIP_CONNECTIVITY=${DIAG_SKIP_CONNECTIVITY:-0}
VERSION_FILE=${V6PLUS_VERSION_FILE:-/usr/lib/version}
DISCOVER=0
FULL_OUTPUT=
full_output_seen=0

usage() {
  printf 'usage: %s [--config DIR] [--discover] [--full-output ABSOLUTE_PATH]\n' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --config)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CONFIG_DIR=$2
      shift 2
      ;;
    --discover)
      [ "$DISCOVER" -eq 0 ] || { usage; exit 2; }
      DISCOVER=1
      shift
      ;;
    --full-output)
      [ "$full_output_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      FULL_OUTPUT=$2
      full_output_seen=1
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [ "${V6PLUS_LIB+x}" = x ]; then
  LIB=$V6PLUS_LIB
else
  LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh
fi
[ -f "$LIB" ] || { printf 'diagnostic library not found\n' >&2; exit 2; }
# This is trusted program code. Configuration and state files are never sourced.
. "$LIB"
V6PLUS_STATE_DIR=${V6PLUS_STATE_DIR:-/data/unifi-jpix-tunnel-repair/state}

DIAG_TEMP_DIR=
DIAG_REPORT=
DIAG_COMPLETE=0
diag_finish() {
  diag_status=$?
  trap - EXIT
  exec 1>&3
  if [ "$DIAG_COMPLETE" -eq 1 ] && [ -n "$FULL_OUTPUT" ]; then
    if ln "$DIAG_REPORT" "$FULL_OUTPUT"; then
      rm -f -- "$DIAG_REPORT"
    else
      DIAG_COMPLETE=0
      diag_status=2
    fi
  else
    rm -f -- "$DIAG_REPORT" 2>/dev/null || :
  fi
  rmdir "$DIAG_TEMP_DIR" 2>/dev/null || :
  printf 'DIAGNOSTIC_MODE=share-safe\n'
  case $diag_status in
    0) printf 'RESULT=ready\n' ;;
    1) printf 'RESULT=not-ready\n' ;;
    *) printf 'RESULT=invalid\n' ;;
  esac
  if [ -n "$FULL_OUTPUT" ] && [ "$DIAG_COMPLETE" -eq 1 ] && [ "$diag_status" -lt 2 ]; then
    printf 'FULL_OUTPUT=written\n'
  else
    printf 'FULL_OUTPUT=not-requested\n'
  fi
  exit "$diag_status"
}

if [ -n "$FULL_OUTPUT" ]; then
  case $FULL_OUTPUT in /*) ;; *) printf 'full output path must be absolute\n' >&2; exit 2 ;; esac
  [ ! -e "$FULL_OUTPUT" ] && [ ! -L "$FULL_OUTPUT" ] || { printf 'full output path already exists\n' >&2; exit 2; }
  diag_parent=${FULL_OUTPUT%/*}
  [ -n "$diag_parent" ] || diag_parent=/
  v6_validate_canonical_secure_directory "$diag_parent" || { printf 'unsafe full output directory\n' >&2; exit 2; }
  DIAG_TEMP_DIR=$(umask 077 && mktemp -d "$diag_parent/.unifi-jpix-tunnel-repair-diag.XXXXXX") || exit 2
else
  DIAG_TEMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/unifi-jpix-tunnel-repair-diag.XXXXXX") || exit 2
fi
chmod 700 "$DIAG_TEMP_DIR" || exit 2
DIAG_REPORT=$DIAG_TEMP_DIR/report
(umask 077 && : >"$DIAG_REPORT") || exit 2
chmod 600 "$DIAG_REPORT" || exit 2
exec 3>&1
trap diag_finish EXIT
exec >"$DIAG_REPORT"

dependency_missing=0
for dependency in ip iptables ip6tables curl systemctl; do
  if command -v "$dependency" >/dev/null 2>&1; then
    printf 'DEPENDENCY_%s=ok\n' "$dependency"
  else
    printf 'DEPENDENCY_%s=missing\n' "$dependency"
    dependency_missing=1
  fi
done
if [ "$dependency_missing" -ne 0 ]; then
  DIAG_COMPLETE=1
  exit 1
fi

discover_load_main() {
  discover_file=$1
  [ -f "$discover_file" ] || return 1
  unset V6_BR_V6 V6_IID V6_TUN_IF
  discover_seen='|'
  while IFS= read -r discover_line || [ -n "$discover_line" ]; do
    case $discover_line in
      ''|'#'*) continue ;;
      *=*) ;;
      *) return 1 ;;
    esac
    discover_key=${discover_line%%=*}
    discover_value=${discover_line#*=}
    case $discover_key in
      WAN_IF|STATIC_V4|TUN_MTU|TCP_MSS|ROUTE_TABLE|RULE_PREF_BASE|WATCH_INTERVAL_SECONDS|UPDATE_INTERVAL_SECONDS|OUTER_IPIP_ALLOW)
        ;;
      BR_V6|IID|TUN_IF)
        case $discover_seen in *"|$discover_key|"*) return 1 ;; esac
        discover_seen=$discover_seen$discover_key'|'
        case $discover_key in
          BR_V6) V6_BR_V6=$discover_value ;;
          IID) V6_IID=$discover_value ;;
          TUN_IF) V6_TUN_IF=$discover_value ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done <"$discover_file"
  [ "${V6_BR_V6+x}" = x ] && [ "${V6_IID+x}" = x ] || return 1
  v6_is_ipv6 "$V6_BR_V6" || return 1
  if [ "${V6_TUN_IF+x}" = x ]; then
    v6_is_iface_value "$V6_TUN_IF" || return 1
  fi
  v6_compose_local_v6 "$V6_BR_V6" "$V6_IID" >/dev/null 2>&1
}

diag_iter_networks() {
  diag_networks_file=$1
  diag_network_rows=$(awk '
    { sub(/[[:space:]]*#.*/, "") }
    NF == 0 { next }
    NF != 2 { exit 1 }
    { print $1 "|" $2 }
  ' "$diag_networks_file") || return 1
  [ -n "$diag_network_rows" ] || return 0
  printf '%s\n' "$diag_network_rows" | while IFS='|' read -r diag_iface diag_cidr; do
    [ -n "$diag_iface" ] && [ -n "$diag_cidr" ] || exit 1
    v6_is_cidr "$diag_cidr" || exit 1
    case ${diag_seen_rows:-'|'} in
      *"|$diag_iface|$diag_cidr|"*) exit 1 ;;
    esac
    diag_seen_rows=${diag_seen_rows:-'|'}$diag_iface'|'$diag_cidr'|'
    printf '%s|%s\n' "$diag_iface" "$diag_cidr"
  done
}

if [ "$DISCOVER" -eq 1 ]; then
  v6_validate_canonical_secure_directory "$CONFIG_DIR" &&
    v6_validate_private_file "$CONFIG_DIR/gateway.conf" 600 || {
      printf 'invalid discovery configuration\n' >&2
      exit 2
    }
  discover_load_main "$CONFIG_DIR/gateway.conf" || {
    printf 'invalid discovery configuration\n' >&2
    exit 2
  }
  V6_ROUTE_TABLE=
  V6_RULE_PREF_BASE=
  V6_STATIC_V4=
  V6_TUN_MTU=
  network_rows=
else
  if ! v6_load_main_config "$CONFIG_DIR/gateway.conf" "$CONFIG_DIR/routed-networks.conf"; then
    printf 'invalid diagnostic configuration\n' >&2
    exit 2
  fi
  main_networks_config=$V6_NETWORKS_CONFIG
  V6_NETWORKS_CONFIG=/dev/null
  if ! v6_validate_main_config; then
    printf 'invalid diagnostic configuration\n' >&2
    exit 2
  fi
  V6_NETWORKS_CONFIG=$main_networks_config
  network_rows=$(diag_iter_networks "$CONFIG_DIR/routed-networks.conf") || {
    printf 'invalid networks configuration\n' >&2
    exit 2
  }
fi

sanitize_line() {
  v6_redact "$1" | LC_ALL=C tr -cd '\11\12\40-\176' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

sanitize_snapshot() {
  snapshot_data=$1
  if [ -n "$snapshot_data" ]; then
    printf '%s\n' "$snapshot_data" | while IFS= read -r snapshot_line; do
      sanitize_line "$snapshot_line"
    done
  fi
}

first_line() {
  first_line_value=
  if IFS= read -r first_line_value || [ -n "$first_line_value" ]; then
    printf '%s\n' "$first_line_value"
  fi
}

tunnel_mode_is_discoverable() {
  case $1 in
    ipip6|ip/ipv6|any/ipv6) return 0 ;;
    *) return 1 ;;
  esac
}

tunnel_mode_is_ready() {
  case $1 in
    ipip6|ip/ipv6) return 0 ;;
    *) return 1 ;;
  esac
}

discover_br_tunnel_matches() {
  discover_expected_remote=$1
  ip -d -6 tunnel show 2>/dev/null | while IFS= read -r discover_tunnel_line; do
    discover_tunnel_iface=${discover_tunnel_line%%:*}
    discover_tunnel_mode=$(printf '%s\n' "$discover_tunnel_line" | awk 'NR == 1 { print $2; exit }')
    tunnel_mode_is_discoverable "$discover_tunnel_mode" || continue
    v6_is_iface_value "$discover_tunnel_iface" || continue
    discover_tunnel_remote=$(printf '%s\n' "$discover_tunnel_line" | awk '
      { for (i = 1; i < NF; i++) if ($i == "remote") { print $(i + 1); exit } }
    ')
    discover_tunnel_remote_expanded=$(v6_expand_ipv6 "${discover_tunnel_remote%%%*}" 2>/dev/null || :)
    if [ "$discover_tunnel_remote_expanded" = "$discover_expected_remote" ]; then
      printf '%s\n' "$discover_tunnel_iface"
    fi
  done | LC_ALL=C sort -u
}

readiness=0

unifi_os_version=unknown
unifi_os_candidate=
if command -v ubnt-device-info >/dev/null 2>&1; then
  unifi_os_candidate=$(ubnt-device-info firmware 2>/dev/null | first_line || :)
fi
if [ -z "$unifi_os_candidate" ] && [ -r "$VERSION_FILE" ]; then
  unifi_os_candidate=$(first_line <"$VERSION_FILE" || :)
fi
[ -z "$unifi_os_candidate" ] || unifi_os_version=$(sanitize_line "$unifi_os_candidate")

unifi_network_version=unknown
if command -v dpkg-query >/dev/null 2>&1; then
  unifi_network_candidate=$(dpkg-query -W -f='${Version}\n' unifi 2>/dev/null | first_line || :)
  [ -z "$unifi_network_candidate" ] || unifi_network_version=$(sanitize_line "$unifi_network_candidate")
fi

br_route_output=$(ip -6 route get "$V6_BR_V6" 2>/dev/null || :)
br_route_dev=$(printf '%s\n' "$br_route_output" | awk '
  {
    for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }
  }
')
[ -n "$br_route_dev" ] || { br_route_dev=none; readiness=1; }

if [ "$DISCOVER" -eq 1 ]; then
  WAN_IF=$br_route_dev
else
  WAN_IF=$V6_WAN_IF
fi

wan_link_output=
if [ "$WAN_IF" != none ]; then
  wan_link_output=$(ip -o link show dev "$WAN_IF" 2>/dev/null || :)
fi
case $wan_link_output in
  *'state UP'*|*'LOWER_UP'*) wan_link=up ;;
  '') wan_link=missing; readiness=1 ;;
  *) wan_link=down; readiness=1 ;;
esac

wan_speed=unknown
if [ "$WAN_IF" != none ] && [ -r "/sys/class/net/$WAN_IF/speed" ]; then
  wan_speed_candidate=$(first_line <"/sys/class/net/$WAN_IF/speed" 2>/dev/null || :)
  if v6_is_uint "$wan_speed_candidate" && [ "$wan_speed_candidate" -gt 0 ]; then
    wan_speed=$wan_speed_candidate
  fi
fi

wan_global_raw=
if [ "$WAN_IF" != none ]; then
  wan_global_raw=$(ip -6 addr show dev "$WAN_IF" scope global 2>/dev/null | awk '
    /inet6 / {
      candidate = $2
      deprecated = ($0 ~ / deprecated/)
      next
    }
    /preferred_lft/ && candidate != "" {
      if (!deprecated && $0 !~ /preferred_lft 0sec/) {
        print candidate
        exit
      }
      candidate = ""
    }
  ' || :)
fi
wan_global=none
if [ -n "$wan_global_raw" ]; then
  wan_global_candidate=$(v6_expand_ipv6 "${wan_global_raw%%%*}" 2>/dev/null || :)
  [ -z "$wan_global_candidate" ] || wan_global=$wan_global_candidate
fi
[ "$wan_global" != none ] || readiness=1

pd_candidates=$(
  {
    ip -6 route show table all proto dhcp 2>/dev/null || :
    ip -6 route show table all proto ra 2>/dev/null || :
  } | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\//) print $i }' |
  while IFS= read -r pd_prefix; do
    pd_address=${pd_prefix%/*}
    pd_length=${pd_prefix#*/}
    v6_is_uint "$pd_length" || continue
    [ "$pd_length" -ge 48 ] && [ "$pd_length" -le 63 ] || continue
    pd_non_global=$(printf '%s\n' "$pd_address" | awk '
      { value = tolower($0) }
      value ~ /^:/ || value ~ /^fe[89ab]/ || value ~ /^f[cd]/ || value ~ /^ff/ { print "yes" }
    ')
    [ "$pd_non_global" != yes ] || continue
    pd_expanded=$(v6_expand_ipv6 "$pd_address" 2>/dev/null || :)
    [ -n "$pd_expanded" ] && printf '%s/%s\n' "$pd_expanded" "$pd_length"
  done | LC_ALL=C sort -u
)

route_source_raw=$(v6_route_source_v6 "$V6_BR_V6" 2>/dev/null || :)
route_source=none
if [ -n "$route_source_raw" ]; then
  route_source_candidate=$(v6_expand_ipv6 "$route_source_raw" 2>/dev/null || :)
  [ -z "$route_source_candidate" ] || route_source=$route_source_candidate
fi
[ "$route_source" != none ] || readiness=1

local_tunnel=none
if [ "$route_source" != none ]; then
  local_tunnel_candidate=$(v6_compose_local_v6 "$route_source" "$V6_IID" 2>/dev/null || :)
  [ -z "$local_tunnel_candidate" ] || local_tunnel=$local_tunnel_candidate
fi
[ "$local_tunnel" != none ] || readiness=1

if [ "$DISCOVER" -eq 1 ]; then
  tunnel_selection=none
  V6_TUN_IF=none
  expected_tunnel_remote=$(v6_expand_ipv6 "$V6_BR_V6" 2>/dev/null || :)
  tunnel_matches=$(discover_br_tunnel_matches "$expected_tunnel_remote" || :)
  tunnel_match_count=$(printf '%s\n' "$tunnel_matches" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$tunnel_match_count" -eq 1 ]; then
    tunnel_selection=br-remote-match
    V6_TUN_IF=$tunnel_matches
  elif [ "$tunnel_match_count" -gt 1 ]; then
    tunnel_selection=ambiguous
    readiness=1
  else
    readiness=1
  fi
else
  tunnel_selection=configured
fi

tunnel_output=
if [ "$V6_TUN_IF" != none ] && tunnel_output=$(ip -d -6 tunnel show "$V6_TUN_IF" 2>/dev/null); then
  tunnel_exists=yes
else
  tunnel_exists=no
  readiness=1
fi

tunnel_local=none
tunnel_remote=none
tunnel_ipv4=none
tunnel_mtu=none
if [ "$tunnel_exists" = yes ]; then
  tunnel_mode=$(printf '%s\n' "$tunnel_output" | awk 'NR == 1 { print $2; exit }')
  tunnel_mode_is_ready "$tunnel_mode" || readiness=1
  tunnel_local_candidate=$(printf '%s\n' "$tunnel_output" | awk '{ for (i=1; i<NF; i++) if ($i == "local") { print $(i+1); exit } }')
  tunnel_remote_candidate=$(printf '%s\n' "$tunnel_output" | awk '{ for (i=1; i<NF; i++) if ($i == "remote") { print $(i+1); exit } }')
  [ -z "$tunnel_local_candidate" ] || tunnel_local=$(sanitize_line "${tunnel_local_candidate%%%*}")
  [ -z "$tunnel_remote_candidate" ] || tunnel_remote=$(sanitize_line "${tunnel_remote_candidate%%%*}")
  tunnel_ipv4_candidate=$(ip -4 addr show dev "$V6_TUN_IF" 2>/dev/null | awk '/inet / { print $2; exit }' || :)
  [ -z "$tunnel_ipv4_candidate" ] || tunnel_ipv4=$(sanitize_line "${tunnel_ipv4_candidate%/*}")
  tunnel_link_output=$(ip -o link show dev "$V6_TUN_IF" 2>/dev/null || :)
  tunnel_mtu_candidate=$(printf '%s\n' "$tunnel_link_output" | awk '{ for (i=1; i<NF; i++) if ($i == "mtu") { print $(i+1); exit } }')
  if v6_is_uint "$tunnel_mtu_candidate"; then tunnel_mtu=$tunnel_mtu_candidate; fi
  [ "$tunnel_local" != none ] && [ "$tunnel_remote" != none ] &&
    [ "$tunnel_ipv4" != none ] && [ "$tunnel_mtu" != none ] || readiness=1
fi

router_ipv4_route=$(ip -4 route get 192.0.2.1 2>/dev/null | first_line || :)
[ -n "$router_ipv4_route" ] || router_ipv4_route=none
router_ipv4_route=$(sanitize_line "$router_ipv4_route")

if iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK >/dev/null 2>&1; then
  nat_chain=UBIOS_POSTROUTING_USER_HOOK
else
  nat_chain=POSTROUTING
fi
nat_snapshot=$(iptables -t nat -S "$nat_chain" 2>/dev/null | awk '/v6plus:/' || :)
nat_snapshot=$(sanitize_snapshot "$nat_snapshot")

if ip6tables -S UBIOS_INPUT_USER_HOOK >/dev/null 2>&1; then
  v6_input_chain=UBIOS_INPUT_USER_HOOK
else
  v6_input_chain=INPUT
fi
v6_input_snapshot=$(ip6tables -S "$v6_input_chain" 2>/dev/null || :)
outer_exact=no
outer_candidates=$(printf '%s\n' "$v6_input_snapshot" | awk -v chain="$v6_input_chain" '
  NF == 10 &&
  $1 == "-A" && $2 == chain &&
  $3 == "-s" && $5 == "-d" &&
  $7 == "-p" && ($8 == "4" || $8 == "ipencap") &&
  $9 == "-j" && $10 == "ACCEPT" {
    print $4 "|" $6
  }
  NF == 14 &&
  $1 == "-A" && $2 == chain &&
  $3 == "-s" && $5 == "-d" &&
  $7 == "-p" && ($8 == "4" || $8 == "ipencap") &&
  $9 == "-m" && $10 == "comment" &&
  $11 == "--comment" && $12 == "unifi-jpix-tunnel-repair" &&
  $13 == "-j" && $14 == "ACCEPT" {
    print $4 "|" $6
  }
')
expected_outer_remote=$(v6_expand_ipv6 "$V6_BR_V6" 2>/dev/null || :)
if [ -n "$outer_candidates" ] && [ -n "$expected_outer_remote" ] && [ "$local_tunnel" != none ]; then
  while IFS='|' read -r outer_source outer_destination; do
    outer_source_expanded=$(v6_expand_ipv6 "${outer_source%/128}" 2>/dev/null || :)
    outer_destination_expanded=$(v6_expand_ipv6 "${outer_destination%/128}" 2>/dev/null || :)
    if [ "$outer_source_expanded" = "$expected_outer_remote" ] &&
       [ "$outer_destination_expanded" = "$local_tunnel" ]; then
      outer_exact=yes
      break
    fi
  done <<EOF
$outer_candidates
EOF
fi

if [ -n "$V6_ROUTE_TABLE" ]; then
  route_table_snapshot=$(ip -4 route show table "$V6_ROUTE_TABLE" 2>/dev/null || :)
  route_table_empty=none
else
  route_table_snapshot=
  route_table_empty=unknown
fi
route_table_snapshot=$(sanitize_snapshot "$route_table_snapshot")

if [ -n "$V6_RULE_PREF_BASE" ]; then
  policy_limit=$((V6_RULE_PREF_BASE + 999))
  policy_snapshot=$(ip -4 rule show 2>/dev/null | awk -v low="$V6_RULE_PREF_BASE" -v high="$policy_limit" '
    {
      preference = $1
      sub(/:$/, "", preference)
      if (preference ~ /^[0-9]+$/ && preference >= low && preference <= high) print
    }
  ' || :)
  policy_empty=none
else
  policy_snapshot=
  policy_empty=unknown
fi
policy_snapshot=$(sanitize_snapshot "$policy_snapshot")

mangle_snapshot=$(iptables -t mangle -S 2>/dev/null | awk '/v6plus:/' || :)
mangle_snapshot=$(sanitize_snapshot "$mangle_snapshot")

last_update_local=none
last_update_succeeded=none
last_update_http=none
last_update_file=$V6PLUS_STATE_DIR/last-provider-update.state
if [ -e "$last_update_file" ] || [ -L "$last_update_file" ]; then
  if v6_validate_state_dir && v6_load_update_state "$last_update_file"; then
    last_update_local=$V6_LAST_UPDATE_LOCAL_V6
    last_update_succeeded=$V6_LAST_UPDATE_SUCCEEDED_AT
    last_update_http=$V6_LAST_UPDATE_HTTP_CODE
  fi
fi

if [ "$DIAG_SKIP_CONNECTIVITY" = 1 ]; then
  ipv4_connectivity=skipped
  ipv6_connectivity=skipped
else
  if curl -4 --silent --show-error --fail --max-time 5 https://connectivitycheck.gstatic.com/generate_204 >/dev/null 2>&1; then
    ipv4_connectivity=ok
  else
    ipv4_connectivity=failed
    readiness=1
  fi
  if curl -6 --silent --show-error --fail --max-time 5 https://connectivitycheck.gstatic.com/generate_204 >/dev/null 2>&1; then
    ipv6_connectivity=ok
  else
    ipv6_connectivity=failed
    readiness=1
  fi
fi

emit_numbered() {
  numbered_prefix=$1
  numbered_data=$2
  numbered_empty=$3
  if [ -n "$numbered_data" ]; then
    printf '%s\n' "$numbered_data" | awk -v prefix="$numbered_prefix" 'NF { count++; print prefix "_" count "=" $0 }'
  else
    printf '%s_1=%s\n' "$numbered_prefix" "$numbered_empty"
  fi
}

printf 'UNIFI_OS_VERSION=%s\n' "$unifi_os_version"
printf 'UNIFI_NETWORK_VERSION=%s\n' "$unifi_network_version"
printf 'BR_ROUTE_DEV=%s\n' "$br_route_dev"
printf 'WAN_IF=%s\n' "$WAN_IF"
printf 'WAN_LINK=%s\n' "$wan_link"
printf 'WAN_SPEED_MBIT=%s\n' "$wan_speed"
printf 'WAN_GLOBAL_V6=%s\n' "$wan_global"
emit_numbered PD_PREFIX "$pd_candidates" unknown
printf 'BR_ROUTE_SOURCE_V6=%s\n' "$route_source"
printf 'LOCAL_TUNNEL_V6=%s\n' "$local_tunnel"
printf 'TUN_SELECTION=%s\n' "$tunnel_selection"
printf 'TUN_IF=%s\n' "$V6_TUN_IF"
printf 'TUN_EXISTS=%s\n' "$tunnel_exists"
printf 'TUN_LOCAL_V6=%s\n' "$tunnel_local"
printf 'TUN_REMOTE_V6=%s\n' "$tunnel_remote"
printf 'TUN_IPV4=%s\n' "$tunnel_ipv4"
printf 'TUN_MTU=%s\n' "$tunnel_mtu"
printf 'ROUTER_IPV4_ROUTE=%s\n' "$router_ipv4_route"
printf 'NAT_CHAIN=%s\n' "$nat_chain"
printf 'V6_INPUT_CHAIN=%s\n' "$v6_input_chain"
printf 'OUTER_IPIP_EXACT_ACCEPT=%s\n' "$outer_exact"
emit_numbered ROUTE_TABLE_ENTRY "$route_table_snapshot" "$route_table_empty"
emit_numbered POLICY_RULE "$policy_snapshot" "$policy_empty"
emit_numbered NAT_RULE "$nat_snapshot" none
emit_numbered MANGLE_RULE "$mangle_snapshot" none
printf 'LAST_UPDATE_LOCAL_V6=%s\n' "$last_update_local"
printf 'LAST_UPDATE_SUCCEEDED_AT=%s\n' "$last_update_succeeded"
printf 'LAST_UPDATE_HTTP_CODE=%s\n' "$last_update_http"
printf 'IPV4_CONNECTIVITY=%s\n' "$ipv4_connectivity"
printf 'IPV6_CONNECTIVITY=%s\n' "$ipv6_connectivity"

if [ "$DISCOVER" -eq 1 ] || [ -z "$network_rows" ]; then
  printf 'NETWORK_1_IFACE=none\n'
  printf 'NETWORK_1_CIDR=none\n'
  printf 'NETWORK_1_LINK=none\n'
else
  network_number=0
  while IFS='|' read -r network_iface network_cidr; do
    network_number=$((network_number + 1))
    network_link_output=$(ip link show dev "$network_iface" 2>/dev/null || :)
    case $network_link_output in
      *'state UP'*|*'LOWER_UP'*) network_link=up ;;
      '') network_link=missing; readiness=1 ;;
      *) network_link=down; readiness=1 ;;
    esac
    printf 'NETWORK_%s_IFACE=%s\n' "$network_number" "$network_iface"
    printf 'NETWORK_%s_CIDR=%s\n' "$network_number" "$network_cidr"
    printf 'NETWORK_%s_LINK=%s\n' "$network_number" "$network_link"
  done <<EOF
$network_rows
EOF
fi

DIAG_COMPLETE=1
exit "$readiness"
