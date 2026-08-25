#!/bin/sh

: "${V6PLUS_LOG_TAG:=v6plus}"
: "${DRY_RUN:=0}"
: "${V6_IP_CMD:=ip}"
: "${V6_IPTABLES_CMD:=iptables}"
: "${V6_IP6TABLES_CMD:=ip6tables}"
: "${V6PLUS_STATE_DIR:=/data/v6plus/state}"
: "${V6_CONTROL_GREP_CMD:=grep}"
: "${V6_CURL_SED_CMD:=sed}"
: "${V6_SEEN_GREP_CMD:=grep}"

v6_redact() {
  printf '%s\n' "$1" | sed -E \
    -e 's/(UPDATE_USERNAME=).*/\1[REDACTED]/g' \
    -e 's/(UPDATE_PASSWORD=).*/\1[REDACTED]/g' \
    -e 's/([?&]user=)[^&]*/\1[REDACTED]/g' \
    -e 's/([?&]pass=)[^&]*/\1[REDACTED]/g'
}

v6_log() {
  message=$(v6_redact "$*")
  printf '[%s] %s\n' "$V6PLUS_LOG_TAG" "$message" >&2
  command -v logger >/dev/null 2>&1 && logger -t "$V6PLUS_LOG_TAG" -- "$message" || :
}

v6_die() { v6_log "ERROR: $*"; return 1; }

v6_run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run]'
    for arg in "$@"; do printf ' %s' "$(v6_redact_arg "$arg")"; done
    printf '\n'
    return 0
  fi
  "$@"
}

# iptables and ip6tables return 4 when another process temporarily owns the
# xtables lock. UniFi can rebuild its firewall during boot, so retry only that
# transient condition; all other failures keep their existing fail-closed
# behavior.
v6_xtables_call() {
  [ "$#" -ge 1 ] || return 1
  v6_xtables_attempt=1
  while :; do
    if "$@"; then
      return 0
    else
      v6_xtables_status=$?
    fi
    [ "$v6_xtables_status" -eq 4 ] || return "$v6_xtables_status"
    [ "$v6_xtables_attempt" -lt 30 ] || return "$v6_xtables_status"
    v6_xtables_attempt=$((v6_xtables_attempt + 1))
    sleep 1 || return 1
  done
}

v6_run_xtables() {
  if [ "$DRY_RUN" = 1 ]; then
    v6_run "$@"
  else
    v6_xtables_call "$@"
  fi
}

