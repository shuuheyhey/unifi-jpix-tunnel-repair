#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

UPDATE_SCRIPT=$ROOT/scripts/unifi-jpix-tunnel-repair-update.sh
test_start 'update notification executable exists'
if [ -x "$UPDATE_SCRIPT" ]; then
  pass
else
  fail "missing executable $UPDATE_SCRIPT"
  test_finish
fi
. "$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh"

TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/unifi-jpix-tunnel-repair-update-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

UPDATE_PATH=$ROOT/tests/stubs/update:/opt/homebrew/bin:/usr/bin:/bin
LOCAL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000
REDACTED_V6=2001:0DB8:1234:0030::/64
TEST_USERNAME='user+name@example.invalid'
TEST_PASSWORD='p&a ss%word'

export V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_ALLOW_NONROOT=1
export V6PLUS_LIB=$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh
export V6PLUS_ROOT=$ROOT
export V6PLUS_NOW=1700000000
export V6_IP_CMD=ip

write_main_config() {
  update_interval=$1
  cat >"$CONFIG/gateway.conf" <<EOF
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
UPDATE_INTERVAL_SECONDS=$update_interval
OUTER_IPIP_ALLOW=auto
EOF
  printf '%s\n' 'br0 192.168.20.0/24' >"$CONFIG/routed-networks.conf"
}

write_update_config() {
  cat >"$CONFIG/provider-update.conf" <<EOF
UPDATE_URL=https://update.example.invalid/update?service=fixed
UPDATE_USERNAME=$TEST_USERNAME
UPDATE_PASSWORD=$TEST_PASSWORD
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
EOF
  chmod 600 "$CONFIG/provider-update.conf"
}

new_case() {
  CASE=$TMP/$1
  CONFIG=$CASE/config
  STATE=$CASE/state
  CURL_ARGV_LOG=$CASE/curl.argv
  CURL_STDIN_LOG=$CASE/curl.stdin
  CURL_RESPONSES=$CASE/curl.responses
  CURL_COUNT_FILE=$CASE/curl.count
  IP_ARGV_LOG=$CASE/ip.argv
  SLEEP_ARGV_LOG=$CASE/sleep.argv
  CURL_TEMP_MODE_LOG=$CASE/curl.temp-modes
  CURL_DECODED_LOG=$CASE/curl.decoded
  CHILD_ENV_LOG=$CASE/child.env
  V6PLUS_STATE_DIR=$STATE
  V6PLUS_LOCK_DIR=$CASE/shared.lock
  UPDATE_PROCESS_LOG=$CASE/process.log
  export CASE CONFIG STATE CURL_ARGV_LOG CURL_STDIN_LOG CURL_RESPONSES CURL_COUNT_FILE
  V6_CONTROL_GREP_CMD=$ROOT/tests/stubs/update/control-grep
  V6_CURL_SED_CMD=$ROOT/tests/stubs/update/curl-sed
  V6_SEEN_GREP_CMD=$ROOT/tests/stubs/update/seen-grep
  export IP_ARGV_LOG SLEEP_ARGV_LOG CURL_TEMP_MODE_LOG CURL_DECODED_LOG CHILD_ENV_LOG
  export V6PLUS_STATE_DIR V6PLUS_LOCK_DIR UPDATE_PROCESS_LOG V6_CONTROL_GREP_CMD V6_CURL_SED_CMD V6_SEEN_GREP_CMD
  unset IP_ADDR_MODE V6PLUS_TEST_SIGNAL_DURING_LOCK
  unset V6PLUS_TEST_SIGNAL_AFTER_TEMP V6PLUS_TEST_TEMP_LOG
  unset CURL_PREPOSITION_ATOMIC_TMP
  unset STUB_CONTROL_GREP_FAIL STUB_CURL_SED_FAIL STUB_STAT_FOREIGN_CONFIG_DIR STUB_STAT_FOREIGN_STATE
  unset STUB_SEEN_GREP_FAIL_AT STUB_DATE_VALUE
  unset line key value v6_update_line v6_update_key v6_update_value
  unset V6_CURL_ESCAPED_USERNAME V6_CURL_ESCAPED_PASSWORD
  unset source_full iid_full iid output source_prefix iid_suffix
  unset v6_route_output v6_compose_iid v6_compose_source_full v6_compose_iid_full
  unset v6_compose_source_prefix v6_compose_iid_suffix
  V6PLUS_NOW=1700000000
  export V6PLUS_NOW
  mkdir -p "$CONFIG" "$STATE" "$CASE/bodies"
  chmod 700 "$CONFIG" "$STATE"
  : >"$CURL_ARGV_LOG"
  : >"$CURL_STDIN_LOG"
  : >"$CURL_RESPONSES"
  : >"$IP_ARGV_LOG"
  : >"$SLEEP_ARGV_LOG"
  : >"$CURL_TEMP_MODE_LOG"
  : >"$CURL_DECODED_LOG"
  : >"$CHILD_ENV_LOG"
  : >"$UPDATE_PROCESS_LOG"
  write_main_config 600
  write_update_config
}

queue_response() {
  response_transport=$1
  response_http=$2
  response_body=$3
  response_number=$(wc -l <"$CURL_RESPONSES" | tr -d ' ')
  response_path=$CASE/bodies/body.$response_number
  printf '%s' "$response_body" >"$response_path"
  printf '%s|%s|%s\n' "$response_transport" "$response_http" "$response_path" >>"$CURL_RESPONSES"
}

