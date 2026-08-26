#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"
. "$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh"
V6PLUS_ALLOW_NONROOT=1
V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_ALLOW_NONROOT V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/v6plus-lib-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/config"
chmod 700 "$TMP/config"

cat >"$TMP/config/gateway.conf" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
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

cat >"$TMP/config/routed-networks.conf" <<'EOF'
# home
br0 192.168.20.0/24

br10 192.168.10.0/24
EOF

cat >"$TMP/bin/ip" <<'EOF'
#!/bin/sh
case $* in
  'link show dev br0'|'link show dev br10') exit 0 ;;
  '-d link show type bridge')
    printf '10: br0: <BROADCAST,MULTICAST,UP> mtu 1500 state UP\n'
    printf '11: br10: <BROADCAST,MULTICAST,UP> mtu 1500 state UP\n'
    ;;
  '-4 route show dev br0 scope link')
    printf '192.168.20.0/24 proto kernel scope link src 192.168.20.1\n'
    ;;
  '-4 route show dev br10 scope link')
    case ${LIB_CONNECTED_ROUTES_MODE:-normal} in
      normal) printf '192.168.10.0/24 proto kernel scope link src 192.168.10.1\n' ;;
      overlap) printf '192.168.20.128/25 proto kernel scope link src 192.168.20.129\n' ;;
      missing) : ;;
      *) exit 99 ;;
    esac
    ;;
  '-6 route show table all proto kernel')
    case ${LIB_ENDPOINT_ROUTE_MODE:-one} in
      one)
        printf 'anycast 2001:db8:1234:20::/64 dev br0 proto kernel metric 0\n'
        printf '2001:db8:1234:30::/64 dev br10 proto kernel metric 256\n'
        ;;
      zero)
        printf 'fe80::/64 dev br0 proto kernel metric 256\n'
        ;;
      multiple)
        printf '2001:db8:1234:20::/64 dev br0 proto kernel metric 256\n'
        printf '2001:db8:1234:21::/64 dev br0 proto kernel metric 256\n'
        ;;
      wan)
        printf '2001:db8:1234:30::/64 dev eth9 proto kernel metric 256\n'
        ;;
      *) exit 99 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/ip"
PATH="$TMP/bin:$PATH"
export PATH

validate_main_file() {
  v6_load_main_config "$1" "$TMP/config/routed-networks.conf" && v6_validate_main_config
}

call_endpoint_prefix64() {
  command -v v6_endpoint_prefix64 >/dev/null 2>&1 || return 0
  v6_endpoint_prefix64 "$1"
}

make_main_variant() {
  sed "s|$2|$3|" "$TMP/config/gateway.conf" >"$TMP/config/$1"
}

test_start 'redacts password assignment'
assert_eq "$(v6_redact 'UPDATE_PASSWORD=secret-value')" 'UPDATE_PASSWORD=[REDACTED]'

test_start 'redacts username assignment'
assert_eq "$(v6_redact 'UPDATE_USERNAME=user-value')" 'UPDATE_USERNAME=[REDACTED]'

test_start 'redacts pass query parameter'
assert_eq "$(v6_redact 'http://u/?user=abc&pass=secret')" 'http://u/?user=[REDACTED]&pass=[REDACTED]'

v6_load_main_config "$TMP/config/gateway.conf" "$TMP/config/routed-networks.conf"
test_start 'valid config passes'
assert_success v6_validate_main_config

test_start 'explicit endpoint interface is accepted as config data'
assert_eq "$V6_ENDPOINT_IF" br0

sed '/^ENDPOINT_IF=/d' "$TMP/config/gateway.conf" >"$TMP/config/missing-endpoint.env"
test_start 'missing endpoint interface fails'
assert_failure validate_main_file "$TMP/config/missing-endpoint.env"