v6_redact_arg() {
  v6_redact_argument=$(v6_redact "$1")
  for v6_redact_pair in \
    "${V6_REDACT_FIXED_V4:-}|[FIXED_V4]" \
    "${V6_REDACT_BR_V6:-}|[BR_V6]" \
    "${V6_REDACT_LOCAL_V6:-}|[LOCAL_V6]" \
    "${V6_REDACT_OLD_LOCAL_V6:-}|[OLD_LOCAL_V6]" \
    "${V6_REDACT_ORIGINAL_V4:-}|[ORIGINAL_V4]"
  do
    v6_redact_value=${v6_redact_pair%%|*}
    v6_redact_placeholder=${v6_redact_pair#*|}
    [ -n "$v6_redact_value" ] || continue
    case $v6_redact_argument in
      "$v6_redact_value") v6_redact_argument=$v6_redact_placeholder ;;
      "$v6_redact_value"/*) v6_redact_argument=$v6_redact_placeholder${v6_redact_argument#"$v6_redact_value"} ;;
    esac
  done
  printf '%s\n' "$v6_redact_argument"
}

v6_acquire_lock() {
  lock_dir=$1
  if ! (
    umask 077
    mkdir "$lock_dir" 2>/dev/null || exit 1
    printf '%s\n' "$$" >"$lock_dir/pid" || { rm -f -- "$lock_dir/pid" 2>/dev/null || :; rmdir "$lock_dir" 2>/dev/null || :; exit 1; }
    if [ "${V6PLUS_TEST_SIGNAL_DURING_LOCK:-0}" = 1 ]; then
      kill -TERM "$$"
      sleep 1
    fi
  ); then
    v6_lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if v6_is_uint "$v6_lock_pid"; then
      v6_log "lock held at $lock_dir by PID $v6_lock_pid; verify with kill -0 $v6_lock_pid before manually removing exactly $lock_dir"
    else
      v6_log "lock held at $lock_dir; inspect its PID and verify with kill -0 before manually removing exactly $lock_dir"
    fi
    return 1
  fi
}

v6_release_lock() {
  lock_dir=$1
  [ "$(cat "$lock_dir/pid" 2>/dev/null || true)" = "$$" ] || return 0
  rm -f -- "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || :
}

v6_make_seen_dir() {
  v6_seen_dir=${TMPDIR:-/tmp}/v6plus-seen.$$
  (umask 077 && mkdir "$v6_seen_dir") 2>/dev/null || return 1
}

v6_cleanup_seen_dir() {
  rm -f -- "$1"/* 2>/dev/null || :
  rmdir "$1" 2>/dev/null || :
}

v6_seen_key() {
  "$V6_SEEN_GREP_CMD" -F -x "$2" "$1" >/dev/null 2>&1
}

v6_validate_private_file() {
  [ "$#" -eq 2 ] || return 1
  unset v6_private_path v6_private_mode v6_private_actual_mode v6_private_owner
  v6_private_path=$1
  v6_private_mode=$2
  [ -f "$v6_private_path" ] && [ ! -L "$v6_private_path" ] || return 1
  v6_private_actual_mode=$(stat -c %a "$v6_private_path" 2>/dev/null) || return 1
  v6_private_owner=$(stat -c %u "$v6_private_path" 2>/dev/null) || return 1
  [ "$v6_private_actual_mode" = "$v6_private_mode" ] || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$v6_private_owner" = "$(id -u)" ]
  else
    [ "$v6_private_owner" = 0 ]
  fi
}

v6_validate_secure_directory() {
  [ "$#" -eq 1 ] || return 1
  unset v6_secure_dir v6_secure_mode v6_secure_owner v6_secure_group v6_secure_other
  v6_secure_dir=$1
  [ -d "$v6_secure_dir" ] && [ ! -L "$v6_secure_dir" ] || return 1
  v6_secure_mode=$(stat -c %a "$v6_secure_dir" 2>/dev/null) || return 1
  v6_secure_owner=$(stat -c %u "$v6_secure_dir" 2>/dev/null) || return 1
  case $v6_secure_mode in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
  v6_secure_group=${v6_secure_mode#?}
  v6_secure_group=${v6_secure_group%?}
  v6_secure_other=${v6_secure_mode#??}
  case $v6_secure_group in 2|3|6|7) return 1 ;; esac
  case $v6_secure_other in 2|3|6|7) return 1 ;; esac
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$v6_secure_owner" = "$(id -u)" ]
  else
    [ "$v6_secure_owner" = 0 ]
  fi
}

v6_validate_canonical_secure_directory() {
  [ "$#" -eq 1 ] || return 1
  unset v6_canonical_dir v6_physical_dir v6_chain_dir v6_chain_parent
  v6_canonical_dir=$1
  v6_has_no_control_character "$v6_canonical_dir" || return 1
  case $v6_canonical_dir in /*) ;; *) return 1 ;; esac
  case $v6_canonical_dir in
    /|*/|*//*|*/./*|*/.|*/../*|*/..) return 1 ;;
  esac
  v6_physical_dir=$(CDPATH= cd -- "$v6_canonical_dir" 2>/dev/null && pwd -P) || return 1
  [ "$v6_physical_dir" = "$v6_canonical_dir" ] || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    # Test-only seam: temporary test roots normally live below a sticky shared
    # directory. Production always validates the complete root-owned chain.
    v6_validate_secure_directory "$v6_canonical_dir"
    return
  fi
  v6_chain_dir=$v6_canonical_dir
  while :; do
    v6_validate_secure_directory "$v6_chain_dir" || return 1
    [ "$v6_chain_dir" != / ] || break
    v6_chain_parent=${v6_chain_dir%/*}
    [ -n "$v6_chain_parent" ] || v6_chain_parent=/
    v6_chain_dir=$v6_chain_parent
  done
}

v6_has_control_character() {
  [ "$#" -eq 1 ] || return 1
  case $1 in
    *'
'*) return 0 ;;
  esac
  LC_ALL=C "$V6_CONTROL_GREP_CMD" '[[:cntrl:]]' >/dev/null 2>&1 <<EOF
$1
EOF
}

v6_has_no_control_character() {
  [ "$#" -eq 1 ] || return 1
  unset v6_control_status
  if v6_has_control_character "$1"; then
    return 1
  else
    v6_control_status=$?
  fi
  [ "$v6_control_status" -eq 1 ] && return 0
  return "$v6_control_status"
}

v6_cleanup_update_parse() {
  v6_update_cleanup_dir=$1
  unset v6_update_line v6_update_key v6_update_value v6_update_seen_file
  v6_cleanup_seen_dir "$v6_update_cleanup_dir"
  unset v6_update_cleanup_dir
}

v6_load_main_config() {
  [ "$#" -eq 2 ] || return 1
  v6_main_file=$1
  v6_networks_file=$2
  unset V6_WAN_IF V6_TUN_IF V6_STATIC_V4 V6_BR_V6 V6_IID V6_TUN_MTU V6_TCP_MSS
  unset V6_ROUTE_TABLE V6_RULE_PREF_BASE V6_WATCH_INTERVAL_SECONDS
  unset V6_UPDATE_INTERVAL_SECONDS V6_OUTER_IPIP_ALLOW V6_NETWORKS_CONFIG
  v6_main_parent=${v6_main_file%/*}
  v6_networks_parent=${v6_networks_file%/*}
  [ "$v6_main_parent" != "$v6_main_file" ] || return 1
  [ "$v6_networks_parent" = "$v6_main_parent" ] || return 1
  v6_validate_canonical_secure_directory "$v6_main_parent" || return 1
  v6_validate_private_file "$v6_main_file" 600 || return 1
  v6_validate_private_file "$v6_networks_file" 600 || return 1
  v6_make_seen_dir || return 1
  v6_seen_file=$v6_seen_dir/keys
  : >"$v6_seen_file" || {
    v6_cleanup_seen_dir "$v6_seen_dir"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|\#*) continue ;;
      *=*) ;;
      *) v6_cleanup_seen_dir "$v6_seen_dir"; return 1 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case $key in
      WAN_IF|TUN_IF|STATIC_V4|BR_V6|IID|TUN_MTU|TCP_MSS|ROUTE_TABLE|RULE_PREF_BASE|WATCH_INTERVAL_SECONDS|UPDATE_INTERVAL_SECONDS|OUTER_IPIP_ALLOW) ;;
      *) v6_cleanup_seen_dir "$v6_seen_dir"; return 1 ;;
    esac
    if v6_seen_key "$v6_seen_file" "$key"; then
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    else
      v6_seen_status=$?
      if [ "$v6_seen_status" -ne 1 ]; then
        v6_cleanup_seen_dir "$v6_seen_dir"
        return 1
      fi
    fi
    printf '%s\n' "$key" >>"$v6_seen_file" || {
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    }
    case $key in
      WAN_IF) V6_WAN_IF=$value ;;
      TUN_IF) V6_TUN_IF=$value ;;
      STATIC_V4) V6_STATIC_V4=$value ;;
      BR_V6) V6_BR_V6=$value ;;
      IID) V6_IID=$value ;;
      TUN_MTU) V6_TUN_MTU=$value ;;
      TCP_MSS) V6_TCP_MSS=$value ;;
      ROUTE_TABLE) V6_ROUTE_TABLE=$value ;;
      RULE_PREF_BASE) V6_RULE_PREF_BASE=$value ;;
      WATCH_INTERVAL_SECONDS) V6_WATCH_INTERVAL_SECONDS=$value ;;
      UPDATE_INTERVAL_SECONDS) V6_UPDATE_INTERVAL_SECONDS=$value ;;
      OUTER_IPIP_ALLOW) V6_OUTER_IPIP_ALLOW=$value ;;
    esac
  done <"$v6_main_file" || {
    v6_cleanup_seen_dir "$v6_seen_dir"
    return 1
  }
  v6_cleanup_seen_dir "$v6_seen_dir"
  V6_NETWORKS_CONFIG=$v6_networks_file
}

v6_load_update_config() {
  [ "$#" -eq 1 ] || return 1
  unset line key value
  unset v6_update_file v6_update_parent v6_update_mode v6_update_owner
  unset v6_update_line v6_update_key v6_update_value v6_update_seen_file v6_update_cleanup_dir
  unset V6_UPDATE_URL V6_UPDATE_USERNAME V6_UPDATE_PASSWORD
  unset V6_ALLOW_INSECURE_UPDATE_HTTP V6_INSECURE_UPDATE_HTTP_HOST V6_UPDATE_PROTO
  v6_update_file=$1
  v6_update_parent=${v6_update_file%/*}
  [ "$v6_update_parent" != "$v6_update_file" ] || v6_update_parent=.
  v6_validate_canonical_secure_directory "$v6_update_parent" || return 1
  [ -f "$v6_update_file" ] && [ ! -L "$v6_update_file" ] || return 1
  v6_update_mode=$(stat -c %a "$v6_update_file" 2>/dev/null) || return 1
  v6_update_owner=$(stat -c %u "$v6_update_file" 2>/dev/null) || return 1
  case $v6_update_mode in [0-7]00) ;; *) return 1 ;; esac
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$v6_update_owner" = "$(id -u)" ] || return 1
  else
    [ "$v6_update_owner" = 0 ] || return 1
  fi
  v6_make_seen_dir || return 1
  v6_update_seen_file=$v6_seen_dir/keys
  : >"$v6_update_seen_file" || {
    v6_cleanup_seen_dir "$v6_seen_dir"
    return 1
  }
  while IFS= read -r v6_update_line || [ -n "$v6_update_line" ]; do
    case $v6_update_line in
      ''|\#*) continue ;;
      *=*) ;;
      *) v6_cleanup_update_parse "$v6_seen_dir"; return 1 ;;
    esac
    v6_update_key=${v6_update_line%%=*}
    v6_update_value=${v6_update_line#*=}
    v6_has_no_control_character "$v6_update_key" || { v6_cleanup_update_parse "$v6_seen_dir"; return 1; }
    v6_has_no_control_character "$v6_update_value" || { v6_cleanup_update_parse "$v6_seen_dir"; return 1; }
    case $v6_update_key in
      UPDATE_URL|UPDATE_USERNAME|UPDATE_PASSWORD|ALLOW_INSECURE_UPDATE_HTTP|INSECURE_UPDATE_HTTP_HOST) ;;
      *) v6_cleanup_update_parse "$v6_seen_dir"; return 1 ;;
    esac
    if v6_seen_key "$v6_update_seen_file" "$v6_update_key"; then
      v6_cleanup_update_parse "$v6_seen_dir"
      return 1
    else
      v6_update_seen_status=$?
      if [ "$v6_update_seen_status" -ne 1 ]; then
        v6_cleanup_update_parse "$v6_seen_dir"
        return 1
      fi
    fi
    printf '%s\n' "$v6_update_key" >>"$v6_update_seen_file" || {
      v6_cleanup_update_parse "$v6_seen_dir"
      return 1
    }
    case $v6_update_key in
      UPDATE_URL) V6_UPDATE_URL=$v6_update_value ;;
      UPDATE_USERNAME) V6_UPDATE_USERNAME=$v6_update_value ;;
      UPDATE_PASSWORD) V6_UPDATE_PASSWORD=$v6_update_value ;;
      ALLOW_INSECURE_UPDATE_HTTP) V6_ALLOW_INSECURE_UPDATE_HTTP=$v6_update_value ;;
      INSECURE_UPDATE_HTTP_HOST) V6_INSECURE_UPDATE_HTTP_HOST=$v6_update_value ;;
    esac
  done <"$v6_update_file" || {
    v6_cleanup_update_parse "$v6_seen_dir"
    return 1
  }
  v6_cleanup_update_parse "$v6_seen_dir"
  [ "${V6_UPDATE_URL+x}" = x ] && [ "${V6_UPDATE_USERNAME+x}" = x ] &&
    [ "${V6_UPDATE_PASSWORD+x}" = x ] && [ "${V6_ALLOW_INSECURE_UPDATE_HTTP+x}" = x ] &&
    [ "${V6_INSECURE_UPDATE_HTTP_HOST+x}" = x ] || return 1
  [ -n "$V6_UPDATE_URL" ] && [ -n "$V6_UPDATE_USERNAME" ] && [ -n "$V6_UPDATE_PASSWORD" ] || return 1
  case $V6_ALLOW_INSECURE_UPDATE_HTTP in yes|no) ;; *) return 1 ;; esac
  case $V6_UPDATE_URL in
    https://*)
      [ "$V6_ALLOW_INSECURE_UPDATE_HTTP" = no ] || return 1
      [ -z "$V6_INSECURE_UPDATE_HTTP_HOST" ] || return 1
      V6_UPDATE_PROTO=https
      ;;
    http://*)
      [ "$V6_ALLOW_INSECURE_UPDATE_HTTP" = yes ] || return 1
      case $V6_INSECURE_UPDATE_HTTP_HOST in
        ''|.*|*..*|*[!A-Za-z0-9.-]*|-*|*-) return 1 ;;
      esac
      v6_update_authority=${V6_UPDATE_URL#http://}
      v6_update_authority=${v6_update_authority%%/*}
      [ "$v6_update_authority" = "$V6_INSECURE_UPDATE_HTTP_HOST" ] || return 1
      V6_UPDATE_PROTO=http
      ;;
    *) return 1 ;;
  esac
  case $V6_UPDATE_URL in *'@'*) return 1 ;; esac
}

v6_curl_config_escape() {
  [ "$#" -eq 1 ] || return 1
  v6_has_no_control_character "$1" || return $?
  unset v6_curl_escaped
  v6_curl_escaped=$("$V6_CURL_SED_CMD" -e 's/\\/\\\\/g' -e 's/"/\\"/g' <<EOF
$1
EOF
  ) || return $?
  printf '%s' "$v6_curl_escaped"
}

v6_is_uint() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

v6_is_canonical_uint10() {
  [ "$#" -eq 1 ] || return 1
  v6_is_uint "$1" || return 1
  case $1 in 0) ;; 0*) return 1 ;; esac
  [ "${#1}" -le 10 ]
}

v6_load_update_state() {
  [ "$#" -eq 1 ] || return 1
  unset line key value
  unset v6_state_line v6_state_key v6_state_value v6_state_expanded
  unset v6_state_local_seen v6_state_time_seen v6_state_http_seen
  unset V6_LAST_UPDATE_LOCAL_V6 V6_LAST_UPDATE_SUCCEEDED_AT V6_LAST_UPDATE_HTTP_CODE
  v6_validate_private_file "$1" 600 || return 1
  v6_state_local_seen=0
  v6_state_time_seen=0
  v6_state_http_seen=0
  while IFS= read -r v6_state_line || [ -n "$v6_state_line" ]; do
    case $v6_state_line in *=*) ;; *) return 1 ;; esac
    v6_state_key=${v6_state_line%%=*}
    v6_state_value=${v6_state_line#*=}
    v6_has_no_control_character "$v6_state_key" || return 1
    v6_has_no_control_character "$v6_state_value" || return 1
    case $v6_state_key in
      LOCAL_V6)
        [ "$v6_state_local_seen" -eq 0 ] || return 1
        V6_LAST_UPDATE_LOCAL_V6=$v6_state_value
        v6_state_local_seen=1
        ;;
      SUCCEEDED_AT)
        [ "$v6_state_time_seen" -eq 0 ] || return 1
        V6_LAST_UPDATE_SUCCEEDED_AT=$v6_state_value
        v6_state_time_seen=1
        ;;
      HTTP_CODE)
        [ "$v6_state_http_seen" -eq 0 ] || return 1
        V6_LAST_UPDATE_HTTP_CODE=$v6_state_value
        v6_state_http_seen=1
        ;;
      *) return 1 ;;
    esac
  done <"$1" || return 1
  [ "$v6_state_local_seen" -eq 1 ] && [ "$v6_state_time_seen" -eq 1 ] && [ "$v6_state_http_seen" -eq 1 ] || return 1
  v6_state_expanded=$(v6_expand_ipv6 "$V6_LAST_UPDATE_LOCAL_V6") || return 1
  [ "$v6_state_expanded" = "$V6_LAST_UPDATE_LOCAL_V6" ] || return 1
  v6_is_canonical_uint10 "$V6_LAST_UPDATE_SUCCEEDED_AT" || return 1
  [ "$V6_LAST_UPDATE_HTTP_CODE" = 200 ]
}

v6_is_iface_value() {
  case ${1:-} in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

v6_is_ip_value() {
  case ${1:-} in ''|*[!0-9A-Fa-f:./]*) return 1 ;; *) return 0 ;; esac
}

v6_is_chain_value() {
  case ${1:-} in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac
}

v6_is_ipv4() {
  printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||$i>255)exit 1}'
}

v6_is_cidr() {
  addr=${1%/*}
  bits=${1#*/}
  [ "$addr" != "$1" ] && v6_is_ipv4 "$addr" && v6_is_uint "$bits" && [ "$bits" -ge 0 ] && [ "$bits" -le 32 ]
}