run_update_with_config() {
  run_config=$1
  shift
  RUN_OUTPUT=$CASE/stdout
  RUN_ERROR=$CASE/stderr
  : >"$RUN_OUTPUT"
  : >"$RUN_ERROR"
  set +e
  PATH=$UPDATE_PATH "$UPDATE_SCRIPT" --config "$run_config" "$@" >"$RUN_OUTPUT" 2>"$RUN_ERROR"
  RUN_STATUS=$?
  set -e
  cat "$RUN_ERROR" >>"$UPDATE_PROCESS_LOG"
}

run_update() { run_update_with_config "$CONFIG" "$@"; }

curl_count() { if [ -f "$CURL_COUNT_FILE" ]; then cat "$CURL_COUNT_FILE"; else printf 0; fi; }

assert_run_success() {
  test_start "$1"
  if [ "$RUN_STATUS" -eq 0 ]; then pass; else fail "exit $RUN_STATUS: stdout=$(cat "$RUN_OUTPUT") stderr=$(cat "$RUN_ERROR")"; fi
}

assert_run_status() {
  test_start "$1"
  assert_eq "$RUN_STATUS" "$2"
}

assert_file_absent() {
  test_start "$1"
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then pass; else fail "unexpected path $2"; fi
}

assert_secret_absent() {
  secret_label=$1
  secret_path=$2
  test_start "$secret_label hides username"
  if grep -F "$TEST_USERNAME" "$secret_path" >/dev/null 2>&1; then fail 'username leaked'; else pass; fi
  test_start "$secret_label hides password"
  if grep -F "$TEST_PASSWORD" "$secret_path" >/dev/null 2>&1; then fail 'password leaked'; else pass; fi
}

nul_args() { tr '\000' '\n' <"$1"; }

assert_runtime_state_empty() {
  test_start "$1"
  if [ -z "$(find "$STATE" -mindepth 1 -print)" ]; then pass; else fail 'runtime state changed'; fi
}

assert_no_shell_diagnostic() {
  test_start "$1"
  if grep -E 'Illegal number|integer expression|bad number|arithmetic expression' "$RUN_ERROR" >/dev/null 2>&1; then
    fail "raw shell diagnostic: $(cat "$RUN_ERROR")"
  else
    pass
  fi
}

# A successful forced request accepts realistic compressed kernel output, binds the exact
# expanded endpoint, and keeps secrets off argv and outputs.
new_case forced-success
queue_response 0 200 ' arbitrary provider success '
run_update --force
assert_run_success 'forced notification succeeds'
test_start 'forced notification performs exactly one request'
assert_eq "$(curl_count)" 1
forced_args=$(nul_args "$CURL_ARGV_LOG")
test_start 'curl binds the exact expanded local endpoint'
assert_contains "$forced_args" "--interface
$LOCAL_V6"
test_start 'curl uses IPv6 with finite connection and total timeouts'
assert_contains "$forced_args" "--ipv6
--interface
$LOCAL_V6
--silent
--show-error
--connect-timeout
10
--max-time
30"
test_start 'curl reads its request configuration only from stdin'
assert_contains "$forced_args" "--config
-"
test_start 'curl receives no provider URL on argv'
case $forced_args in *update.example.invalid*) fail 'provider URL leaked to argv' ;; *) pass ;; esac
test_start 'curl stdin preserves the provider HTTPS scheme and GET option'
assert_contains "$(cat "$CURL_STDIN_LOG.1")" "url = \"https://update.example.invalid/update?service=fixed\"
get"
test_start 'curl pins HTTPS for the request and redirects'
assert_contains "$forced_args" "--proto
=https
--proto-redir
=https"
test_start 'curl stdin submits the exact username field for URL encoding'
assert_contains "$(cat "$CURL_STDIN_LOG.1")" "data-urlencode = \"user=$TEST_USERNAME\""
test_start 'curl stdin submits the exact password field for URL encoding'
assert_contains "$(cat "$CURL_STDIN_LOG.1")" "data-urlencode = \"pass=$TEST_PASSWORD\""
test_start 'curl stub decodes the exact sensitive submitted fields'
assert_eq "$(cat "$CURL_DECODED_LOG")" "user=$TEST_USERNAME
pass=$TEST_PASSWORD"
test_start 'curl stub validates exactly one GET and two data-urlencode fields'
assert_eq "$(wc -l <"$CURL_DECODED_LOG" | tr -d ' ')" 2
test_start 'successful state is exact'
assert_eq "$(cat "$STATE/last-provider-update.state")" "LOCAL_V6=$LOCAL_V6
SUCCEEDED_AT=1700000000
HTTP_CODE=200"
test_start 'successful state mode is private'
assert_eq "$(stat -c %a "$STATE/last-provider-update.state")" 600
test_start 'curl observes a private response directory and body file'
assert_eq "$(cat "$CURL_TEMP_MODE_LOG")" '700|600'
assert_secret_absent 'curl argv' "$CURL_ARGV_LOG"
assert_secret_absent 'stdout' "$RUN_OUTPUT"
assert_secret_absent 'stderr' "$RUN_ERROR"
assert_secret_absent 'process log' "$UPDATE_PROCESS_LOG"
assert_secret_absent 'successful state' "$STATE/last-provider-update.state"
test_start 'provider response body is never logged'
case $(cat "$RUN_OUTPUT" "$RUN_ERROR" "$UPDATE_PROCESS_LOG") in *'arbitrary provider success'*) fail 'body leaked' ;; *) pass ;; esac
test_start 'logs contain only the redacted upper /64 endpoint'
assert_contains "$(cat "$RUN_ERROR")" "endpoint=$REDACTED_V6"
test_start 'logs do not contain the complete endpoint'
case $(cat "$RUN_ERROR") in *"$LOCAL_V6"*) fail 'full endpoint leaked' ;; *) pass ;; esac