LIB_ENDPOINT_ROUTE_MODE=one
export LIB_ENDPOINT_ROUTE_MODE
test_start 'endpoint prefix comes from the explicit bridge kernel route'
assert_eq "$(call_endpoint_prefix64 br0)" '2001:0db8:1234:0020:0000:0000:0000:0000'

LIB_ENDPOINT_ROUTE_MODE=zero
export LIB_ENDPOINT_ROUTE_MODE
test_start 'zero endpoint prefix candidates fail closed'
assert_failure call_endpoint_prefix64 br0

LIB_ENDPOINT_ROUTE_MODE=multiple
export LIB_ENDPOINT_ROUTE_MODE
test_start 'multiple endpoint prefix candidates fail closed'
assert_failure call_endpoint_prefix64 br0

LIB_ENDPOINT_ROUTE_MODE=wan
export LIB_ENDPOINT_ROUTE_MODE
test_start 'WAN interface cannot be selected as the delegated endpoint bridge'
assert_failure call_endpoint_prefix64 eth9

LIB_ENDPOINT_ROUTE_MODE=one
export LIB_ENDPOINT_ROUTE_MODE

sed '/^TCP_MSS=/d' "$TMP/config/gateway.conf" >"$TMP/config/missing-key.env"
test_start 'missing required key fails'
assert_failure validate_main_file "$TMP/config/missing-key.env"

make_main_variant 'invalid-ipv4.env' 'STATIC_V4=203.0.113.42' 'STATIC_V4=999.0.0.1'
test_start 'invalid static IPv4 fails'
assert_failure validate_main_file "$TMP/config/invalid-ipv4.env"

make_main_variant 'invalid-iid.env' 'IID=00cb:0071:2a00:0000' 'IID=00cb:0071:2a00:zzzz'
test_start 'invalid IID fails'
assert_failure validate_main_file "$TMP/config/invalid-iid.env"

make_main_variant 'mtu-min.env' 'TUN_MTU=1460' 'TUN_MTU=1280'
sed 's/TCP_MSS=1420/TCP_MSS=1240/' "$TMP/config/mtu-min.env" >"$TMP/config/mtu-min.tmp"
mv "$TMP/config/mtu-min.tmp" "$TMP/config/mtu-min.env"
test_start 'minimum TUN_MTU passes'
assert_success validate_main_file "$TMP/config/mtu-min.env"
make_main_variant 'mtu-max.env' 'TUN_MTU=1460' 'TUN_MTU=1500'
test_start 'maximum TUN_MTU passes'
assert_success validate_main_file "$TMP/config/mtu-max.env"
make_main_variant 'mtu-low.env' 'TUN_MTU=1460' 'TUN_MTU=1279'
test_start 'low TUN_MTU fails'
assert_failure validate_main_file "$TMP/config/mtu-low.env"
make_main_variant 'mtu-high.env' 'TUN_MTU=1460' 'TUN_MTU=1501'
test_start 'high TUN_MTU fails'
assert_failure validate_main_file "$TMP/config/mtu-high.env"
make_main_variant 'mtu-text.env' 'TUN_MTU=1460' 'TUN_MTU=abc'
test_start 'non-numeric TUN_MTU fails'
assert_failure validate_main_file "$TMP/config/mtu-text.env"

make_main_variant 'mss-min.env' 'TCP_MSS=1420' 'TCP_MSS=536'
test_start 'minimum TCP_MSS passes'
assert_success validate_main_file "$TMP/config/mss-min.env"
make_main_variant 'mss-max.env' 'TCP_MSS=1420' 'TCP_MSS=1460'
test_start 'absolute maximum TCP MSS fails when it exceeds tunnel MTU minus IPv4 header'
assert_failure validate_main_file "$TMP/config/mss-max.env"
make_main_variant 'mss-low.env' 'TCP_MSS=1420' 'TCP_MSS=535'
test_start 'low TCP_MSS fails'
assert_failure validate_main_file "$TMP/config/mss-low.env"
make_main_variant 'mss-high.env' 'TCP_MSS=1420' 'TCP_MSS=1461'
test_start 'high TCP_MSS fails'
assert_failure validate_main_file "$TMP/config/mss-high.env"
make_main_variant 'mss-text.env' 'TCP_MSS=1420' 'TCP_MSS=abc'
test_start 'non-numeric TCP_MSS fails'
assert_failure validate_main_file "$TMP/config/mss-text.env"