v6_is_ipv6() {
  case $1 in
    *:*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$1" | awk '
    /^[0-9A-Fa-f:]+$/ {
      if ($0 ~ /^:/ && substr($0, 1, 2) != "::") exit 1
      if ($0 ~ /:$/ && (length($0) < 2 || substr($0, length($0) - 1, 2) != "::")) exit 1
      compressed = index($0, "::") != 0
      if ($0 ~ /:::/ || $0 ~ /::.*::/) exit 1
      n=split($0, parts, ":")
      fields=0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "") continue
        if (length(parts[i]) > 4) exit 1
        fields++
      }
      if (compressed && fields < 8) exit 0
      if (!compressed && fields == 8) exit 0
      exit 1
    }
    { exit 1 }
  '
}

v6_clear_ipv6_helper_scratch() {
  unset output iid source_full iid_full source_prefix iid_suffix
  unset v6_route_output v6_route_source
  unset v6_compose_iid v6_compose_source_full v6_compose_iid_full
  unset v6_compose_source_prefix v6_compose_iid_suffix v6_compose_print_status
  unset address marker left right left_count right_count left_parts right_parts
  unset zeros total hextets hextet
}

v6_expand_ipv6() {
  [ "$#" -eq 1 ] || return 1
  v6_clear_ipv6_helper_scratch
  case $1 in
    *'
'*) return 1 ;;
  esac
  printf '%s\n' "$1" | awk '
    {
      address = $0
      sub(/%.*/, "", address)
      sub(/\/.*/, "", address)
      if (address == "" || address ~ /:::/) exit 1

      marker = index(address, "::")
      if (marker) {
        left = substr(address, 1, marker - 1)
        right = substr(address, marker + 2)
        if (index(right, "::")) exit 1
        left_count = 0
        right_count = 0
        if (left != "") {
          left_count = split(left, left_parts, ":")
          for (i = 1; i <= left_count; i++) {
            if (left_parts[i] == "") exit 1
          }
        }
        if (right != "") {
          right_count = split(right, right_parts, ":")
          for (i = 1; i <= right_count; i++) {
            if (right_parts[i] == "") exit 1
          }
        }
        zeros = 8 - left_count - right_count
        if (zeros < 1) exit 1
        total = 0
        for (i = 1; i <= left_count; i++) hextets[++total] = left_parts[i]
        for (i = 1; i <= zeros; i++) hextets[++total] = "0"
        for (i = 1; i <= right_count; i++) hextets[++total] = right_parts[i]
      } else {
        total = split(address, hextets, ":")
        if (total != 8) exit 1
        for (i = 1; i <= total; i++) {
          if (hextets[i] == "") exit 1
        }
      }

      output = ""
      for (i = 1; i <= 8; i++) {
        hextet = hextets[i]
        if (hextet !~ /^[0-9A-Fa-f]+$/ || length(hextet) > 4) exit 1
        hextet = tolower(hextet)
        hextet = substr("0000" hextet, length(hextet) + 1)
        output = output (i == 1 ? "" : ":") hextet
      }
      print output
    }
  '
}