new_case explicit-legacy-http
cat >"$CONFIG/provider-update.conf" <<EOF
UPDATE_URL=http://legacy.example.invalid/update
UPDATE_USERNAME=$TEST_USERNAME
UPDATE_PASSWORD=$TEST_PASSWORD
ALLOW_INSECURE_UPDATE_HTTP=yes
INSECURE_UPDATE_HTTP_HOST=legacy.example.invalid
EOF
chmod 600 "$CONFIG/provider-update.conf"
queue_response 0 200 'OK'
run_update --force
assert_run_success 'explicit exact-host legacy HTTP opt-in remains available'
legacy_args=$(nul_args "$CURL_ARGV_LOG")
test_start 'legacy HTTP request is pinned to HTTP only'
assert_contains "$legacy_args" "--proto
=http
--proto-redir
=http"
test_start 'legacy HTTP emits a clear transport warning'
assert_contains "$(cat "$RUN_ERROR")" 'WARNING legacy HTTP update transport explicitly enabled'
assert_secret_absent 'legacy HTTP logs' "$RUN_ERROR"

test_start 'parsed credential variables are not exported to child processes'
if (
  v6_load_update_config "$CONFIG/provider-update.conf" || exit 1
  env | grep '^V6_UPDATE_\(URL\|USERNAME\|PASSWORD\)=' >/dev/null
); then fail 'credential variable was exported'; else pass; fi

test_start 'update config owner must match the narrow nonroot seam owner'
if (
  id() { printf '%s\n' 1234; }
  v6_load_update_config "$CONFIG/provider-update.conf"
); then fail 'unexpected owner was accepted'; else pass; fi

# Each failed attempt sleeps once before the next, then the third success commits state.
new_case retries
queue_response 7 000 'transport detail secret body'
queue_response 0 503 'unavailable detail'
queue_response 0 200 'OK'
run_update --force
assert_run_success 'transport then HTTP failures recover on third attempt'
test_start 'retry sequence performs exactly three requests'
assert_eq "$(curl_count)" 3
test_start 'retry sequence sleeps ten seconds exactly twice'
assert_eq "$(cat "$SLEEP_ARGV_LOG")" "10
10"
test_start 'retry log reports attempt, status, and outcome without bodies'
assert_contains "$(cat "$RUN_ERROR")" 'attempt=2 http=503 outcome=failure'
test_start 'retry log never exposes response details'
case $(cat "$RUN_ERROR") in *detail*) fail 'response detail leaked' ;; *) pass ;; esac

# Exhaustion must retain the prior success bytes exactly.
new_case exhausted
printf '%s\n' 'LOCAL_V6=2001:0db8:1234:0030:0000:0000:0000:0001' 'SUCCEEDED_AT=1699990000' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
cp "$STATE/last-provider-update.state" "$CASE/prior-state"
queue_response 7 000 'one'
queue_response 0 503 'two'
queue_response 0 200 ' FAIL: rejected '
run_update --force
assert_run_status 'three failed attempts return notification failure' 1
test_start 'failed notification preserves prior successful state byte-for-byte'
cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'prior state bytes changed'
test_start 'three failures still sleep only between attempts'
assert_eq "$(cat "$SLEEP_ARGV_LOG")" "10
10"

new_case state-write-failure
printf '%s\n' 'LOCAL_V6=2001:0db8:1234:0030:0000:0000:0000:0001' 'SUCCEEDED_AT=1699990000' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
cp "$STATE/last-provider-update.state" "$CASE/prior-state"
CURL_PREPOSITION_ATOMIC_TMP=1
export CURL_PREPOSITION_ATOMIC_TMP
queue_response 0 200 'OK'
run_update --force
assert_run_status 'checked atomic state-write failure returns notification failure' 1
test_start 'atomic state-write failure preserves prior success byte-for-byte'
cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'prior state bytes changed'

# Provider-negative tokens are case-insensitive and require a delimiter.
for negative_body in 'NG' ' ng rejected' 'ERROR: denied' ' Fail failure'; do
  new_case negative-$(printf '%s' "$negative_body" | tr -cd 'A-Za-z')
  queue_response 0 200 "$negative_body"
  queue_response 0 200 "$negative_body"
  queue_response 0 200 "$negative_body"
  run_update --force
  assert_run_status "provider-negative body <$negative_body> fails" 1
done
new_case negative-multiline-whitespace
multiline_negative=$(printf '\n \tERROR: denied after whitespace')
queue_response 0 200 "$multiline_negative"
queue_response 0 200 "$multiline_negative"
queue_response 0 200 "$multiline_negative"
run_update --force
assert_run_status 'provider-negative body after multiline whitespace fails' 1
new_case nonnegative-prefix
queue_response 0 200 'FAILURE is arbitrary success text'
run_update --force
assert_run_success 'non-delimited failure prefix is accepted'

# Interval gating depends on both endpoint identity and safe elapsed time.
new_case interval-skip
printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
run_update
assert_run_success 'unchanged endpoint inside interval skips'
test_start 'inside-interval skip performs no request'
assert_eq "$(curl_count)" 0

new_case interval-boundary
printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999400' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
queue_response 0 200 'OK'
run_update
assert_run_success 'elapsed time exactly equal to interval sends'
test_start 'interval boundary performs one request'
assert_eq "$(curl_count)" 1