make_main_variant 'table-min.env' 'ROUTE_TABLE=300' 'ROUTE_TABLE=1'
test_start 'minimum route table passes'
assert_success validate_main_file "$TMP/config/table-min.env"
make_main_variant 'table-max.env' 'ROUTE_TABLE=300' 'ROUTE_TABLE=4294967295'
test_start 'maximum route table passes'
assert_success validate_main_file "$TMP/config/table-max.env"
make_main_variant 'table-low.env' 'ROUTE_TABLE=300' 'ROUTE_TABLE=0'
test_start 'low route table fails'
assert_failure validate_main_file "$TMP/config/table-low.env"
make_main_variant 'table-high.env' 'ROUTE_TABLE=300' 'ROUTE_TABLE=4294967296'
test_start 'high route table fails'
assert_failure validate_main_file "$TMP/config/table-high.env"
make_main_variant 'table-text.env' 'ROUTE_TABLE=300' 'ROUTE_TABLE=abc'
test_start 'non-numeric route table fails'
assert_failure validate_main_file "$TMP/config/table-text.env"

make_main_variant 'pref-min.env' 'RULE_PREF_BASE=10000' 'RULE_PREF_BASE=1'
test_start 'minimum rule preference passes'
assert_success validate_main_file "$TMP/config/pref-min.env"
make_main_variant 'pref-max.env' 'RULE_PREF_BASE=10000' 'RULE_PREF_BASE=32700'
test_start 'maximum rule preference passes'
assert_success validate_main_file "$TMP/config/pref-max.env"
make_main_variant 'pref-low.env' 'RULE_PREF_BASE=10000' 'RULE_PREF_BASE=0'
test_start 'low rule preference fails'
assert_failure validate_main_file "$TMP/config/pref-low.env"
make_main_variant 'pref-high.env' 'RULE_PREF_BASE=10000' 'RULE_PREF_BASE=32701'
test_start 'high rule preference fails'
assert_failure validate_main_file "$TMP/config/pref-high.env"
make_main_variant 'pref-text.env' 'RULE_PREF_BASE=10000' 'RULE_PREF_BASE=abc'
test_start 'non-numeric rule preference fails'
assert_failure validate_main_file "$TMP/config/pref-text.env"

make_main_variant 'watch-zero.env' 'WATCH_INTERVAL_SECONDS=5' 'WATCH_INTERVAL_SECONDS=0'
test_start 'zero watch interval fails'
assert_failure validate_main_file "$TMP/config/watch-zero.env"
make_main_variant 'watch-text.env' 'WATCH_INTERVAL_SECONDS=5' 'WATCH_INTERVAL_SECONDS=abc'
test_start 'non-numeric watch interval fails'
assert_failure validate_main_file "$TMP/config/watch-text.env"
make_main_variant 'update-zero.env' 'UPDATE_INTERVAL_SECONDS=600' 'UPDATE_INTERVAL_SECONDS=0'
test_start 'zero update interval disables non-forced notifications'
assert_success validate_main_file "$TMP/config/update-zero.env"
make_main_variant 'update-text.env' 'UPDATE_INTERVAL_SECONDS=600' 'UPDATE_INTERVAL_SECONDS=abc'
test_start 'non-numeric update interval fails'
assert_failure validate_main_file "$TMP/config/update-text.env"
make_main_variant 'outer-allow.env' 'OUTER_IPIP_ALLOW=auto' 'OUTER_IPIP_ALLOW=maybe'
test_start 'invalid outer IPIP allow value fails'
assert_failure validate_main_file "$TMP/config/outer-allow.env"