v6_route_source_v6() {
  [ "$#" -eq 1 ] || return 1
  v6_clear_ipv6_helper_scratch
  v6_route_output=$("$V6_IP_CMD" -6 route get "$1") || return 1
  set -- $v6_route_output
  while [ "$#" -gt 1 ]; do
    if [ "$1" = src ]; then
      v6_route_source=${2%%%*}
      unset v6_route_output
      printf '%s\n' "$v6_route_source"
      unset v6_route_source
      return 0
    fi
    shift
  done
  unset v6_route_output
  v6_die "BR route has no selected IPv6 source"
}

v6_compose_local_v6() {
  [ "$#" -eq 2 ] || return 1
  v6_clear_ipv6_helper_scratch
  v6_compose_iid=${2#::}
  [ "$(printf '%s\n' "$v6_compose_iid" | awk -F: '{ print NF }')" -eq 4 ] || {
    v6_die "IID must contain exactly four hextets"
    v6_clear_ipv6_helper_scratch
    return 1
  }
  v6_compose_source_full=$(v6_expand_ipv6 "${1%%%*}") || { v6_clear_ipv6_helper_scratch; return 1; }
  v6_compose_iid_full=$(v6_expand_ipv6 "::$v6_compose_iid") || { v6_clear_ipv6_helper_scratch; return 1; }
  v6_compose_source_prefix=$(printf '%s\n' "$v6_compose_source_full" | cut -d: -f1-4)
  v6_compose_iid_suffix=$(printf '%s\n' "$v6_compose_iid_full" | cut -d: -f5-8)
  printf '%s:%s\n' "$v6_compose_source_prefix" "$v6_compose_iid_suffix"
  v6_compose_print_status=$?
  set -- "$v6_compose_print_status"
  v6_clear_ipv6_helper_scratch
  unset v6_compose_print_status
  return "$1"
}

v6_iter_networks() {
  [ "$#" -eq 1 ] || return 1
  v6_network_file=$1
  v6_make_seen_dir || return 1
  v6_seen_file=$v6_seen_dir/networks
  : >"$v6_seen_file" || {
    v6_cleanup_seen_dir "$v6_seen_dir"
    return 1
  }
  v6_parsed_file=$v6_seen_dir/parsed
  awk '
    { sub(/[[:space:]]*#.*/, "") }
    NF == 0 { next }
    NF != 2 { exit 1 }
    { print $1, $2 }
  ' "$v6_network_file" >"$v6_parsed_file" || {
    v6_cleanup_seen_dir "$v6_seen_dir"
    return 1
  }
  while IFS=' ' read -r iface cidr extra || [ -n "${iface:-}" ]; do
    [ -n "$iface" ] && [ -n "$cidr" ] && [ -z "${extra:-}" ] || {
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    }
    v6_is_iface_value "$iface" && v6_is_cidr "$cidr" && "$V6_IP_CMD" link show dev "$iface" >/dev/null 2>&1 || {
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    }
    if v6_seen_key "$v6_seen_file" "IFACE|$iface"; then
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    else
      v6_seen_status=$?
      if [ "$v6_seen_status" -ne 1 ]; then
        v6_cleanup_seen_dir "$v6_seen_dir"
        return 1
      fi
    fi
    if v6_seen_key "$v6_seen_file" "CIDR|$cidr"; then
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    else
      v6_seen_status=$?
      if [ "$v6_seen_status" -ne 1 ]; then
        v6_cleanup_seen_dir "$v6_seen_dir"
        return 1
      fi
    fi
    printf 'IFACE|%s\nCIDR|%s\n' "$iface" "$cidr" >>"$v6_seen_file" || {
      v6_cleanup_seen_dir "$v6_seen_dir"
      return 1
    }
    printf '%s|%s\n' "$iface" "$cidr"
  done <"$v6_parsed_file" || {
    v6_cleanup_seen_dir "$v6_seen_dir"
    return 1
  }
  v6_cleanup_seen_dir "$v6_seen_dir"
}

v6_require_main_config() {
  [ "${V6_WAN_IF+x}" = x ] && [ "${V6_TUN_IF+x}" = x ] && [ "${V6_STATIC_V4+x}" = x ] && [ "${V6_BR_V6+x}" = x ] && [ "${V6_IID+x}" = x ] && [ "${V6_TUN_MTU+x}" = x ] && [ "${V6_TCP_MSS+x}" = x ] && [ "${V6_ROUTE_TABLE+x}" = x ] && [ "${V6_RULE_PREF_BASE+x}" = x ] && [ "${V6_WATCH_INTERVAL_SECONDS+x}" = x ] && [ "${V6_UPDATE_INTERVAL_SECONDS+x}" = x ] && [ "${V6_OUTER_IPIP_ALLOW+x}" = x ] && [ "${V6_NETWORKS_CONFIG+x}" = x ]
}

v6_validate_main_config() {
  v6_require_main_config || return 1
  v6_is_iface_value "$V6_WAN_IF" && v6_is_iface_value "$V6_TUN_IF" && [ -n "$V6_IID" ] || return 1
  v6_is_ipv4 "$V6_STATIC_V4" || return 1
  v6_is_ipv6 "$V6_BR_V6" || return 1
  case $V6_IID in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;;
    *) return 1 ;;
  esac
  v6_is_uint "$V6_TUN_MTU" && [ "$V6_TUN_MTU" -ge 1280 ] && [ "$V6_TUN_MTU" -le 1500 ] || return 1
  v6_is_uint "$V6_TCP_MSS" && [ "$V6_TCP_MSS" -ge 536 ] && [ "$V6_TCP_MSS" -le 1460 ] || return 1
  v6_is_uint "$V6_ROUTE_TABLE" && [ "$V6_ROUTE_TABLE" -ge 1 ] && [ "$V6_ROUTE_TABLE" -le 4294967295 ] || return 1
  v6_is_uint "$V6_RULE_PREF_BASE" && [ "$V6_RULE_PREF_BASE" -ge 1 ] && [ "$V6_RULE_PREF_BASE" -le 32700 ] || return 1
  v6_is_uint "$V6_WATCH_INTERVAL_SECONDS" && [ "$V6_WATCH_INTERVAL_SECONDS" -ge 1 ] || return 1
  v6_is_uint "$V6_UPDATE_INTERVAL_SECONDS" || return 1
  [ "${#V6_UPDATE_INTERVAL_SECONDS}" -le 10 ] || return 1
  case $V6_OUTER_IPIP_ALLOW in auto|yes|no) ;; *) return 1 ;; esac
  if [ "${V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES:-0}" != 1 ]; then
    case $V6_STATIC_V4 in 192.0.2.*|198.51.100.*|203.0.113.*) return 1 ;; esac
    case $V6_BR_V6 in
      2001:[Dd][Bb]8:*|2001:0[Dd][Bb]8:*|2001:00[Dd][Bb]8:*|2001:000[Dd][Bb]8:*) return 1 ;;
    esac
  fi
  v6_iter_networks "$V6_NETWORKS_CONFIG" >/dev/null
}

