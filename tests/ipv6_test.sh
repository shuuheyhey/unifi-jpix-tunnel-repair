#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"
. "$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh"
TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/v6plus-ipv6-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
CHILD_ENV_LOG=$TMP/child.env
: >"$CHILD_ENV_LOG"
export CHILD_ENV_LOG
PATH=$ROOT/tests/stubs/update:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/usr/bin:/bin
export PATH
V6_IP_CMD="$ROOT/tests/stubs/ip-route-source"
export V6_IP_CMD

missing_src_ip() {
  printf '2001:db8:ffff::1 via fe80::1 dev eth9 metric 1024\n'
}

route_source_no_args_survives_nounset() {
  (
    set -u
    if v6_route_source_v6 2>&1; then
      return 1
    fi
    printf 'survived\n'
  )
}

compose_one_arg_survives_nounset() {
  (
    set -u
    if v6_compose_local_v6 '2001:db8::1' 2>&1; then
      return 1
    fi
    printf 'survived\n'
  )
}

test_start 'extracts kernel-selected source for BR route'
assert_eq "$(v6_route_source_v6 '2001:db8:ffff::1')" '2001:db8:1234:30:abcd::1'

test_start 'rejects route output without src instead of composing an unselected source'
V6_IP_CMD=missing_src_ip
assert_failure v6_route_source_v6 '2001:db8:ffff::1'
V6_IP_CMD="$ROOT/tests/stubs/ip-route-source"

test_start 'route source missing an argument returns failure without exiting under nounset'
assert_eq "$(route_source_no_args_survives_nounset)" 'survived'

test_start 'composition missing an IID returns failure without exiting under nounset'
assert_eq "$(compose_one_arg_survives_nounset)" 'survived'

test_start 'keeps route-selected upper 64 bits instead of delegated /56 base'
assert_eq "$(v6_compose_local_v6 '2001:db8:1234:30:abcd::1' '00cb:0071:2a00:0000')" \
  '2001:0db8:1234:0030:00cb:0071:2a00:0000'

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
export source_full iid_full iid output source_prefix iid_suffix v6_route_output
export v6_compose_iid v6_compose_source_full v6_compose_iid_full
export v6_compose_source_prefix v6_compose_iid_suffix
: >"$CHILD_ENV_LOG"
test_start 'route helper works with inherited exported scratch names'
assert_eq "$(v6_route_source_v6 '2001:db8:ffff::1')" '2001:db8:1234:30:abcd::1'
test_start 'compose helper works with inherited exported scratch names'
assert_eq "$(v6_compose_local_v6 '2001:db8:1234:30:abcd::1' '00cb:0071:2a00:0000')" \
  '2001:0db8:1234:0030:00cb:0071:2a00:0000'
test_start 'expand helper works with inherited exported scratch names'
assert_eq "$(v6_expand_ipv6 '2001:db8:1234:30:abcd::1')" \
  '2001:0db8:1234:0030:abcd:0000:0000:0001'
for helper_child in ip awk cut; do
  test_start "$helper_child is observed during direct IPv6 helper calls"
  assert_contains "$(cat "$CHILD_ENV_LOG")" "--- $helper_child ---"
done
for helper_secret in sentinel-source-full sentinel-iid-full sentinel-iid sentinel-output \
  sentinel-source-prefix sentinel-iid-suffix sentinel-route-output sentinel-compose-iid \
  sentinel-compose-source-full sentinel-compose-iid-full sentinel-compose-source-prefix \
  sentinel-compose-iid-suffix 2001:0db8:1234:0030:abcd:0000:0000:0001 \
  2001:0db8:1234:0030:00cb:0071:2a00:0000; do
  test_start "direct helper child environments exclude <$helper_secret>"
  if grep -F "$helper_secret" "$CHILD_ENV_LOG" >/dev/null 2>&1; then
    fail 'IPv6 helper scratch leaked through inherited environment'
  else
    pass
  fi
done
unset source_full iid_full iid output source_prefix iid_suffix v6_route_output
unset v6_compose_iid v6_compose_source_full v6_compose_iid_full
unset v6_compose_source_prefix v6_compose_iid_suffix

test_start 'expands leading compression instead of dropping zero hextets'
assert_eq "$(v6_expand_ipv6 '::1')" '0000:0000:0000:0000:0000:0000:0000:0001'

test_start 'expands middle compression instead of miscounting zero hextets'
assert_eq "$(v6_expand_ipv6 '2001:db8::abcd:1')" '2001:0db8:0000:0000:0000:0000:abcd:0001'

test_start 'strips zone and prefix then lowercases uppercase hextets'
assert_eq "$(v6_expand_ipv6 '2001:DB8::A%eth9/64')" '2001:0db8:0000:0000:0000:0000:0000:000a'

test_start 'rejects embedded newlines instead of emitting multiple expanded addresses'
assert_failure v6_expand_ipv6 '2001:db8::1
2001:db8::2'

test_start 'rejects multiple compression markers instead of accepting ambiguous IPv6'
assert_failure v6_expand_ipv6 '2001::db8::1'

test_start 'rejects empty uncompressed hextets instead of silently omitting one'
assert_failure v6_expand_ipv6 '2001:db8:0:0:0:0:0:'

test_start 'rejects non-hex hextets instead of emitting invalid expanded IPv6'
assert_failure v6_expand_ipv6 '2001:db8::gggg'

test_start 'rejects over-four-character hextets instead of truncating IPv6'
assert_failure v6_expand_ipv6 '2001:db8::12345'

test_start 'rejects uncompressed IPv6 with the wrong hextet count'
assert_failure v6_expand_ipv6 '2001:db8:0:0:0:0:1'

test_start 'rejects compressed IPv6 with too many explicit hextets'
assert_failure v6_expand_ipv6 '1:2:3:4:5:6:7:8::'

test_start 'rejects IID longer than four hextets instead of changing the /64 suffix width'
assert_failure v6_compose_local_v6 '2001:db8:1234:30::1' '1:2:3:4:5'

test_start 'rejects IID shorter than four hextets instead of padding an incomplete suffix'
assert_failure v6_compose_local_v6 '2001:db8:1234:30::1' '1:2:3'

test_finish