new_case interval-near-decimal-limit
V6PLUS_NOW=9999999999
export V6PLUS_NOW
printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=9999999399' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
queue_response 0 200 'OK'
run_update
assert_run_success 'ten-digit timestamps send safely at the exact interval boundary'
test_start 'ten-digit interval boundary performs one request'
assert_eq "$(curl_count)" 1
test_start 'ten-digit timestamp is committed exactly'
assert_contains "$(cat "$STATE/last-provider-update.state")" 'SUCCEEDED_AT=9999999999'

new_case changed-endpoint
printf '%s\n' 'LOCAL_V6=2001:0db8:1234:0030:0000:0000:0000:0001' 'SUCCEEDED_AT=1699999999' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
queue_response 0 200 'OK'
run_update
assert_run_success 'changed endpoint sends immediately'
test_start 'changed endpoint performs one request'
assert_eq "$(curl_count)" 1

new_case interval-zero
write_main_config 0
run_update
assert_run_success 'zero interval disables non-forced update'
test_start 'zero interval performs no request'
assert_eq "$(curl_count)" 0
queue_response 0 200 'OK'
run_update --force
assert_run_success 'force overrides zero interval'
test_start 'forced zero-interval call performs a request'
assert_eq "$(curl_count)" 1

for bad_state in malformed future overflow; do
  new_case state-$bad_state
  case $bad_state in
    malformed) printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=nope' 'HTTP_CODE=200' >"$STATE/last-provider-update.state" ;;
    future) printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1700000001' 'HTTP_CODE=200' >"$STATE/last-provider-update.state" ;;
    overflow) printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=999999999999999999999999999' 'HTTP_CODE=200' >"$STATE/last-provider-update.state" ;;
  esac
  chmod 600 "$STATE/last-provider-update.state"
  run_update
  assert_run_status "$bad_state prior state fails safely" 1
  test_start "$bad_state prior state causes no request"
  assert_eq "$(curl_count)" 0
done

for noncanonical_state in leading-zero signed; do
  new_case state-$noncanonical_state-timestamp
  case $noncanonical_state in
    leading-zero) prior_timestamp=0169999500 ;;
    signed) prior_timestamp=+169999500 ;;
  esac
  printf '%s\n' "LOCAL_V6=$LOCAL_V6" "SUCCEEDED_AT=$prior_timestamp" 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
  chmod 600 "$STATE/last-provider-update.state"
  run_update
  assert_run_status "$noncanonical_state prior timestamp fails safely" 1
  test_start "$noncanonical_state prior timestamp has stable diagnostic"
  assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=previous_state'
  test_start "$noncanonical_state prior timestamp causes no request"
  assert_eq "$(curl_count)" 0
  assert_no_shell_diagnostic "$noncanonical_state prior timestamp emits no raw shell diagnostic"
done

for invalid_now in leading-zero signed overflow; do
  new_case now-$invalid_now
  case $invalid_now in
    leading-zero) V6PLUS_NOW=0170000000 ;;
    signed) V6PLUS_NOW=+1700000000 ;;
    overflow) V6PLUS_NOW=17000000000 ;;
  esac
  export V6PLUS_NOW
  run_update --force
  assert_run_status "$invalid_now current timestamp fails safely" 1
  test_start "$invalid_now current timestamp has stable diagnostic"
  assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=timestamp'
  test_start "$invalid_now current timestamp causes no request"
  assert_eq "$(curl_count)" 0
  assert_no_shell_diagnostic "$invalid_now current timestamp emits no raw shell diagnostic"
done

# Force validates only state path metadata. Private corrupt or future content is recoverable;
# notification failure preserves every original byte, including the trailing newline.
for force_state in corrupt future; do
  new_case force-$force_state-success
  case $force_state in
    corrupt) printf '%s\n' 'not-an-assignment with opaque recovery bytes' >"$STATE/last-provider-update.state" ;;
    future) printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1700000001' 'HTTP_CODE=200' >"$STATE/last-provider-update.state" ;;
  esac
  chmod 600 "$STATE/last-provider-update.state"
  queue_response 0 200 'OK'
  run_update --force
  assert_run_success "force replaces private $force_state state after verified success"
  test_start "force $force_state success writes exact state"
  assert_eq "$(cat "$STATE/last-provider-update.state")" "LOCAL_V6=$LOCAL_V6
SUCCEEDED_AT=1700000000
HTTP_CODE=200"

  new_case force-$force_state-failure
  case $force_state in
    corrupt) printf '%s\n' 'not-an-assignment with opaque recovery bytes' >"$STATE/last-provider-update.state" ;;
    future) printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1700000001' 'HTTP_CODE=200' >"$STATE/last-provider-update.state" ;;
  esac
  chmod 600 "$STATE/last-provider-update.state"
  cp "$STATE/last-provider-update.state" "$CASE/prior-state"
  queue_response 7 000 'one'
  queue_response 0 503 'two'
  queue_response 0 200 'FAIL: denied'
  run_update --force
  assert_run_status "force failure returns nonzero with private $force_state state" 1
  test_start "force failure preserves private $force_state state byte-for-byte"
  cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'prior state bytes changed'
done

for unsafe_state in mode duplicate extra missing bad-code; do
  new_case state-$unsafe_state
  case $unsafe_state in
    mode)
      printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
      chmod 640 "$STATE/last-provider-update.state"
      ;;
    duplicate)
      printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' 'HTTP_CODE=200' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
      chmod 600 "$STATE/last-provider-update.state"
      ;;
    extra)
      printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' 'HTTP_CODE=200' 'EXTRA=value' >"$STATE/last-provider-update.state"
      chmod 600 "$STATE/last-provider-update.state"
      ;;
    missing)
      printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' >"$STATE/last-provider-update.state"
      chmod 600 "$STATE/last-provider-update.state"
      ;;
    bad-code)
      printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' 'HTTP_CODE=201' >"$STATE/last-provider-update.state"
      chmod 600 "$STATE/last-provider-update.state"
      ;;
  esac
  run_update
  assert_run_status "$unsafe_state prior state schema is rejected" 1
  test_start "$unsafe_state prior state causes no request"
  assert_eq "$(curl_count)" 0