v6_detect_nat_chain() {
  if v6_xtables_call "$V6_IPTABLES_CMD" -t nat -S UBIOS_POSTROUTING_USER_HOOK >/dev/null 2>&1; then
    printf '%s\n' UBIOS_POSTROUTING_USER_HOOK
  else
    v6_chain_status=$?
    [ "$v6_chain_status" -eq 1 ] || return "$v6_chain_status"
    v6_xtables_call "$V6_IPTABLES_CMD" -t nat -S POSTROUTING >/dev/null 2>&1 || return 1
    printf '%s\n' POSTROUTING
  fi
}

v6_detect_v6_input_chain() {
  if v6_xtables_call "$V6_IP6TABLES_CMD" -S UBIOS_INPUT_USER_HOOK >/dev/null 2>&1; then
    printf '%s\n' UBIOS_INPUT_USER_HOOK
  else
    v6_chain_status=$?
    [ "$v6_chain_status" -eq 1 ] || return "$v6_chain_status"
    v6_xtables_call "$V6_IP6TABLES_CMD" -S INPUT >/dev/null 2>&1 || return 1
    printf '%s\n' INPUT
  fi
}

v6_has_managed_comment() {
  v6_comment_previous=
  v6_comment_module=0
  v6_comment_value=0
  for v6_comment_arg in "$@"; do
    if [ "$v6_comment_previous" = -m ] && [ "$v6_comment_arg" = comment ]; then
      v6_comment_module=1
    fi
    if [ "$v6_comment_previous" = --comment ] && [ "$v6_comment_arg" = v6plus-static-ip ]; then
      v6_comment_value=1
    fi
    v6_comment_previous=$v6_comment_arg
  done
  [ "$v6_comment_module" -eq 1 ] && [ "$v6_comment_value" -eq 1 ]
}

