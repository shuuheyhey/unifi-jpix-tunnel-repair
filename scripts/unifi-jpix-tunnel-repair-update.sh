#!/bin/sh
set -u

ROOT=${V6PLUS_ROOT:-/data/unifi-jpix-tunnel-repair}
CONFIG_DIR=$ROOT/config
FORCE=0
config_seen=0
force_seen=0

usage() { printf 'usage: %s [--config DIR] [--force]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case $1 in
    --config)
      [ "$config_seen" -eq 0 ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      CONFIG_DIR=$2
      config_seen=1
      shift 2
      ;;
    --force)
      [ "$force_seen" -eq 0 ] || { usage; exit 2; }
      FORCE=1
      force_seen=1
      shift
      ;;
    *) usage; exit 2 ;;
  esac
done

if [ "${V6PLUS_LIB+x}" = x ]; then LIB=$V6PLUS_LIB; else LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh; fi
[ -f "$LIB" ] || { printf 'update library not found\n' >&2; exit 2; }
# This is trusted program code. Configuration and state records are parsed strictly as data.
. "$LIB"

# Remove inherited export attributes before any parser or helper starts a child.
unset line key value v6_update_line v6_update_key v6_update_value
unset v6_main_file v6_networks_file v6_seen_file v6_seen_status v6_update_seen_status
unset v6_canonical_dir v6_physical_dir
unset V6_CURL_ESCAPED_URL V6_CURL_ESCAPED_USERNAME V6_CURL_ESCAPED_PASSWORD
unset SOURCE_V6 ROUTE_SOURCE ENDPOINT_PREFIX LOCAL_V6 expanded_endpoint REDACTED_ENDPOINT NOW
unset source_listing source_line source_kind source_token source_rest source_prefix
unset source_address_with_zone source_address source_zone source_expanded source_match source_status elapsed
v6_clear_ipv6_helper_scratch
v6_clear_endpoint_helper_scratch

V6PLUS_STATE_DIR=${V6PLUS_STATE_DIR:-/data/unifi-jpix-tunnel-repair/state}
V6PLUS_LOCK_DIR=${V6PLUS_LOCK_DIR:-/run/unifi-jpix-tunnel-repair.lock}
V6_IP_CMD=${V6_IP_CMD:-ip}
V6_CURL_CMD=${V6_CURL_CMD:-curl}
LAST_UPDATE_FILE=$V6PLUS_STATE_DIR/last-provider-update.state
LOCK_HELD=0
TEMP_DIR=
BODY_FILE=
HTTP_FILE=
CURL_ERROR_FILE=

update_cleanup() {
  if [ -n "$TEMP_DIR" ]; then
    [ -z "$BODY_FILE" ] || rm -f -- "$BODY_FILE" 2>/dev/null || :
    [ -z "$HTTP_FILE" ] || rm -f -- "$HTTP_FILE" 2>/dev/null || :
    [ -z "$CURL_ERROR_FILE" ] || rm -f -- "$CURL_ERROR_FILE" 2>/dev/null || :
    rmdir "$TEMP_DIR" 2>/dev/null || :
  fi
  [ "$LOCK_HELD" -eq 1 ] || return 0
  v6_release_lock "$V6PLUS_LOCK_DIR"
}

config_error() { printf 'invalid update configuration\n' >&2; return 2; }
runtime_error() { v6_log "ERROR phase=$1"; return 1; }

load_configuration() {
  v6_validate_canonical_secure_directory "$CONFIG_DIR" || return 1
  v6_load_main_config "$CONFIG_DIR/gateway.conf" "$CONFIG_DIR/routed-networks.conf" || return 1
  v6_validate_main_config || return 1
  v6_load_update_config "$CONFIG_DIR/provider-update.conf"
}

safe_epoch() {
  v6_is_canonical_uint10 "$1"
}

ensure_state_dir() {
  if [ ! -e "$V6PLUS_STATE_DIR" ]; then
    (umask 077 && mkdir -- "$V6PLUS_STATE_DIR") || return 1
  fi
  v6_validate_state_dir
}

prepare_curl_config() {
  unset V6_CURL_ESCAPED_URL V6_CURL_ESCAPED_USERNAME V6_CURL_ESCAPED_PASSWORD
  V6_CURL_ESCAPED_URL=$(v6_curl_config_escape "$V6_UPDATE_URL") || return 1
  V6_CURL_ESCAPED_USERNAME=$(v6_curl_config_escape "$V6_UPDATE_USERNAME") || return 1
  V6_CURL_ESCAPED_PASSWORD=$(v6_curl_config_escape "$V6_UPDATE_PASSWORD") || return 1
}