done

# Update configuration metadata and all credential-bearing values fail closed.
new_case update-mode
chmod 640 "$CONFIG/provider-update.conf"
run_update --force
assert_run_status 'group-readable update config is rejected as configuration' 2
test_start 'unsafe update-config mode is rejected before curl'
assert_eq "$(curl_count)" 0

new_case update-symlink
mv "$CONFIG/provider-update.conf" "$CONFIG/update.real"
ln -s "$CONFIG/update.real" "$CONFIG/provider-update.conf"
run_update --force
assert_run_status 'symlink update config is rejected as configuration' 2
test_start 'symlink update config is rejected before curl'
assert_eq "$(curl_count)" 0

new_case update-parent-symlink
mv "$CONFIG" "$CASE/config.real"
ln -s "$CASE/config.real" "$CONFIG"
run_update --force
assert_run_status 'symlink update-config parent is rejected as configuration' 2
test_start 'symlink update-config parent is rejected before curl'
assert_eq "$(curl_count)" 0
assert_runtime_state_empty 'symlink update-config parent leaves runtime state untouched'

new_case update-parent-symlink-slash
mv "$CONFIG" "$CASE/config.real"
ln -s "$CASE/config.real" "$CONFIG"
run_update_with_config "$CONFIG/" --force
assert_run_status 'symlink update-config parent with trailing slash is rejected' 2
test_start 'symlink parent trailing slash is rejected before curl'
assert_eq "$(curl_count)" 0
assert_runtime_state_empty 'symlink parent trailing slash leaves runtime state untouched'

new_case update-parent-symlink-dot
mv "$CONFIG" "$CASE/config.real"
ln -s "$CASE/config.real" "$CONFIG"
run_update_with_config "$CONFIG/." --force
assert_run_status 'symlink update-config parent with dot component is rejected' 2
test_start 'symlink parent dot component is rejected before curl'
assert_eq "$(curl_count)" 0
assert_runtime_state_empty 'symlink parent dot component leaves runtime state untouched'

new_case update-parent-intermediate-symlink
ln -s "$CASE" "$CASE/alias-parent"
run_update_with_config "$CASE/alias-parent/config" --force
assert_run_status 'intermediate symlink in update-config path is rejected' 2
test_start 'intermediate symlink path is rejected before curl'
assert_eq "$(curl_count)" 0
assert_runtime_state_empty 'intermediate symlink path leaves runtime state untouched'

for path_spelling in trailing-slash dot dotdot repeated-slash relative-leading-dash control; do
  new_case update-parent-$path_spelling
  case $path_spelling in
    trailing-slash) noncanonical_config=$CONFIG/ ;;
    dot) noncanonical_config=$CASE/./config ;;
    dotdot)
      mkdir "$CASE/other"
      noncanonical_config=$CASE/other/../config
      ;;
    repeated-slash) noncanonical_config=$CASE//config ;;
    relative-leading-dash) noncanonical_config=-config ;;
    control) noncanonical_config=$(printf '%s\nx' "$CONFIG") ;;
  esac
  run_update_with_config "$noncanonical_config" --force
  assert_run_status "$path_spelling update-config path spelling is rejected" 2
  test_start "$path_spelling update-config path is rejected before curl"
  assert_eq "$(curl_count)" 0
  assert_runtime_state_empty "$path_spelling update-config path leaves runtime state untouched"
done

new_case canonical-update-parent
queue_response 0 200 'OK'
run_update_with_config "$CONFIG" --force
assert_run_success 'canonical physical update-config path succeeds'
test_start 'canonical physical update-config path performs one request'
assert_eq "$(curl_count)" 1

new_case update-parent-writable
chmod 770 "$CONFIG"
run_update --force
assert_run_status 'group-writable update-config parent is rejected as configuration' 2
test_start 'group-writable update-config parent is rejected before curl'
assert_eq "$(curl_count)" 0

new_case update-parent-owner
STUB_STAT_FOREIGN_CONFIG_DIR=1
export STUB_STAT_FOREIGN_CONFIG_DIR
run_update --force
assert_run_status 'unexpected update-config parent owner is rejected as configuration' 2
test_start 'unexpected update-config parent owner is rejected before curl'
assert_eq "$(curl_count)" 0

new_case main-seen-key-inspection-error
printf '%s\n' sentinel >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
cp "$STATE/last-provider-update.state" "$CASE/prior-state"
STUB_SEEN_GREP_FAIL_AT=WAN_IF
export STUB_SEEN_GREP_FAIL_AT
run_update --force
assert_run_status 'main duplicate-key inspection error is configuration failure' 2
test_start 'main duplicate-key inspection error performs no curl'
assert_eq "$(curl_count)" 0
test_start 'main duplicate-key inspection error preserves runtime state'
cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'state changed'
assert_secret_absent 'main duplicate-key inspection error process log' "$UPDATE_PROCESS_LOG"