v6_iptables_ensure() {
  [ "$#" -ge 3 ] || return 1
  v6_iptables_table=$1
  v6_iptables_chain=$2
  shift 2
  v6_is_chain_value "$v6_iptables_chain" && v6_has_managed_comment "$@" || return 1
  if v6_xtables_call "$V6_IPTABLES_CMD" -t "$v6_iptables_table" -C "$v6_iptables_chain" "$@" >/dev/null 2>&1; then
    return 0
  else
    v6_membership_status=$?
  fi
  [ "$v6_membership_status" -eq 1 ] || return "$v6_membership_status"
  v6_run_xtables "$V6_IPTABLES_CMD" -t "$v6_iptables_table" -A "$v6_iptables_chain" "$@"
}

v6_iptables_delete() {
  [ "$#" -ge 3 ] || return 1
  v6_iptables_table=$1
  v6_iptables_chain=$2
  shift 2
  v6_is_chain_value "$v6_iptables_chain" && v6_has_managed_comment "$@" || return 1
  if [ "$DRY_RUN" = 1 ]; then
    if v6_xtables_call "$V6_IPTABLES_CMD" -t "$v6_iptables_table" -C "$v6_iptables_chain" "$@" >/dev/null 2>&1; then
      :
    else
      v6_membership_status=$?
      [ "$v6_membership_status" -eq 1 ] && return 0
      return "$v6_membership_status"
    fi
    v6_run_xtables "$V6_IPTABLES_CMD" -t "$v6_iptables_table" -D "$v6_iptables_chain" "$@"
    return $?
  fi
  while :; do
    if v6_xtables_call "$V6_IPTABLES_CMD" -t "$v6_iptables_table" -C "$v6_iptables_chain" "$@" >/dev/null 2>&1; then
      v6_xtables_call "$V6_IPTABLES_CMD" -t "$v6_iptables_table" -D "$v6_iptables_chain" "$@" || return 1
      continue
    else
      v6_membership_status=$?
    fi
    [ "$v6_membership_status" -eq 1 ] && return 0
    return "$v6_membership_status"
  done
}