make_main_variant 'mss-too-large.env' 'TCP_MSS=1420' 'TCP_MSS=1421'
test_start 'TCP MSS larger than tunnel MTU minus IPv4 header fails'
assert_failure validate_main_file "$TMP/config/mss-too-large.env"

test_start 'network parser emits stable delimiter'
assert_eq "$(v6_iter_networks "$TMP/config/routed-networks.conf")" "br0|192.168.20.0/24
br10|192.168.10.0/24"

printf 'br0 192.168.20.0/24\nbr0 192.168.20.0/24\n' >"$TMP/config/duplicate.conf"
test_start 'duplicate network fails'
assert_failure v6_iter_networks "$TMP/config/duplicate.conf"

printf 'br0 192.168.20.0/24 extra\n' >"$TMP/config/three-fields.conf"
test_start 'network entry with wrong field count fails'
assert_failure v6_iter_networks "$TMP/config/three-fields.conf"
printf 'br0 192.168.20.0/33\n' >"$TMP/config/invalid-cidr.conf"
test_start 'network entry with invalid CIDR fails'
assert_failure v6_iter_networks "$TMP/config/invalid-cidr.conf"
printf 'br99 192.168.20.0/24\n' >"$TMP/config/missing-link.conf"
test_start 'network entry with missing link fails'
assert_failure v6_iter_networks "$TMP/config/missing-link.conf"

printf 'br0 8.8.8.0/24\n' >"$TMP/config/public-cidr.conf"
test_start 'public routed network fails'
assert_failure v6_iter_networks "$TMP/config/public-cidr.conf"

printf 'br0 192.168.20.1/24\n' >"$TMP/config/noncanonical-cidr.conf"
test_start 'noncanonical routed network fails'
assert_failure v6_iter_networks "$TMP/config/noncanonical-cidr.conf"

printf 'br0 192.168.20.0/24\nbr10 192.168.20.128/25\n' >"$TMP/config/overlap.conf"
LIB_CONNECTED_ROUTES_MODE=overlap
export LIB_CONNECTED_ROUTES_MODE
test_start 'overlapping routed networks fail'
assert_failure v6_iter_networks "$TMP/config/overlap.conf"
unset LIB_CONNECTED_ROUTES_MODE

LIB_CONNECTED_ROUTES_MODE=missing
export LIB_CONNECTED_ROUTES_MODE
test_start 'network without an exact connected route fails'
assert_failure v6_iter_networks "$TMP/config/routed-networks.conf"
unset LIB_CONNECTED_ROUTES_MODE

DRY_RUN=1
export DRY_RUN
test_start 'dry run prints but does not execute'
assert_contains "$(v6_run false 2>&1)" '[dry-run] false'

test_start 'first lock succeeds'
assert_success v6_acquire_lock "$TMP/lock"
test_start 'second lock fails'
assert_failure v6_acquire_lock "$TMP/lock"
test_start 'lock conflict reports safe stale-lock verification'
assert_contains "$(v6_acquire_lock "$TMP/lock" 2>&1 || true)" 'kill -0'
v6_release_lock "$TMP/lock"
mkdir "$TMP/foreign-lock"
printf '999999\n' >"$TMP/foreign-lock/pid"
test_start 'foreign PID lock is not released'
v6_release_lock "$TMP/foreign-lock"
assert_file_exists "$TMP/foreign-lock/pid"
rm -f "$TMP/foreign-lock/pid"
rmdir "$TMP/foreign-lock"
test_start 'released lock can be acquired again'
assert_success v6_acquire_lock "$TMP/lock"
v6_release_lock "$TMP/lock"

cat >"$TMP/config/unknown.env" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
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
UNEXPECTED_KEY=value
EOF
test_start 'unknown main config key fails'
assert_failure v6_load_main_config "$TMP/config/unknown.env" "$TMP/config/routed-networks.conf"