new_case update-seen-key-inspection-error
printf '%s\n' sentinel >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
cp "$STATE/last-provider-update.state" "$CASE/prior-state"
STUB_SEEN_GREP_FAIL_AT=UPDATE_PASSWORD
export STUB_SEEN_GREP_FAIL_AT
run_update --force
assert_run_status 'update duplicate-key inspection error is configuration failure' 2
test_start 'update duplicate-key inspection error performs no curl'
assert_eq "$(curl_count)" 0
test_start 'update duplicate-key inspection error preserves runtime state'
cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'state changed'
assert_secret_absent 'update duplicate-key inspection error child environments' "$CHILD_ENV_LOG"

if [ "$(id -u)" -eq 0 ]; then
  new_case update-owner
  if chown 65534 "$CONFIG/provider-update.conf" 2>/dev/null; then
    run_update --force
    assert_run_status 'unexpected update config owner is rejected as configuration' 2
    test_start 'unexpected update config owner is rejected before curl'
    assert_eq "$(curl_count)" 0
  fi
fi

for invalid_config in empty-url empty-user empty-pass bad-scheme carriage tab; do
  new_case config-$invalid_config
  case $invalid_config in
    empty-url) printf '%s\n' 'UPDATE_URL=' "UPDATE_USERNAME=$TEST_USERNAME" "UPDATE_PASSWORD=$TEST_PASSWORD" >"$CONFIG/provider-update.conf" ;;
    empty-user) printf '%s\n' 'UPDATE_URL=https://update.example.invalid/' 'UPDATE_USERNAME=' "UPDATE_PASSWORD=$TEST_PASSWORD" >"$CONFIG/provider-update.conf" ;;
    empty-pass) printf '%s\n' 'UPDATE_URL=https://update.example.invalid/' "UPDATE_USERNAME=$TEST_USERNAME" 'UPDATE_PASSWORD=' >"$CONFIG/provider-update.conf" ;;
    bad-scheme) printf '%s\n' 'UPDATE_URL=file:///tmp/provider' "UPDATE_USERNAME=$TEST_USERNAME" "UPDATE_PASSWORD=$TEST_PASSWORD" >"$CONFIG/provider-update.conf" ;;
    carriage) printf 'UPDATE_URL=https://update.example.invalid/\r\nUPDATE_USERNAME=%s\nUPDATE_PASSWORD=%s\n' "$TEST_USERNAME" "$TEST_PASSWORD" >"$CONFIG/provider-update.conf" ;;
    tab) printf 'UPDATE_URL=https://update.example.invalid/\nUPDATE_USERNAME=user\tname\nUPDATE_PASSWORD=%s\n' "$TEST_PASSWORD" >"$CONFIG/provider-update.conf" ;;
  esac
  printf '%s\n' 'ALLOW_INSECURE_UPDATE_HTTP=no' 'INSECURE_UPDATE_HTTP_HOST=' >>"$CONFIG/provider-update.conf"
  chmod 600 "$CONFIG/provider-update.conf"
  run_update --force
  assert_run_status "$invalid_config update config is rejected" 2
  test_start "$invalid_config update config causes no request"
  assert_eq "$(curl_count)" 0
done

# Curl config grammar escaping is exact and control rejection is silent.
test_start 'curl config escaping changes only backslash and quote'
assert_eq "$(v6_curl_config_escape 'left\right"quoted')" 'left\\right\"quoted'
test_start 'curl config escaping emits no extra delimiter byte'
printf '%s' 'left\\right\"quoted' >"$CASE/curl-escape-expected"
v6_curl_config_escape 'left\right"quoted' >"$CASE/curl-escape-actual"
cmp -s "$CASE/curl-escape-actual" "$CASE/curl-escape-expected" && pass || fail 'escape output gained an extra byte'
test_start 'curl config escaping rejects controls without echoing input'
curl_escape_error=$CASE/curl-escape.error
if v6_curl_config_escape "unsafe	value" >"$CASE/curl-escape.output" 2>"$curl_escape_error"; then
  fail 'control-bearing value unexpectedly accepted'
else
  if [ ! -s "$CASE/curl-escape.output" ] && [ ! -s "$curl_escape_error" ]; then pass; else fail 'rejected value was echoed'; fi
fi

test_start 'control-character helper propagates grep execution errors'
set +e
V6_CONTROL_GREP_CMD=$ROOT/tests/stubs/update/fail-command v6_has_control_character safe
control_helper_status=$?
set -e
assert_eq "$control_helper_status" 2

test_start 'curl config escaping propagates sed execution errors without output'
set +e
V6_CURL_SED_CMD=$ROOT/tests/stubs/update/fail-command v6_curl_config_escape safe >"$CASE/sed-failure-output"
curl_escape_status=$?
set -e
if [ "$curl_escape_status" -eq 2 ] && [ ! -s "$CASE/sed-failure-output" ]; then pass; else fail "status=$curl_escape_status output=$(cat "$CASE/sed-failure-output")"; fi

new_case grep-failure
printf '%s\n' sentinel >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
cp "$STATE/last-provider-update.state" "$CASE/prior-state"
STUB_CONTROL_GREP_FAIL=1
export STUB_CONTROL_GREP_FAIL
run_update --force
assert_run_status 'control grep failure is a configuration error' 2
test_start 'control grep failure performs no curl'
assert_eq "$(curl_count)" 0
test_start 'control grep failure preserves state byte-for-byte'
cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'state changed'

new_case sed-failure
printf '%s\n' sentinel >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
cp "$STATE/last-provider-update.state" "$CASE/prior-state"
STUB_CURL_SED_FAIL=1
export STUB_CURL_SED_FAIL
run_update --force
assert_run_status 'curl escaping sed failure is a configuration error' 2
test_start 'curl escaping sed failure performs no curl'
assert_eq "$(curl_count)" 0
test_start 'curl escaping sed failure preserves state byte-for-byte'
cmp -s "$STATE/last-provider-update.state" "$CASE/prior-state" && pass || fail 'state changed'