v6_ip6tables_ensure() {
  [ "$#" -ge 2 ] || return 1
  v6_ip6tables_chain=$1
  shift
  v6_is_chain_value "$v6_ip6tables_chain" && v6_has_managed_comment "$@" || return 1
  if v6_xtables_call "$V6_IP6TABLES_CMD" -C "$v6_ip6tables_chain" "$@" >/dev/null 2>&1; then
    return 0
  else
    v6_membership_status=$?
  fi
  [ "$v6_membership_status" -eq 1 ] || return "$v6_membership_status"
  v6_run_xtables "$V6_IP6TABLES_CMD" -A "$v6_ip6tables_chain" "$@"
}

v6_ip6tables_delete() {
  [ "$#" -ge 2 ] || return 1
  v6_ip6tables_chain=$1
  shift
  v6_is_chain_value "$v6_ip6tables_chain" && v6_has_managed_comment "$@" || return 1
  if [ "$DRY_RUN" = 1 ]; then
    if v6_xtables_call "$V6_IP6TABLES_CMD" -C "$v6_ip6tables_chain" "$@" >/dev/null 2>&1; then
      :
    else
      v6_membership_status=$?
      [ "$v6_membership_status" -eq 1 ] && return 0
      return "$v6_membership_status"
    fi
    v6_run_xtables "$V6_IP6TABLES_CMD" -D "$v6_ip6tables_chain" "$@"
    return $?
  fi
  while :; do
    if v6_xtables_call "$V6_IP6TABLES_CMD" -C "$v6_ip6tables_chain" "$@" >/dev/null 2>&1; then
      v6_xtables_call "$V6_IP6TABLES_CMD" -D "$v6_ip6tables_chain" "$@" || return 1
      continue
    else
      v6_membership_status=$?
    fi
    [ "$v6_membership_status" -eq 1 ] && return 0
    return "$v6_membership_status"
  done
}