cat >"$TMP/config/duplicate.env" <<'EOF'
WAN_IF=eth9
WAN_IF=eth10
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
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
test_start 'duplicate main config key fails'
assert_failure v6_load_main_config "$TMP/config/duplicate.env" "$TMP/config/routed-networks.conf"

V6_SEEN_GREP_CMD=$ROOT/tests/stubs/update/seen-grep
STUB_SEEN_GREP_FAIL_AT=WAN_IF
export V6_SEEN_GREP_CMD STUB_SEEN_GREP_FAIL_AT
test_start 'main duplicate-key lookup error fails closed'
assert_failure v6_load_main_config "$TMP/config/gateway.conf" "$TMP/config/routed-networks.conf"
unset STUB_SEEN_GREP_FAIL_AT

cat >"$TMP/config/update-valid.env" <<'EOF'
UPDATE_URL=https://update.example.invalid/path
UPDATE_USERNAME=user
UPDATE_PASSWORD=password
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
EOF
chmod 600 "$TMP/config/update-valid.env"
test_start 'private update config in a secure parent loads as data'
assert_success v6_load_update_config "$TMP/config/update-valid.env"

STUB_SEEN_GREP_FAIL_AT=UPDATE_PASSWORD
export STUB_SEEN_GREP_FAIL_AT
test_start 'update duplicate-key lookup error fails closed'
assert_failure v6_load_update_config "$TMP/config/update-valid.env"
unset STUB_SEEN_GREP_FAIL_AT

cat >"$TMP/config/update-unknown.env" <<'EOF'
UPDATE_URL=http://update.example.invalid/path
UPDATE_USERNAME=user
UPDATE_PASSWORD=password
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
EXTRA=value
EOF
chmod 600 "$TMP/config/update-unknown.env"
test_start 'unknown update config key fails'
assert_failure v6_load_update_config "$TMP/config/update-unknown.env"

cat >"$TMP/config/update-duplicate.env" <<'EOF'
UPDATE_URL=http://update.example.invalid/path
UPDATE_USERNAME=user
UPDATE_PASSWORD=password
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
UPDATE_PASSWORD=another-password
EOF
chmod 600 "$TMP/config/update-duplicate.env"
test_start 'duplicate update config key fails'
assert_failure v6_load_update_config "$TMP/config/update-duplicate.env"

cat >"$TMP/config/malformed.env" <<'EOF'
WAN_IF=eth9
this is not an assignment
EOF
test_start 'malformed main assignment fails'
assert_failure v6_load_main_config "$TMP/config/malformed.env" "$TMP/config/routed-networks.conf"

cat >"$TMP/config/malicious.env" <<'EOF'
WAN_IF=$(touch forbidden)
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
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
malicious_load_is_safe() {
  (
    cd "$TMP"
    v6_load_main_config "$TMP/config/malicious.env" "$TMP/config/routed-networks.conf"
    [ ! -e forbidden ]
  )
}
test_start 'main config values are never executed'
assert_success malicious_load_is_safe

cat >"$TMP/config/malicious-provider-update.conf" <<'EOF'
UPDATE_URL=https://update.example.invalid/path
UPDATE_USERNAME=user
UPDATE_PASSWORD=$(touch update-forbidden)
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
EOF
chmod 600 "$TMP/config/malicious-provider-update.conf"
malicious_update_load_is_safe() {
  (
    cd "$TMP"
    v6_load_update_config "$TMP/config/malicious-provider-update.conf" || exit 1
    [ "$V6_UPDATE_PASSWORD" = '$(touch update-forbidden)' ] || exit 1
    [ ! -e update-forbidden ]
  )
}
test_start 'update config values are never executed'
assert_success malicious_update_load_is_safe