exact_source_present() {
  unset source_listing source_line source_kind source_token source_rest source_prefix
  unset source_address_with_zone source_address source_zone source_expanded source_match
  source_listing=$("$V6_IP_CMD" -6 addr show dev "$V6_WAN_IF" 2>/dev/null) || return 2
  source_match=0
  while IFS= read -r source_line || [ -n "$source_line" ]; do
    source_kind=
    source_token=
    source_rest=
    IFS=' 	' read -r source_kind source_token source_rest <<EOF
$source_line
EOF
    [ -n "$source_kind" ] || continue
    [ "$source_kind" = inet6 ] || continue
    [ -n "$source_token" ] || return 2
    case $source_token in */*) ;; *) return 2 ;; esac
    case $source_token in */*/*) return 2 ;; esac
    source_prefix=${source_token##*/}
    v6_is_uint "$source_prefix" || return 2
    case $source_prefix in 0) ;; 0*) return 2 ;; esac
    [ "${#source_prefix}" -le 3 ] || return 2
    [ "$source_prefix" -le 128 ] || return 2
    source_address_with_zone=${source_token%/*}
    case $source_address_with_zone in
      *%*)
        source_address=${source_address_with_zone%%\%*}
        source_zone=${source_address_with_zone#*%}
        case $source_zone in ''|*[!A-Za-z0-9_.:-]*) return 2 ;; esac
        ;;
      *) source_address=$source_address_with_zone ;;
    esac
    case $source_address in ''|*%*|*/*) return 2 ;; esac
    source_expanded=$(v6_expand_ipv6 "$source_address") || return 2
    [ "$source_prefix" = 128 ] || continue
    [ "$source_expanded" = "$LOCAL_V6" ] && source_match=1
  done <<EOF
$source_listing
EOF
  [ "$source_match" -eq 1 ] && return 0
  return 1
}

make_temp_dir() {
  TEMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/unifi-jpix-tunnel-repair-update.XXXXXX") || return 1
  chmod 700 "$TEMP_DIR" || return 1
  BODY_FILE=$TEMP_DIR/body
  HTTP_FILE=$TEMP_DIR/http
  CURL_ERROR_FILE=$TEMP_DIR/curl-error
  (umask 077 && : >"$BODY_FILE" && : >"$HTTP_FILE" && : >"$CURL_ERROR_FILE") || return 1
  [ -z "${V6PLUS_TEST_TEMP_LOG:-}" ] || printf '%s\n' "$TEMP_DIR" >"$V6PLUS_TEST_TEMP_LOG" || return 1
  if [ "${V6PLUS_TEST_SIGNAL_AFTER_TEMP:-0}" = 1 ]; then
    kill -TERM "$$"
    sleep 1
  fi
}

valid_http_file() {
  awk 'NR == 1 { good = length($0) == 3 && $0 ~ /^[0-9][0-9][0-9]$/ && $0 >= 100 && $0 <= 599 } NR > 1 { good=0 } END { exit !good }' "$HTTP_FILE"
}

provider_body_success() {
  awk '
    {
      body = $0
      sub(/^[[:space:]]*/, "", body)
      if (body == "") next
      upper = toupper(body)
      if (upper ~ /^(NG|ERROR|FAIL)([[:space:]:]|$)/) exit 1
      exit 0
    }
  ' "$BODY_FILE"
}

write_success_state() {
  {
    printf 'LOCAL_V6=%s\n' "$LOCAL_V6"
    printf 'SUCCEEDED_AT=%s\n' "$NOW"
    printf 'HTTP_CODE=200\n'
  } | v6_write_atomic 600 "$LAST_UPDATE_FILE"
}

send_update() {
  case $V6_UPDATE_PROTO in
    https) update_curl_proto='=https'; update_curl_proto_redir='=https' ;;
    http) update_curl_proto='=http'; update_curl_proto_redir='=http' ;;
    *) return 1 ;;
  esac
  attempt=1
  while [ "$attempt" -le 3 ]; do
    : >"$BODY_FILE" || return 1
    : >"$HTTP_FILE" || return 1
    : >"$CURL_ERROR_FILE" || return 1
    "$V6_CURL_CMD" --config - --proto "$update_curl_proto" --proto-redir "$update_curl_proto_redir" \
      --ipv6 --interface "$LOCAL_V6" \
      --silent --show-error --connect-timeout 10 --max-time 30 \
      --output "$BODY_FILE" --write-out '%{http_code}' >"$HTTP_FILE" 2>"$CURL_ERROR_FILE" <<EOF