v6_validate_state_dir() {
  [ -d "$V6PLUS_STATE_DIR" ] && [ ! -L "$V6PLUS_STATE_DIR" ] || return 1
  v6_state_owner=$(stat -c %u "$V6PLUS_STATE_DIR" 2>/dev/null) || return 1
  v6_state_mode=$(stat -c %a "$V6PLUS_STATE_DIR" 2>/dev/null) || return 1
  [ "$v6_state_mode" = 700 ] || return 1
  if [ "${V6PLUS_ALLOW_NONROOT:-0}" = 1 ]; then
    [ "$v6_state_owner" = "$(id -u)" ]
  else
    [ "$v6_state_owner" = 0 ]
  fi
}

v6_write_atomic() {
  [ "$#" -eq 2 ] || return 1
  v6_atomic_mode=$1
  v6_atomic_destination=$2
  v6_is_uint "$v6_atomic_mode" || return 1
  case $v6_atomic_destination in
    "$V6PLUS_STATE_DIR"/*)
      v6_atomic_leaf=${v6_atomic_destination#"$V6PLUS_STATE_DIR"/}
      case $v6_atomic_leaf in ''|.|..|*/*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  v6_validate_state_dir || return 1
  v6_atomic_tmp_dir=$v6_atomic_destination.tmp.$$
  v6_atomic_tmp=$v6_atomic_tmp_dir/value
  (
    trap 'rm -f -- "$v6_atomic_tmp" 2>/dev/null || :; rmdir "$v6_atomic_tmp_dir" 2>/dev/null || :' EXIT
    trap 'exit 1' HUP INT TERM
    umask 077
    mkdir "$v6_atomic_tmp_dir" 2>/dev/null || exit 1
    chmod 700 "$v6_atomic_tmp_dir" || exit 1
    cat >"$v6_atomic_tmp" || exit 1
    chmod "$v6_atomic_mode" "$v6_atomic_tmp" || exit 1
    mv -f -- "$v6_atomic_tmp" "$v6_atomic_destination"
  )
}