cat >"$TMP/config/update-http-default.env" <<'EOF'
UPDATE_URL=http://legacy.example.invalid/path
UPDATE_USERNAME=user
UPDATE_PASSWORD=password
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
EOF
chmod 600 "$TMP/config/update-http-default.env"
test_start 'legacy HTTP is rejected by default'
assert_failure v6_load_update_config "$TMP/config/update-http-default.env"

cat >"$TMP/config/update-http-opt-in.env" <<'EOF'
UPDATE_URL=http://legacy.example.invalid/path
UPDATE_USERNAME=user
UPDATE_PASSWORD=password
ALLOW_INSECURE_UPDATE_HTTP=yes
INSECURE_UPDATE_HTTP_HOST=legacy.example.invalid
EOF
chmod 600 "$TMP/config/update-http-opt-in.env"
test_start 'legacy HTTP requires explicit exact-host opt-in'
assert_success v6_load_update_config "$TMP/config/update-http-opt-in.env"

sed 's/INSECURE_UPDATE_HTTP_HOST=legacy.example.invalid/INSECURE_UPDATE_HTTP_HOST=other.example.invalid/' \
  "$TMP/config/update-http-opt-in.env" >"$TMP/config/update-http-mismatch.env"
test_start 'legacy HTTP exact-host mismatch is rejected'
assert_failure v6_load_update_config "$TMP/config/update-http-mismatch.env"

chmod 644 "$TMP/config/gateway.conf"
test_start 'main config with non-private mode is rejected before parsing'
assert_failure v6_load_main_config "$TMP/config/gateway.conf" "$TMP/config/routed-networks.conf"
chmod 600 "$TMP/config/gateway.conf"

chmod 644 "$TMP/config/routed-networks.conf"
test_start 'network config with non-private mode is rejected before parsing'
assert_failure v6_load_main_config "$TMP/config/gateway.conf" "$TMP/config/routed-networks.conf"
chmod 600 "$TMP/config/routed-networks.conf"

mv "$TMP/config/routed-networks.conf" "$TMP/config/networks.real"
ln -s "$TMP/config/networks.real" "$TMP/config/routed-networks.conf"
test_start 'symlinked network config is rejected before parsing'
assert_failure v6_load_main_config "$TMP/config/gateway.conf" "$TMP/config/routed-networks.conf"
rm "$TMP/config/routed-networks.conf"
mv "$TMP/config/networks.real" "$TMP/config/routed-networks.conf"

production_chain=$( (
  unset V6PLUS_ALLOW_NONROOT
  v6_validate_secure_directory() { printf '%s\n' "$1"; }
  v6_validate_canonical_secure_directory "$TMP/config"
) )
test_start 'production directory validation walks through the filesystem root'
if case $production_chain in "$TMP/config
$TMP"*) true ;; *) false ;; esac &&
   [ "$(printf '%s\n' "$production_chain" | tail -n 1)" = / ]; then
  pass
else
  fail "unexpected validation chain <$production_chain>"
fi