new_case scratch-environment-secrecy
line=$TEST_USERNAME
key=$TEST_USERNAME
value=$TEST_PASSWORD
v6_update_line=$TEST_USERNAME
v6_update_key=$TEST_USERNAME
v6_update_value=$TEST_PASSWORD
V6_CURL_ESCAPED_USERNAME=$TEST_USERNAME
V6_CURL_ESCAPED_PASSWORD=$TEST_PASSWORD
export line key value v6_update_line v6_update_key v6_update_value
export V6_CURL_ESCAPED_USERNAME V6_CURL_ESCAPED_PASSWORD
queue_response 7 000 'retry'
queue_response 0 200 'OK'
run_update --force
assert_run_success 'exported generic scratch names do not block notification'
for child_name in grep sed ip curl logger sleep; do
  test_start "$child_name child environment excludes raw credentials"
  assert_contains "$(cat "$CHILD_ENV_LOG")" "--- $child_name ---"
  if grep -F "$TEST_USERNAME" "$CHILD_ENV_LOG" >/dev/null 2>&1 || grep -F "$TEST_PASSWORD" "$CHILD_ENV_LOG" >/dev/null 2>&1; then
    fail 'credential leaked through inherited environment'
  else
    pass
  fi
done

new_case endpoint-environment-secrecy
SOURCE_V6=sentinel-source-v6
LOCAL_V6=sentinel-local-v6
expanded_endpoint=sentinel-expanded-endpoint
REDACTED_ENDPOINT=sentinel-redacted-endpoint
NOW=sentinel-now
source_full=sentinel-source-full
iid_full=sentinel-iid-full
iid=sentinel-iid
output=sentinel-output
source_prefix=sentinel-source-prefix
iid_suffix=sentinel-iid-suffix
v6_route_output=sentinel-route-output
v6_compose_iid=sentinel-compose-iid
v6_compose_source_full=sentinel-compose-source-full
v6_compose_iid_full=sentinel-compose-iid-full
v6_compose_source_prefix=sentinel-compose-source-prefix
v6_compose_iid_suffix=sentinel-compose-iid-suffix
export SOURCE_V6 LOCAL_V6 expanded_endpoint REDACTED_ENDPOINT NOW
export source_full iid_full iid output source_prefix iid_suffix v6_route_output
export v6_compose_iid v6_compose_source_full v6_compose_iid_full
export v6_compose_source_prefix v6_compose_iid_suffix
unset V6PLUS_NOW
STUB_DATE_VALUE=1700000000
export STUB_DATE_VALUE
queue_response 7 000 'retry'
queue_response 0 200 'OK'
run_update --force
assert_run_success 'inherited exported endpoint scratch names do not block notification'
for child_name in ip awk cut tr date logger curl sleep stat grep sed; do
  test_start "$child_name child ran during endpoint environment test"
  assert_contains "$(cat "$CHILD_ENV_LOG")" "--- $child_name ---"
done
for forbidden_environment_value in sentinel-source-v6 sentinel-local-v6 sentinel-expanded-endpoint \
  sentinel-redacted-endpoint sentinel-now sentinel-source-full sentinel-iid-full sentinel-iid \
  sentinel-output sentinel-source-prefix sentinel-iid-suffix sentinel-route-output \
  sentinel-compose-iid sentinel-compose-source-full sentinel-compose-iid-full \
  sentinel-compose-source-prefix sentinel-compose-iid-suffix \
  2001:db8:1234:30:abcd::1 2001:0db8:1234:0030:abcd:0000:0000:0001 \
  2001:0db8:1234:0030:00cb:0071:2a00:0000; do
  test_start "child environments exclude endpoint value <$forbidden_environment_value>"
  if grep -F "$forbidden_environment_value" "$CHILD_ENV_LOG" >/dev/null 2>&1; then
    fail 'endpoint value leaked through inherited environment'
  else
    pass
  fi
done
test_start 'curl still binds the computed exact endpoint after export cleanup'
assert_contains "$(nul_args "$CURL_ARGV_LOG")" "--interface
2001:0db8:1234:0030:00cb:0071:2a00:0000"
test_start 'private state still records the computed exact endpoint after export cleanup'
assert_contains "$(cat "$STATE/last-provider-update.state")" 'LOCAL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000'
unset SOURCE_V6 LOCAL_V6 expanded_endpoint REDACTED_ENDPOINT NOW
unset source_full iid_full iid output source_prefix iid_suffix v6_route_output
unset v6_compose_iid v6_compose_source_full v6_compose_iid_full
unset v6_compose_source_prefix v6_compose_iid_suffix
LOCAL_V6=2001:0db8:1234:0030:00cb:0071:2a00:0000

# Exact source presence, status parsing, locking, cleanup, and usage are fail-closed.
new_case missing-source
IP_ADDR_MODE=absent
export IP_ADDR_MODE
run_update --force
assert_run_status 'missing exact source /128 is a runtime failure' 1
test_start 'missing exact source has distinct stable diagnostic'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=source_address'
test_start 'missing source /128 prevents curl'
assert_eq "$(curl_count)" 0

new_case addr-inspection-error
IP_ADDR_MODE=error
export IP_ADDR_MODE
run_update --force
assert_run_status 'source-address inspection error is a runtime failure' 1
test_start 'source inspection error has distinct stable diagnostic'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=source_inspection'
test_start 'source inspection error prevents curl'
assert_eq "$(curl_count)" 0