url = "$V6_CURL_ESCAPED_URL"
get
data-urlencode = "user=$V6_CURL_ESCAPED_USERNAME"
data-urlencode = "pass=$V6_CURL_ESCAPED_PASSWORD"
EOF
    transport_status=$?
    http_log=invalid
    if valid_http_file; then http_code=$(cat "$HTTP_FILE"); http_log=$http_code; else http_code=; fi
    if [ "$transport_status" -eq 0 ] && [ "$http_code" = 200 ] && provider_body_success; then
      v6_log "attempt=$attempt http=200 outcome=success endpoint=$REDACTED_ENDPOINT"
      write_success_state || { v6_log "attempt=$attempt http=200 outcome=state_failure endpoint=$REDACTED_ENDPOINT"; return 1; }
      return 0
    fi
    v6_log "attempt=$attempt http=$http_log outcome=failure endpoint=$REDACTED_ENDPOINT"
    [ "$attempt" -ge 3 ] || "$V6_SLEEP_CMD" 10 || return 1
    attempt=$((attempt + 1))
  done
  return 1
}

load_configuration || { config_error; exit 2; }
prepare_curl_config || { config_error; exit 2; }
if [ "$V6_UPDATE_PROTO" = http ]; then
  v6_log 'WARNING legacy HTTP update transport explicitly enabled; credentials are not confidential in transit'
fi
if [ "${V6PLUS_ALLOW_NONROOT:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  runtime_error privileges
  exit 1
fi

trap 'update_cleanup' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
LOCK_HELD=1
if ! v6_acquire_lock "$V6PLUS_LOCK_DIR"; then LOCK_HELD=0; runtime_error lock; exit 1; fi

ensure_state_dir || { runtime_error state_dir; exit 1; }
ROUTE_SOURCE=$(v6_route_source_v6 "$V6_BR_V6") || { runtime_error route_source; exit 1; }
v6_expand_ipv6 "$ROUTE_SOURCE" >/dev/null || { runtime_error route_source; exit 1; }
ENDPOINT_PREFIX=$(v6_endpoint_prefix64 "$V6_ENDPOINT_IF") || { runtime_error endpoint_prefix; exit 1; }
LOCAL_V6=$(v6_compose_local_v6 "$ENDPOINT_PREFIX" "$V6_IID") || { runtime_error local_source; exit 1; }
unset ROUTE_SOURCE ENDPOINT_PREFIX
if exact_source_present; then
  :
else
  source_status=$?
  case $source_status in
    1) runtime_error source_address ;;
    *) runtime_error source_inspection ;;
  esac
  exit 1
fi
unset source_listing source_line source_kind source_token source_rest source_prefix
unset source_address_with_zone source_address source_zone source_expanded source_match source_status
expanded_endpoint=$(v6_expand_ipv6 "$LOCAL_V6") || { runtime_error local_source; exit 1; }
REDACTED_ENDPOINT=$(printf '%s\n' "$expanded_endpoint" | cut -d: -f1-4 | tr '[:lower:]' '[:upper:]')::/64
unset expanded_endpoint

NOW=${V6PLUS_NOW:-$(date +%s)}
safe_epoch "$NOW" || { runtime_error timestamp; exit 1; }

if [ "$FORCE" -eq 0 ] && [ "$V6_UPDATE_INTERVAL_SECONDS" -eq 0 ]; then
  v6_log "attempt=0 http=none outcome=interval_disabled endpoint=$REDACTED_ENDPOINT"
  exit 0
fi

if [ -e "$LAST_UPDATE_FILE" ] || [ -L "$LAST_UPDATE_FILE" ]; then
  v6_validate_private_file "$LAST_UPDATE_FILE" 600 || { runtime_error previous_state; exit 1; }
  if [ "$FORCE" -eq 0 ]; then
    v6_load_update_state "$LAST_UPDATE_FILE" || { runtime_error previous_state; exit 1; }
    [ "$V6_LAST_UPDATE_SUCCEEDED_AT" -le "$NOW" ] || { runtime_error previous_state; exit 1; }
  fi
  if [ "$FORCE" -eq 0 ] && [ "$V6_LAST_UPDATE_LOCAL_V6" = "$LOCAL_V6" ]; then
    elapsed=$((NOW - V6_LAST_UPDATE_SUCCEEDED_AT))
    if [ "$elapsed" -lt "$V6_UPDATE_INTERVAL_SECONDS" ]; then
      v6_log "attempt=0 http=none outcome=interval_wait endpoint=$REDACTED_ENDPOINT"
      exit 0
    fi
  fi
fi

V6_SLEEP_CMD=${V6_SLEEP_CMD:-sleep}
make_temp_dir || { runtime_error response_temp; exit 1; }
send_update || { runtime_error notification; exit 1; }
exit 0