unset V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
cat >"$TMP/config/rfc5737.env" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
STATIC_V4=203.0.113.42
BR_V6=2001:4860::1
IID=00cb:0071:2a00:0000
TUN_MTU=1460
TCP_MSS=1420
ROUTE_TABLE=300
RULE_PREF_BASE=10000
WATCH_INTERVAL_SECONDS=5
UPDATE_INTERVAL_SECONDS=600
OUTER_IPIP_ALLOW=auto
EOF
v6_load_main_config "$TMP/config/rfc5737.env" "$TMP/config/routed-networks.conf"
test_start 'RFC 5737 static IPv4 fails without override'
assert_failure v6_validate_main_config
cat >"$TMP/config/rfc3849.env" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
STATIC_V4=8.8.8.8
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
v6_load_main_config "$TMP/config/rfc3849.env" "$TMP/config/routed-networks.conf"
test_start 'RFC 3849 bridge IPv6 fails without override'
assert_failure v6_validate_main_config
cat >"$TMP/config/invalid-ipv6.env" <<'EOF'
WAN_IF=eth9
TUN_IF=ip6tnl1
ENDPOINT_IF=br0
STATIC_V4=8.8.8.8
BR_V6=2001::db8::1
IID=00cb:0071:2a00:0000
TUN_MTU=1460
TCP_MSS=1420
ROUTE_TABLE=300
RULE_PREF_BASE=10000
WATCH_INTERVAL_SECONDS=5
UPDATE_INTERVAL_SECONDS=600
OUTER_IPIP_ALLOW=auto
EOF
v6_load_main_config "$TMP/config/invalid-ipv6.env" "$TMP/config/routed-networks.conf"
test_start 'malformed bridge IPv6 fails'
assert_failure v6_validate_main_config
sed -e 's|STATIC_V4=203.0.113.42|STATIC_V4=8.8.8.8|' -e 's|BR_V6=2001:db8:ffff::1|BR_V6=:1:2:3:4:5:6:7:8|' "$TMP/config/gateway.conf" >"$TMP/config/leading-colon-ipv6.env"
test_start 'bridge IPv6 with a leading single colon fails'
assert_failure validate_main_file "$TMP/config/leading-colon-ipv6.env"
sed -e 's|STATIC_V4=203.0.113.42|STATIC_V4=8.8.8.8|' -e 's|BR_V6=2001:db8:ffff::1|BR_V6=1:2:3:4:5:6:7:8:|' "$TMP/config/gateway.conf" >"$TMP/config/trailing-colon-ipv6.env"
test_start 'bridge IPv6 with a trailing single colon fails'
assert_failure validate_main_file "$TMP/config/trailing-colon-ipv6.env"
sed -e 's|STATIC_V4=203.0.113.42|STATIC_V4=8.8.8.8|' -e 's|BR_V6=2001:db8:ffff::1|BR_V6=2001:0db8::1|' "$TMP/config/gateway.conf" >"$TMP/config/padded-rfc3849.env"
test_start 'padded RFC 3849 bridge IPv6 fails without override'
assert_failure validate_main_file "$TMP/config/padded-rfc3849.env"
V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES
v6_load_main_config "$TMP/config/gateway.conf" "$TMP/config/routed-networks.conf"
test_start 'RFC documentation addresses pass with test override'
assert_success v6_validate_main_config

atomic_write_value() { printf '%s\n' payload | v6_write_atomic 600 "$1"; }

mkdir "$TMP/atomic-state"
chmod 700 "$TMP/atomic-state"
V6PLUS_STATE_DIR=$TMP/atomic-state
export V6PLUS_STATE_DIR
printf 'outside-original\n' >"$TMP/outside-target"
ln -s "$TMP/outside-target" "$V6PLUS_STATE_DIR/value.tmp.$$"
test_start 'atomic writer rejects prepositioned temp symlink'
assert_failure atomic_write_value "$V6PLUS_STATE_DIR/value"
test_start 'atomic writer never follows prepositioned temp symlink'
assert_eq "$(cat "$TMP/outside-target")" 'outside-original'
rm -f "$V6PLUS_STATE_DIR/value.tmp.$$" "$V6PLUS_STATE_DIR/value"

chmod 755 "$V6PLUS_STATE_DIR"
test_start 'atomic writer rejects state directory with unsafe mode'
assert_failure atomic_write_value "$V6PLUS_STATE_DIR/value"
chmod 700 "$V6PLUS_STATE_DIR"

mkdir "$TMP/atomic-real"
chmod 700 "$TMP/atomic-real"
ln -s "$TMP/atomic-real" "$TMP/atomic-link"
V6PLUS_STATE_DIR=$TMP/atomic-link
export V6PLUS_STATE_DIR
test_start 'atomic writer rejects symlink state directory'
assert_failure atomic_write_value "$V6PLUS_STATE_DIR/value"

test_finish