for source_mode in prefix64 valid-compressed64 other; do
  new_case source-$source_mode
  IP_ADDR_MODE=$source_mode
  export IP_ADDR_MODE
  run_update --force
  assert_run_status "$source_mode source listing is rejected" 1
  test_start "$source_mode source listing prevents curl"
  assert_eq "$(curl_count)" 0
  test_start "$source_mode valid listing without exact host has address diagnostic"
  assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=source_address'
done

for source_mode in malformed malformed-address64 invalid-hex64 missing-separator extra-separator \
  malformed64-then-present present-then-malformed64 prefix-leading-zero prefix-oversized \
  prefix-nonnumeric multiline-malformed; do
  new_case source-$source_mode
  IP_ADDR_MODE=$source_mode
  export IP_ADDR_MODE
  run_update --force
  assert_run_status "$source_mode malformed source listing is rejected" 1
  test_start "$source_mode malformed source listing prevents curl"
  assert_eq "$(curl_count)" 0
  test_start "$source_mode malformed source listing has inspection diagnostic"
  assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=source_inspection'
  assert_no_shell_diagnostic "$source_mode malformed source listing emits no raw shell diagnostic"
done

new_case source-valid64-then-present
IP_ADDR_MODE=valid64-then-present
export IP_ADDR_MODE
queue_response 0 200 'OK'
run_update --force
assert_run_success 'valid compressed /64 before exact /128 is ignored safely'
test_start 'valid compressed /64 followed by exact /128 performs one request'
assert_eq "$(curl_count)" 1

new_case prior-state-owner
printf '%s\n' "LOCAL_V6=$LOCAL_V6" 'SUCCEEDED_AT=1699999500' 'HTTP_CODE=200' >"$STATE/last-provider-update.state"
chmod 600 "$STATE/last-provider-update.state"
STUB_STAT_FOREIGN_STATE=1
export STUB_STAT_FOREIGN_STATE
run_update --force
assert_run_status 'force rejects unexpected prior-state owner metadata' 1
test_start 'unexpected prior-state owner prevents curl'
assert_eq "$(curl_count)" 0

for malformed_http in '' 20 2000 abc 099 600 '200 extra'; do
  new_case http-$(printf '%s' "$malformed_http" | tr -cd 'A-Za-z0-9')
  queue_response 0 "$malformed_http" 'OK'
  queue_response 0 "$malformed_http" 'OK'
  queue_response 0 "$malformed_http" 'OK'
  run_update --force
  assert_run_status "malformed HTTP code <$malformed_http> fails" 1
done

new_case lock-conflict
mkdir "$V6PLUS_LOCK_DIR"
printf '999999\n' >"$V6PLUS_LOCK_DIR/pid"
run_update --force
assert_run_status 'shared lock conflict is a runtime failure' 1
test_start 'shared lock conflict leaves the foreign lock intact'
assert_eq "$(cat "$V6PLUS_LOCK_DIR/pid")" 999999

new_case lock-signal
V6PLUS_TEST_SIGNAL_DURING_LOCK=1
export V6PLUS_TEST_SIGNAL_DURING_LOCK
run_update --force
assert_run_status 'signal during lock acquisition exits nonzero' 143
assert_file_absent 'signal during lock acquisition cleans owned lock' "$V6PLUS_LOCK_DIR"

new_case temp-signal
queue_response 0 200 'OK'
V6PLUS_TEST_SIGNAL_AFTER_TEMP=1
V6PLUS_TEST_TEMP_LOG=$CASE/temp-path
export V6PLUS_TEST_SIGNAL_AFTER_TEMP V6PLUS_TEST_TEMP_LOG
run_update --force
assert_run_status 'signal after response temp creation exits nonzero' 143
temp_created=$(cat "$V6PLUS_TEST_TEMP_LOG")
assert_file_absent 'signal removes private response temp directory' "$temp_created"
assert_file_absent 'signal after temp creation releases owned lock' "$V6PLUS_LOCK_DIR"

new_case temp-success
queue_response 0 200 'OK'
V6PLUS_TEST_TEMP_LOG=$CASE/temp-path
export V6PLUS_TEST_TEMP_LOG
run_update --force
assert_run_success 'normal completion cleans response temporaries'
temp_created=$(cat "$V6PLUS_TEST_TEMP_LOG")
assert_file_absent 'normal completion removes response temp directory' "$temp_created"
assert_file_absent 'normal completion releases owned lock' "$V6PLUS_LOCK_DIR"

new_case state-dir-mode
chmod 755 "$STATE"
run_update --force
assert_run_status 'unsafe state directory mode is a runtime failure' 1
test_start 'unsafe state directory mode prevents curl'
assert_eq "$(curl_count)" 0

new_case state-symlink
printf '%s\n' 'outside' >"$CASE/outside-state"
ln -s "$CASE/outside-state" "$STATE/last-provider-update.state"
run_update
assert_run_status 'symlink prior state is rejected' 1
test_start 'symlink prior state target is unchanged'
assert_eq "$(cat "$CASE/outside-state")" outside

for usage_args in '--bogus' '--config' '--force --force' '--config one --config two'; do
  new_case usage-$(printf '%s' "$usage_args" | tr -cd 'A-Za-z')
  # Deliberate splitting exercises the command-line grammar.
  # shellcheck disable=SC2086
  run_update $usage_args
  assert_run_status "usage error <$usage_args> exits 2" 2
  test_start "usage error <$usage_args> performs no request"
  assert_eq "$(curl_count)" 0
done

test_finish
