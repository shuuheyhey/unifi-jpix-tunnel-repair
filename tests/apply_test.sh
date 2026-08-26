#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/unifi-jpix-tunnel-repair-apply-test.$$
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || :; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

APPLY_PATH=$ROOT/tests/stubs/apply:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
LOCAL_V6=2001:0db8:1234:0020:00cb:0071:2a00:0000
NEXT_LOCAL_V6=2001:0db8:1234:0021:00cb:0071:2a00:0000
export V6PLUS_ALLOW_DOCUMENTATION_ADDRESSES=1
export V6PLUS_ALLOW_NONROOT=1
export V6PLUS_LIB="$ROOT/scripts/unifi-jpix-tunnel-repair-lib.sh"
export V6PLUS_ROOT="$ROOT"
export V6PLUS_NOW=1724241600
export V6PLUS_TEST_PLATFORM_VERIFIED=1

write_config() {
  outer=$1
  cat >"$CONFIG/gateway.conf" <<EOF
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
OUTER_IPIP_ALLOW=$outer
EOF
}

write_two_networks() {
  cat >"$CONFIG/routed-networks.conf" <<'EOF'
br0 192.168.20.0/24
br10 192.168.10.0/24
EOF
}

new_case() {
  CASE=$TMP/$1
  CONFIG=$CASE/config
  STATE=$CASE/runtime-state
  STUB_STATE_DIR=$CASE/stub-state
  STUB_LOG=$CASE/calls.log
  V6PLUS_STATE_DIR=$STATE
  V6PLUS_LOCK_DIR=$CASE/shared.lock
  export CONFIG STATE STUB_STATE_DIR STUB_LOG V6PLUS_STATE_DIR V6PLUS_LOCK_DIR
  unset STUB_FAIL_RULE_PREF V6PLUS_TEST_FAIL_JOURNAL_TYPE V6PLUS_TEST_FAIL_OFF_REMOVE
  unset V6PLUS_TEST_SIGNAL_AFTER_STATE_REMOVE V6PLUS_TEST_SIGNAL_DURING_LOCK
  unset V6_IPTABLES_SAVE_CMD V6_IP6TABLES_SAVE_CMD
  mkdir -p "$CONFIG" "$STATE" "$STUB_STATE_DIR"
  chmod 700 "$STATE"
  cp "$ROOT/tests/fixtures/apply/original.state" "$STUB_STATE_DIR/tunnel.state"
  printf 'ip6tnl1|192.0.0.2/29\n' >"$STUB_STATE_DIR/addr4.state"
  : >"$STUB_STATE_DIR/addr6.state"
  : >"$STUB_STATE_DIR/routes.state"
  : >"$STUB_STATE_DIR/rules.state"
  cat >"$STUB_STATE_DIR/links.state" <<'EOF'
eth9|yes|1500
br0|yes|1500
br10|yes|1500
eth0|yes|1500
EOF
  printf '2001:db8:1234:30:abcd::1\n' >"$STUB_STATE_DIR/route6.source"
  printf '2001:db8:1234:20::\n' >"$STUB_STATE_DIR/endpoint6.prefix"
  cat >"$STUB_STATE_DIR/iptables.chains" <<'EOF'
nat|UBIOS_POSTROUTING_USER_HOOK
nat|UBIOS_POSTROUTING_JUMP
nat|POSTROUTING
mangle|FORWARD
mangle|OUTPUT
EOF
  : >"$STUB_STATE_DIR/iptables.state"
  printf 'UBIOS_INPUT_USER_HOOK\nUBIOS_INPUT_JUMP\nINPUT\n' >"$STUB_STATE_DIR/ip6tables.chains"
  printf '%s\n' '-A UBIOS_POSTROUTING_JUMP -j UBIOS_POSTROUTING_USER_HOOK' >"$STUB_STATE_DIR/nat-parent.rules"
  printf '%s\n' '-A UBIOS_INPUT_JUMP -j UBIOS_INPUT_USER_HOOK' >"$STUB_STATE_DIR/v6-parent.rules"
  : >"$STUB_STATE_DIR/ip6tables.state"
  : >"$STUB_STATE_DIR/ip6tables-extra.state"
  : >"$STUB_STATE_DIR/services.active"
  : >"$STUB_LOG"
  write_config yes
  write_two_networks
}

run_apply() {
  RUN_OUTPUT=$CASE/output
  RUN_ERROR=$CASE/error
  : >"$RUN_OUTPUT"
  : >"$RUN_ERROR"
  set +e
  PATH=$APPLY_PATH "$ROOT/scripts/unifi-jpix-tunnel-repair-apply.sh" --config "$CONFIG" "$@" >"$RUN_OUTPUT" 2>"$RUN_ERROR"
  RUN_STATUS=$?
  set -e
}

assert_run_success() {
  test_start "$1"
  if [ "$RUN_STATUS" -eq 0 ]; then pass; else fail "exit $RUN_STATUS: stdout=$(cat "$RUN_OUTPUT") stderr=$(cat "$RUN_ERROR")"; fi
}

assert_run_failure() {
  test_start "$1"
  if [ "$RUN_STATUS" -ne 0 ]; then pass; else fail 'command unexpectedly passed'; fi
}

assert_not_contains() {
  case $1 in *"$2"*) fail "unexpected <$2> in <$1>" ;; *) pass ;; esac
}

physical_state() {
  for state_file in tunnel.state addr4.state addr6.state routes.state rules.state iptables.state ip6tables.state ip6tables-extra.state; do
    printf '[%s]\n' "$state_file"
    if [ -f "$STUB_STATE_DIR/$state_file" ]; then cat "$STUB_STATE_DIR/$state_file"; else printf '<absent>\n'; fi
  done
}

runtime_state() {
  for state_file in original-tunnel.env managed-networks last-apply.env; do
    if [ -f "$STATE/$state_file" ]; then
      printf '[%s]\n' "$state_file"
      cat "$STATE/$state_file"
    fi
  done
}

mutation_log_after() {
  mutation_start=$1
  awk -v start="$mutation_start" '
    NR <= start { next }
    /^ip / && ($0 ~ / -[46] addr (replace|del) / || $0 ~ / -4 route (replace|del) / ||
      $0 ~ / -4 rule (add|del) / || $0 ~ / -6 tunnel change / || $0 ~ / link set /) { print; next }
    /^iptables / && $0 ~ / -[ADI] / { print; next }
    /^ip6tables / && $0 ~ / -[ADI] / { print; next }
  ' "$STUB_LOG"
}

install_interleaved_firewall_duplicates() {
  cat >"$STUB_STATE_DIR/iptables.state" <<EOF
nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.1.0.0/16 -j ACCEPT
nat|UBIOS_POSTROUTING_USER_HOOK|-s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.2.0.0/16 -j DROP
nat|UBIOS_POSTROUTING_USER_HOOK|-s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
nat|UBIOS_POSTROUTING_USER_HOOK|-s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.3.0.0/16 -j RETURN
mangle|FORWARD|-o eth0 -j ACCEPT
mangle|FORWARD|-o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
mangle|FORWARD|-i eth0 -j DROP
mangle|FORWARD|-o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
mangle|FORWARD|-i ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
mangle|OUTPUT|-o eth0 -j ACCEPT
mangle|OUTPUT|-o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
mangle|OUTPUT|-o eth1 -j DROP
EOF
  cat >"$STUB_STATE_DIR/ip6tables.state" <<EOF
UBIOS_INPUT_USER_HOOK|-s 2001:db8:aaaa::1/128 -j ACCEPT
UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT
UBIOS_INPUT_USER_HOOK|-s 2001:db8:bbbb::1/128 -j DROP
UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT
INPUT|-s 2001:db8:cccc::1/128 -j ACCEPT
EOF
}

assert_rejected_unchanged() {
  label=$1
  before_physical=$(physical_state)
  before_runtime=$(runtime_state)
  run_apply apply
  test_start "$label is rejected"
  if [ "$RUN_STATUS" -ne 0 ]; then pass; else fail 'apply unexpectedly passed'; fi
  test_start "$label performs no physical mutation"
  assert_eq "$(physical_state)" "$before_physical"
  test_start "$label performs no runtime-state mutation"
  assert_eq "$(runtime_state)" "$before_runtime"
}

assert_inventory_rejected_before_mutation() {
  inventory_label=$1
  inventory_before_physical=$(physical_state)
  inventory_before_runtime=$(runtime_state)
  inventory_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
  run_apply apply
  assert_run_failure "$inventory_label is rejected"
  test_start "$inventory_label reports the preflight phase"
  assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=preflight'
  test_start "$inventory_label invokes no mutation command"
  assert_eq "$(mutation_log_after "$inventory_log_lines")" ''
  test_start "$inventory_label preserves physical and runtime state"
  assert_eq "$(physical_state)$(runtime_state)" "$inventory_before_physical$inventory_before_runtime"
}

new_case unverified-platform
unset V6PLUS_TEST_PLATFORM_VERIFIED
assert_rejected_unchanged 'unverified platform tuple'
V6PLUS_TEST_PLATFORM_VERIFIED=1
export V6PLUS_TEST_PLATFORM_VERIFIED

new_case underlay-too-small
sed 's/^eth9|yes|1500$/eth9|yes|1499/' "$STUB_STATE_DIR/links.state" >"$STUB_STATE_DIR/links.tmp"
mv "$STUB_STATE_DIR/links.tmp" "$STUB_STATE_DIR/links.state"
assert_rejected_unchanged 'tunnel MTU plus IPv6 outer header larger than underlay MTU'

for unsafe_tunnel_attribute in 'dev eth9' 'fwmark 0x1' 'mystery value'; do
  new_case "unsafe-tunnel-$(printf '%s' "$unsafe_tunnel_attribute" | tr ' ' '-')"
  printf 'ip6tnl1: any/ipv6 remote 2001:db8:ffff::1 local 2001:db8:1234:20:cb:71:2a00:0 %s\n' \
    "$unsafe_tunnel_attribute" >"$STUB_STATE_DIR/tunnel.show-output"
  assert_rejected_unchanged "unsupported tunnel attribute <$unsafe_tunnel_attribute>"
done

for nat_parent_mode in missing duplicate detached; do
  new_case "nat-parent-$nat_parent_mode"
  case $nat_parent_mode in
    missing) : >"$STUB_STATE_DIR/nat-parent.rules" ;;
    duplicate) printf '%s\n%s\n' '-A UBIOS_POSTROUTING_JUMP -j UBIOS_POSTROUTING_USER_HOOK' '-A UBIOS_POSTROUTING_JUMP -j UBIOS_POSTROUTING_USER_HOOK' >"$STUB_STATE_DIR/nat-parent.rules" ;;
    detached) printf '%s\n' '-A UBIOS_POSTROUTING_JUMP -j SOME_OTHER_CHAIN' >"$STUB_STATE_DIR/nat-parent.rules" ;;
  esac
  assert_rejected_unchanged "$nat_parent_mode UniFi NAT parent jump"
done

for v6_parent_mode in missing duplicate detached; do
  new_case "v6-parent-$v6_parent_mode"
  case $v6_parent_mode in
    missing) : >"$STUB_STATE_DIR/v6-parent.rules" ;;
    duplicate) printf '%s\n%s\n' '-A UBIOS_INPUT_JUMP -j UBIOS_INPUT_USER_HOOK' '-A UBIOS_INPUT_JUMP -j UBIOS_INPUT_USER_HOOK' >"$STUB_STATE_DIR/v6-parent.rules" ;;
    detached) printf '%s\n' '-A UBIOS_INPUT_JUMP -j SOME_OTHER_CHAIN' >"$STUB_STATE_DIR/v6-parent.rules" ;;
  esac
  assert_rejected_unchanged "$v6_parent_mode UniFi IPv6 input parent jump"
done

# Case 1: exact two-VLAN convergence, snapshot, router route, and modes.
new_case two-vlans
run_apply apply
assert_run_success 'two-VLAN apply converges'
test_start 'apply derives the endpoint from ENDPOINT_IF instead of BR route source'
assert_contains "$(cat "$STUB_STATE_DIR/tunnel.state")" 'TUN_LOCAL=2001:0db8:1234:0020:00cb:0071:2a00:0000'
test_start 'original UniFi tunnel snapshot is exact'
assert_eq "$(cat "$STATE/original-tunnel.env")" "$(cat "$ROOT/tests/fixtures/apply/original.state")"
test_start 'original snapshot is private'
assert_eq "$(stat -c %a "$STATE/original-tunnel.env")" 600
test_start 'managed set is normalized in file order with exact preferences'
assert_eq "$(cat "$STATE/managed-networks")" "br0|192.168.20.0/24|10000
br10|192.168.10.0/24|10001"
test_start 'managed set is private'
assert_eq "$(stat -c %a "$STATE/managed-networks")" 600
test_start 'last apply records exact managed outer state'
assert_eq "$(cat "$STATE/last-apply.env")" "LOCAL_V6=$LOCAL_V6
NAT_CHAIN=UBIOS_POSTROUTING_USER_HOOK
V6_INPUT_CHAIN=UBIOS_INPUT_USER_HOOK
V6_INPUT_MANAGED=yes
APPLIED_AT=1724241600"
test_start 'last apply state is private'
assert_eq "$(stat -c %a "$STATE/last-apply.env")" 600
test_start 'tunnel endpoint MTU and link are converged'
assert_eq "$(cat "$STUB_STATE_DIR/tunnel.state")" "TUN_IF=ip6tnl1
TUN_MODE=ipip6
TUN_LOCAL=$LOCAL_V6
TUN_REMOTE=2001:db8:ffff::1
TUN_IPV4=192.0.0.2/29
TUN_MTU=1460
TUN_UP=yes"
test_start 'WAN endpoint is an exact host address'
assert_eq "$(cat "$STUB_STATE_DIR/addr6.state")" "eth9|$LOCAL_V6/128"
test_start 'original tunnel prefix is replaced by fixed host address'
assert_eq "$(cat "$STUB_STATE_DIR/addr4.state")" 'ip6tnl1|203.0.113.42/32'
test_start 'default and connected routes are exact'
assert_eq "$(cat "$STUB_STATE_DIR/routes.state")" "300|default|ip6tnl1
300|192.168.20.0/24|br0
300|192.168.10.0/24|br10"
test_start 'policy rules use the reserved ordered preferences'
assert_eq "$(cat "$STUB_STATE_DIR/rules.state")" "10000|192.168.20.0/24|br0|300
10001|192.168.10.0/24|br10|300"
test_start 'policy rules are source and ingress-interface scoped'
assert_contains "$(cat "$STUB_LOG")" 'ip -4 rule add pref 10000 from 192.168.20.0/24 iif br0 lookup 300'
test_start 'SNAT and three MSS rules include the exact management tag'
assert_eq "$(cat "$STUB_STATE_DIR/iptables.state")" "nat|UBIOS_POSTROUTING_USER_HOOK|-s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
nat|UBIOS_POSTROUTING_USER_HOOK|-s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
mangle|FORWARD|-o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
mangle|FORWARD|-i ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
mangle|OUTPUT|-o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420"
test_start 'outer protocol-4 accept is narrowly tagged'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" "UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT"
test_start 'router-originated probe uses tunnel and fixed source'
assert_contains "$(PATH=$APPLY_PATH ip -4 route get 192.0.2.1)" 'dev ip6tnl1 src 203.0.113.42'
test_start 'iptables ensure checks exact membership before append'
assert_contains "$(cat "$STUB_LOG")" "iptables -t nat -C UBIOS_POSTROUTING_USER_HOOK -s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
iptables -t nat -A UBIOS_POSTROUTING_USER_HOOK -s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42"

# Native UniFi creates an any-over-IPv6 tunnel. Applying must narrow it to
# IPv4-over-IPv6, while rollback/off must retain a command-safe original mode.
new_case native-any-over-ipv6
sed 's/^TUN_MODE=.*/TUN_MODE=any\/ipv6/' "$STUB_STATE_DIR/tunnel.state" >"$STUB_STATE_DIR/tunnel.tmp"
mv "$STUB_STATE_DIR/tunnel.tmp" "$STUB_STATE_DIR/tunnel.state"
run_apply apply
assert_run_success 'native any-over-IPv6 tunnel converges to fixed IPv4-over-IPv6'
test_start 'native display mode snapshot is normalized to the restorable any command mode'
assert_contains "$(cat "$STATE/original-tunnel.env")" 'TUN_MODE=any'
test_start 'native any-over-IPv6 tunnel is narrowed during apply'
assert_contains "$(cat "$STUB_STATE_DIR/tunnel.state")" 'TUN_MODE=ipip6'
run_apply off
assert_run_success 'off restores a native any-over-IPv6 tunnel'
test_start 'off restores the command-safe native mode'
assert_contains "$(cat "$STUB_STATE_DIR/tunnel.state")" 'TUN_MODE=any'

new_case post-apply-ip-over-ipv6
run_apply apply
assert_run_success 'post-apply display fixture first converges'
sed 's/^TUN_MODE=.*/TUN_MODE=ip\/ipv6/' "$STUB_STATE_DIR/tunnel.state" >"$STUB_STATE_DIR/tunnel.tmp"
mv "$STUB_STATE_DIR/tunnel.tmp" "$STUB_STATE_DIR/tunnel.state"
post_apply_before=$(physical_state)
run_apply apply
assert_run_success 'Linux ip-over-IPv6 display mode is accepted on a later apply'
test_start 'normalized post-apply display mode causes no physical mutation'
assert_eq "$(physical_state)" "$post_apply_before"

# Case 2: a second apply is state-idempotent and does not duplicate rules.
before_second=$(physical_state)
touch -t 200001010000 "$STATE/managed-networks" "$STATE/last-apply.env"
before_second_runtime=$(runtime_state)
before_second_managed_mtime=$(stat -c %Y "$STATE/managed-networks")
before_second_last_mtime=$(stat -c %Y "$STATE/last-apply.env")
V6PLUS_NOW=1724249999
export V6PLUS_NOW
run_apply apply
assert_run_success 'second apply converges idempotently'
test_start 'second apply preserves serialized physical state'
assert_eq "$(physical_state)" "$before_second"
test_start 'second apply preserves serialized runtime state'
assert_eq "$(runtime_state)" "$before_second_runtime"
test_start 'no-op apply preserves managed state mtime'
assert_eq "$(stat -c %Y "$STATE/managed-networks")" "$before_second_managed_mtime"
test_start 'no-op apply preserves last state mtime and APPLIED_AT'
assert_eq "$(stat -c %Y "$STATE/last-apply.env")" "$before_second_last_mtime"
V6PLUS_NOW=1724241600
export V6PLUS_NOW

# Case 3: stale allowlist entries are deleted exactly and unknowns survive.
printf '20000|10.0.0.0/8|user0|main\n' >>"$STUB_STATE_DIR/rules.state"
printf 'nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.0.0.0/8 -j ACCEPT\n' >>"$STUB_STATE_DIR/iptables.state"
printf 'br0 192.168.20.0/24\n' >"$CONFIG/routed-networks.conf"
run_apply apply
assert_run_success 'stale VLAN removal converges'
test_start 'stale connected route alone is removed'
assert_eq "$(cat "$STUB_STATE_DIR/routes.state")" "300|default|ip6tnl1
300|192.168.20.0/24|br0"
test_start 'stale policy rule is removed while unrelated user rule remains'
assert_eq "$(cat "$STUB_STATE_DIR/rules.state")" "10000|192.168.20.0/24|br0|300
20000|10.0.0.0/8|user0|main"
test_start 'stale SNAT is removed while unrelated firewall rule remains'
assert_contains "$(cat "$STUB_STATE_DIR/iptables.state")" 'nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.0.0.0/8 -j ACCEPT'
test_start 'removed VLAN SNAT no longer exists'
assert_not_contains "$(cat "$STUB_STATE_DIR/iptables.state")" '192.168.10.0/24'

# Case 4: a mid-policy failure rolls back only this invocation.
new_case rollback
printf 'br0 192.168.20.0/24\n' >"$CONFIG/routed-networks.conf"
run_apply apply
assert_run_success 'rollback fixture first apply converges'
rollback_physical=$(physical_state)
rollback_runtime=$(runtime_state)
write_two_networks
STUB_FAIL_RULE_PREF=10001
export STUB_FAIL_RULE_PREF
run_apply apply
unset STUB_FAIL_RULE_PREF
assert_run_failure 'second policy rule failure is surfaced'
test_start 'failed invocation restores the exact prior physical state'
assert_eq "$(physical_state)" "$rollback_physical"
test_start 'failed invocation preserves the exact prior managed state'
assert_eq "$(runtime_state)" "$rollback_runtime"
test_start 'failed invocation releases its owned lock'
if [ ! -e "$V6PLUS_LOCK_DIR" ]; then pass; else fail 'lock directory remains'; fi

# Case 5: dry-run emits a plan but writes no physical or runtime state.
new_case dry-run
dry_physical=$(physical_state)
run_apply --dry-run apply
assert_run_success 'dry-run validates and prints a plan'
test_start 'dry-run performs zero physical writes'
assert_eq "$(physical_state)" "$dry_physical"
test_start 'dry-run creates no runtime-state file'
assert_eq "$(find "$STATE" -mindepth 1 -print)" ''
dry_output=$(cat "$RUN_OUTPUT")
test_start 'dry-run output includes a redacted planned mutation shape'
assert_contains "$dry_output" '[dry-run] ip -6 addr replace [LOCAL_V6]/128 dev eth9'
test_start 'dry-run output hides fixed IPv4'
assert_not_contains "$dry_output" '203.0.113.42'
test_start 'dry-run output hides BR IPv6'
assert_not_contains "$dry_output" '2001:db8:ffff::1'
test_start 'dry-run output hides derived local IPv6'
assert_not_contains "$dry_output" "$LOCAL_V6"

# Case 6: off refuses active automation, then restores the immutable snapshot.
new_case off
run_apply apply
assert_run_success 'off fixture apply converges'
printf '25000|10.0.0.0/8|user0|main\n' >>"$STUB_STATE_DIR/rules.state"
printf 'nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.0.0.0/8 -j ACCEPT\n' >>"$STUB_STATE_DIR/iptables.state"
printf 'UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d %s/128 -p 4 -j ACCEPT\n' "$LOCAL_V6" >>"$STUB_STATE_DIR/ip6tables.state"
printf 'unifi-jpix-tunnel-repair-watch.service\n' >"$STUB_STATE_DIR/services.active"
off_before=$(physical_state)
run_apply off
assert_run_failure 'off refuses while an automation service is active'
test_start 'refused off performs no mutation'
assert_eq "$(physical_state)" "$off_before"
: >"$STUB_STATE_DIR/services.active"
run_apply off
assert_run_success 'off restores after all automation units stop'
test_start 'off restores exact original tunnel fields'
assert_eq "$(cat "$STUB_STATE_DIR/tunnel.state")" "$(cat "$ROOT/tests/fixtures/apply/original.state")"
test_start 'off restores exact original IPv4 prefix'
assert_eq "$(cat "$STUB_STATE_DIR/addr4.state")" 'ip6tnl1|192.0.0.2/29'
test_start 'off removes managed WAN endpoint'
assert_eq "$(cat "$STUB_STATE_DIR/addr6.state")" ''
test_start 'off preserves unrelated policy rule'
assert_eq "$(cat "$STUB_STATE_DIR/rules.state")" '25000|10.0.0.0/8|user0|main'
test_start 'off preserves unrelated IPv4 firewall rule'
assert_eq "$(cat "$STUB_STATE_DIR/iptables.state")" 'nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.0.0.0/8 -j ACCEPT'
test_start 'off preserves identical untagged IPv6 accept'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" "UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -j ACCEPT"
test_start 'off keeps immutable original snapshot'
assert_eq "$(cat "$STATE/original-tunnel.env")" "$(cat "$ROOT/tests/fixtures/apply/original.state")"
test_start 'off removes current managed state only'
if [ ! -e "$STATE/managed-networks" ] && [ ! -e "$STATE/last-apply.env" ]; then pass; else fail 'managed state remains'; fi
run_apply off
assert_run_success 'repeated off is repairable and idempotent'

# Case 7: status is read-only and detects drift.
new_case status
run_apply apply
assert_run_success 'status fixture apply converges'
status_before=$(physical_state)
run_apply status
assert_run_success 'healthy status returns success'
test_start 'healthy status performs no mutation'
assert_eq "$(physical_state)" "$status_before"
sed '/^300|default|ip6tnl1$/d' "$STUB_STATE_DIR/routes.state" >"$STUB_STATE_DIR/routes.tmp"
mv "$STUB_STATE_DIR/routes.tmp" "$STUB_STATE_DIR/routes.state"
drift_before=$(physical_state)
run_apply status
assert_run_failure 'status returns failure on route drift'
test_start 'drifted status prints a stable error invariant'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR route_default='
test_start 'drifted status remains read-only'
assert_eq "$(physical_state)" "$drift_before"

# Kernel IPv6 display may omit leading zeroes while the desired state is expanded.
# Both representations must be recognized as one converged endpoint.
new_case compressed-ipv6-kernel-output
run_apply apply
assert_run_success 'compressed IPv6 kernel fixture converges initially'
cat >"$STUB_STATE_DIR/addr6.show-output" <<'EOF'
    inet6 2001:db8:1234:20:cb:71:2a00:0/128 scope global
EOF
cat >"$STUB_STATE_DIR/tunnel.show-output" <<'EOF'
ip6tnl1: ipip6 remote 2001:db8:ffff::1 local 2001:db8:1234:20:cb:71:2a00:0
EOF
compressed_status_before=$(physical_state)
run_apply status
assert_run_success 'status accepts compressed IPv6 kernel endpoints'
test_start 'compressed IPv6 status performs no mutation'
assert_eq "$(physical_state)" "$compressed_status_before"
compressed_apply_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply apply
assert_run_success 'reapply accepts compressed IPv6 kernel endpoints'
test_start 'compressed IPv6 reapply performs no physical mutation'
assert_eq "$(mutation_log_after "$compressed_apply_log_lines")" ''

# Case 8: auto/no/yes outer semantics are distinct and exact.
new_case outer-auto
write_config auto
run_apply apply
assert_run_success 'auto outer mode converges without adding a rule'
test_start 'auto mode leaves IPv6 firewall unchanged'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" ''
test_start 'auto mode warns when exact accept is unconfirmed'
assert_contains "$(cat "$RUN_ERROR")" 'WARN outer_ipip=unconfirmed set OUTER_IPIP_ALLOW=yes only after traffic verification'
test_start 'auto mode records unmanaged outer state'
assert_contains "$(cat "$STATE/last-apply.env")" 'V6_INPUT_MANAGED=no'
write_config yes
run_apply apply
assert_run_success 'explicit yes adds the narrow tagged outer rule'
test_start 'yes mode adds only the exact tagged outer rule'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" "UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT"

new_case outer-no
write_config no
run_apply apply
assert_run_success 'explicit no converges without an outer rule'
test_start 'no mode records no input chain ownership'
assert_contains "$(cat "$STATE/last-apply.env")" 'V6_INPUT_CHAIN=none
V6_INPUT_MANAGED=no'

new_case outer-auto-existing
write_config auto
printf 'UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d %s/128 -p 4 -j ACCEPT\n' "$LOCAL_V6" >"$STUB_STATE_DIR/ip6tables.state"
run_apply apply
assert_run_success 'auto reuses a pre-existing exact untagged accept'
test_start 'auto does not tag or duplicate a user accept'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" "UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -j ACCEPT"

# Validation and ownership rejections all happen before mutation.
new_case collision-rule
printf '10001|192.168.10.0/24|other0|999\n' >"$STUB_STATE_DIR/rules.state"
assert_rejected_unchanged 'first-apply reserved preference collision'

new_case collision-table
printf '300|10.9.0.0/16|other0\n' >"$STUB_STATE_DIR/routes.state"
assert_rejected_unchanged 'first-apply non-empty route table collision'

new_case collision-tag
printf 'nat|UBIOS_POSTROUTING_USER_HOOK|-s 10.0.0.0/8 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >"$STUB_STATE_DIR/iptables.state"
assert_rejected_unchanged 'first-apply existing management tag collision'

new_case collision-address
printf 'eth9|%s/128\n' "$LOCAL_V6" >"$STUB_STATE_DIR/addr6.state"
assert_rejected_unchanged 'first-apply desired WAN address collision'

new_case static-conflict
printf 'eth0|203.0.113.42/24\n' >>"$STUB_STATE_DIR/addr4.state"
assert_rejected_unchanged 'static IPv4 address conflict'

new_case route-probe-mismatch
: >"$STUB_STATE_DIR/route4.mismatch"
assert_rejected_unchanged 'pre-existing router route-probe mismatch'

new_case wrong-tunnel-mode
sed 's/^TUN_MODE=.*/TUN_MODE=gre6/' "$STUB_STATE_DIR/tunnel.state" >"$STUB_STATE_DIR/tunnel.tmp"
mv "$STUB_STATE_DIR/tunnel.tmp" "$STUB_STATE_DIR/tunnel.state"
assert_rejected_unchanged 'wrong tunnel mode'

new_case missing-tunnel
rm "$STUB_STATE_DIR/tunnel.state"
assert_rejected_unchanged 'absent tunnel'

new_case empty-networks
: >"$CONFIG/routed-networks.conf"
assert_rejected_unchanged 'empty network list'

new_case duplicate-interface
printf 'br0 192.168.20.0/24\nbr0 192.168.61.0/24\n' >"$CONFIG/routed-networks.conf"
assert_rejected_unchanged 'duplicate network interface'

new_case duplicate-cidr
printf 'br0 192.168.20.0/24\nbr10 192.168.20.0/24\n' >"$CONFIG/routed-networks.conf"
assert_rejected_unchanged 'duplicate network CIDR'

new_case invalid-cidr
printf 'br0 192.168.20.0/33\n' >"$CONFIG/routed-networks.conf"
assert_rejected_unchanged 'invalid network CIDR'

new_case missing-link
printf 'br99 192.168.99.0/24\n' >"$CONFIG/routed-networks.conf"
assert_rejected_unchanged 'missing network link'

new_case preference-overflow
sed 's/^RULE_PREF_BASE=.*/RULE_PREF_BASE=32700/' "$CONFIG/gateway.conf" >"$CONFIG/v6plus.tmp"
mv "$CONFIG/v6plus.tmp" "$CONFIG/gateway.conf"
: >"$CONFIG/routed-networks.conf"
overflow_index=1
while [ "$overflow_index" -le 67 ]; do
  printf 'vlan%s 10.0.%s.0/24\n' "$overflow_index" "$overflow_index" >>"$CONFIG/routed-networks.conf"
  printf 'vlan%s|yes|1500\n' "$overflow_index" >>"$STUB_STATE_DIR/links.state"
  overflow_index=$((overflow_index + 1))
done
assert_rejected_unchanged 'policy preference overflow'

# Later apply trusts only strictly validated prior state.
new_case corrupt-managed-state
run_apply apply
assert_run_success 'corrupt managed-state fixture converges'
printf 'br0|192.168.20.0/24|not-a-number\n' >"$STATE/managed-networks"
assert_rejected_unchanged 'invalid later managed-network state'

new_case corrupt-last-state
run_apply apply
assert_run_success 'corrupt last-state fixture converges'
cat >"$STATE/last-apply.env" <<EOF
LOCAL_V6=$LOCAL_V6
NAT_CHAIN=UBIOS_POSTROUTING_USER_HOOK
V6_INPUT_CHAIN=UBIOS_INPUT_USER_HOOK
V6_INPUT_MANAGED=yes
APPLIED_AT=1724241600
UNEXPECTED=value
EOF
assert_rejected_unchanged 'unknown later state key'

new_case malicious-state
run_apply apply
assert_run_success 'malicious state fixture converges'
printf 'LOCAL_V6=$(touch %s/forbidden)\n' "$CASE" >"$STATE/last-apply.env"
assert_rejected_unchanged 'malicious later state value'
test_start 'later state is parsed as data and never executed'
if [ ! -e "$CASE/forbidden" ]; then pass; else fail 'state command substitution executed'; fi

# Endpoint transition converges new state first and removes old tagged identity only.
new_case endpoint-transition
run_apply apply
assert_run_success 'endpoint transition fixture converges'
printf 'UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d %s/128 -p 4 -j ACCEPT\n' "$LOCAL_V6" >>"$STUB_STATE_DIR/ip6tables.state"
printf '2001:db8:1234:21::\n' >"$STUB_STATE_DIR/endpoint6.prefix"
run_apply apply
assert_run_success 'endpoint transition converges atomically'
test_start 'new endpoint replaces old managed WAN host address'
assert_eq "$(cat "$STUB_STATE_DIR/addr6.state")" "eth9|$NEXT_LOCAL_V6/128"
test_start 'tunnel uses the new delegated endpoint prefix'
assert_contains "$(cat "$STUB_STATE_DIR/tunnel.state")" "TUN_LOCAL=$NEXT_LOCAL_V6"
test_start 'new tagged outer rule replaces only old tagged identity'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" "UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -j ACCEPT
UBIOS_INPUT_USER_HOOK|-s 2001:db8:ffff::1/128 -d $NEXT_LOCAL_V6/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT"
test_start 'endpoint transition persists new local endpoint'
assert_contains "$(cat "$STATE/last-apply.env")" "LOCAL_V6=$NEXT_LOCAL_V6"

# Fix round 1: admin-up UNKNOWN links are still administratively up.
new_case admin-up-unknown
printf 'UNKNOWN\n' >"$STUB_STATE_DIR/tunnel.link-state"
run_apply apply
assert_run_success 'admin-UP state UNKNOWN tunnel applies'
test_start 'admin-UP UNKNOWN tunnel snapshot records up'
assert_contains "$(cat "$STATE/original-tunnel.env")" 'TUN_UP=yes'
run_apply off
assert_run_success 'off restores admin-UP UNKNOWN tunnel'
test_start 'off keeps UNKNOWN-state tunnel administratively up'
assert_contains "$(cat "$STUB_STATE_DIR/tunnel.state")" 'TUN_UP=yes'

# Fix round 1: the durable journal must precede every mutation.
new_case journal-write-failure
journal_failure_physical=$(physical_state)
V6PLUS_TEST_FAIL_JOURNAL_TYPE=ORIGINAL_REMOVE
export V6PLUS_TEST_FAIL_JOURNAL_TYPE
run_apply apply
unset V6PLUS_TEST_FAIL_JOURNAL_TYPE
assert_run_failure 'journal write failure stops before first mutation'
test_start 'journal write failure preserves physical state'
assert_eq "$(physical_state)" "$journal_failure_physical"
test_start 'journal write failure creates no original or managed state'
assert_eq "$(find "$STATE" -mindepth 1 -print)" ''

new_case signal-after-first-mutation
signal_physical=$(physical_state)
printf 'ip -6 addr replace %s/128 dev eth9\n' "$LOCAL_V6" >"$STUB_STATE_DIR/signal-after.invocations"
run_apply apply
assert_run_failure 'signal after first mutation triggers rollback'
test_start 'signal rollback restores exact physical state'
assert_eq "$(physical_state)" "$signal_physical"
test_start 'signal rollback removes invocation-created original snapshot'
assert_eq "$(find "$STATE" -mindepth 1 -print)" ''
test_start 'signal rollback releases shared lock'
if [ ! -e "$V6PLUS_LOCK_DIR" ]; then pass; else fail 'lock directory remains after signal'; fi

# Fix round 1: failed or interrupted off restores both physical and runtime state.
new_case off-state-remove-failure
run_apply apply
assert_run_success 'off state-removal failure fixture converges'
off_failure_physical=$(physical_state)
off_failure_runtime=$(runtime_state)
V6PLUS_TEST_FAIL_OFF_REMOVE=last
export V6PLUS_TEST_FAIL_OFF_REMOVE
run_apply off
unset V6PLUS_TEST_FAIL_OFF_REMOVE
assert_run_failure 'off fails closed on partial state removal'
test_start 'failed off restores physical state'
assert_eq "$(physical_state)" "$off_failure_physical"
test_start 'failed off restores runtime state'
assert_eq "$(runtime_state)" "$off_failure_runtime"

new_case off-state-remove-signal
run_apply apply
assert_run_success 'off state-removal signal fixture converges'
off_signal_physical=$(physical_state)
off_signal_runtime=$(runtime_state)
V6PLUS_TEST_SIGNAL_AFTER_STATE_REMOVE=managed
export V6PLUS_TEST_SIGNAL_AFTER_STATE_REMOVE
run_apply off
unset V6PLUS_TEST_SIGNAL_AFTER_STATE_REMOVE
assert_run_failure 'signal during off state removal triggers rollback'
test_start 'signaled off restores physical state'
assert_eq "$(physical_state)" "$off_signal_physical"
test_start 'signaled off restores runtime state'
assert_eq "$(runtime_state)" "$off_signal_runtime"

# Fix round 1: every ownership/discovery inspection error fails closed.
new_case inspect-table-error
printf 'ip -4 route show table 300\n' >"$STUB_STATE_DIR/fail.invocations"
assert_rejected_unchanged 'target route-table inspection error'

new_case inspect-tag-error
printf 'iptables -t nat -S\n' >"$STUB_STATE_DIR/fail.invocations"
assert_rejected_unchanged 'management-tag inspection error'

new_case inspect-primary-chain-error
printf 'iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK\n' >"$STUB_STATE_DIR/fail.invocations"
assert_rejected_unchanged 'primary chain inspection error'

new_case inspect-fallback-chain-error
printf 'iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK\n' >"$STUB_STATE_DIR/absent.invocations"
printf 'iptables -t nat -S POSTROUTING\n' >"$STUB_STATE_DIR/fail.invocations"
assert_rejected_unchanged 'fallback chain inspection error'

new_case inspect-later-firewall-error
run_apply apply
assert_run_success 'later firewall inspection fixture converges'
later_inspection_physical=$(physical_state)
later_inspection_runtime=$(runtime_state)
printf 'iptables -t mangle -S\n' >"$STUB_STATE_DIR/fail.invocations"
run_apply apply
assert_run_failure 'later firewall inspection error fails closed'
test_start 'later inspection error preserves physical state'
assert_eq "$(physical_state)" "$later_inspection_physical"
test_start 'later inspection error preserves runtime state'
assert_eq "$(runtime_state)" "$later_inspection_runtime"

new_case transient-xtables-lock
printf '2|iptables -t nat -S\n' >"$STUB_STATE_DIR/lock-at.invocations"
run_apply apply
assert_run_success 'transient xtables lock during managed SNAT inspection is retried'
test_start 'managed NAT chain inspection ran again after lock contention'
assert_eq "$(grep -F -x -c -- 'iptables -t nat -S' "$STUB_LOG")" 4

new_case transient-xtables-mutation-lock
printf '%s\n' \
  '1|iptables -t nat -A UBIOS_POSTROUTING_USER_HOOK -s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42' \
  >"$STUB_STATE_DIR/lock-at.invocations"
run_apply apply
assert_run_success 'transient xtables lock during managed SNAT mutation is retried'
test_start 'managed SNAT mutation ran again after lock contention'
assert_eq "$(grep -F -x -c -- 'iptables -t nat -A UBIOS_POSTROUTING_USER_HOOK -s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42' "$STUB_LOG")" 2

# Fix round 1: later ownership is semantic, complete, and duplicate-aware.
new_case route-legal-attributes
run_apply apply
assert_run_success 'route attribute fixture converges'
: >"$STUB_STATE_DIR/route-show-extra"
run_apply apply
assert_run_success 'later ownership tolerates legal route attributes'

new_case conflicting-reserved-rule
run_apply apply
assert_run_success 'reserved-rule conflict fixture converges'
printf '10000|192.168.20.0/24|evil0|999\n' >>"$STUB_STATE_DIR/rules.state"
assert_rejected_unchanged 'extra conflicting rule at managed preference'

new_case canonical-firewall-output
run_apply apply
assert_run_success 'canonical firewall fixture converges'
: >"$STUB_STATE_DIR/firewall.canonicalize"
cat >"$STUB_STATE_DIR/ip6tables.s-output" <<EOF
-A UBIOS_INPUT_USER_HOOK -s 2001:db8:ffff::1/128 -d 2001:db8:1234:20:cb:71:2a00:0/128 -p ipencap -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT
EOF
run_apply apply
assert_run_success 'later ownership accepts canonical protocol spelling'

new_case duplicate-tagged-preflight
run_apply apply
assert_run_success 'duplicate tagged preflight fixture converges'
sed -n '1p' "$STUB_STATE_DIR/iptables.state" >>"$STUB_STATE_DIR/iptables.state"
assert_rejected_unchanged 'duplicate tagged rule during later ownership'

# Fix round 1: exact delete removes every exact managed duplicate.
new_case duplicate-tagged-off
run_apply apply
assert_run_success 'duplicate off fixture converges'
sed -n '1p' "$STUB_STATE_DIR/iptables.state" >>"$STUB_STATE_DIR/iptables.state"
sed -n '3p' "$STUB_STATE_DIR/iptables.state" >>"$STUB_STATE_DIR/iptables.state"
sed -n '1p' "$STUB_STATE_DIR/ip6tables.state" >>"$STUB_STATE_DIR/ip6tables.state"
run_apply off
assert_run_success 'off deletes all exact tagged duplicates'
test_start 'off leaves no tagged IPv4 duplicate'
assert_not_contains "$(cat "$STUB_STATE_DIR/iptables.state")" 'unifi-jpix-tunnel-repair'
test_start 'off leaves no tagged IPv6 duplicate'
assert_not_contains "$(cat "$STUB_STATE_DIR/ip6tables.state")" 'unifi-jpix-tunnel-repair'

# Fix round 1: reconcile chain and outer-policy transitions explicitly.
new_case nat-chain-transition
run_apply apply
assert_run_success 'NAT chain transition fixture converges'
printf 'iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK\n' >"$STUB_STATE_DIR/absent.invocations"
assert_rejected_unchanged 'missing UniFi NAT user hook after initial apply'

new_case outer-yes-to-auto
run_apply apply
assert_run_success 'yes-to-auto fixture converges'
write_config auto
run_apply apply
assert_run_success 'yes-to-auto transition converges'
test_start 'yes-to-auto warns after removing its own managed confirmation'
assert_contains "$(cat "$RUN_ERROR")" 'WARN outer_ipip=unconfirmed set OUTER_IPIP_ALLOW=yes only after traffic verification'
test_start 'yes-to-auto leaves no managed outer accept'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables.state")" ''

# Fix round 1: status reports material extra/drifted state.
new_case status-material-drift
run_apply apply
assert_run_success 'material status drift fixture converges'
printf 'ip6tnl1|198.51.100.77/32\n' >>"$STUB_STATE_DIR/addr4.state"
printf 'eth9|2001:0db8:1234:0029:00cb:0071:2a00:0000/128\n' >>"$STUB_STATE_DIR/addr6.state"
printf '300|10.77.0.0/16|evil0\n' >>"$STUB_STATE_DIR/routes.state"
printf '10000|192.168.20.0/24|evil0|999\n' >>"$STUB_STATE_DIR/rules.state"
sed -n '1p' "$STUB_STATE_DIR/iptables.state" >>"$STUB_STATE_DIR/iptables.state"
run_apply status
assert_run_failure 'status rejects extra addresses routes rules and duplicates'
status_drift_output=$(cat "$RUN_OUTPUT")
for drift_name in tunnel_ipv4_set obsolete_wan_address reserved_routes reserved_rules tagged_duplicates; do
  test_start "status reports $drift_name drift"
  assert_contains "$status_drift_output" "ERROR $drift_name="
done

new_case status-local-state-mismatch
run_apply apply
assert_run_success 'status local mismatch fixture converges'
printf '2001:db8:1234:21::\n' >"$STUB_STATE_DIR/endpoint6.prefix"
run_apply status
assert_run_failure 'status rejects freshly derived and recorded local mismatch'
test_start 'status reports recorded local mismatch explicitly'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR state_local='

# Fix round 1: interfaces and original tunnel mode are strict data.
new_case unsafe-config-interface
sed 's/^WAN_IF=.*/WAN_IF=eth9|injected/' "$CONFIG/gateway.conf" >"$CONFIG/v6plus.tmp"
mv "$CONFIG/v6plus.tmp" "$CONFIG/gateway.conf"
unsafe_config_physical=$(physical_state)
run_apply apply
test_start 'unsafe configured interface is a configuration error'
assert_eq "$RUN_STATUS" 2
test_start 'unsafe configured interface performs no mutation'
assert_eq "$(physical_state)" "$unsafe_config_physical"

new_case overlong-config-interface
sed 's/^TUN_IF=.*/TUN_IF=interface-name-too-long/' "$CONFIG/gateway.conf" >"$CONFIG/v6plus.tmp"
mv "$CONFIG/v6plus.tmp" "$CONFIG/gateway.conf"
run_apply apply
test_start 'overlong configured interface is rejected'
assert_eq "$RUN_STATUS" 2

new_case unsafe-original-mode
run_apply apply
assert_run_success 'unsafe original mode fixture converges'
sed 's/^TUN_MODE=.*/TUN_MODE=gre6/' "$STATE/original-tunnel.env" >"$STATE/original.tmp"
mv "$STATE/original.tmp" "$STATE/original-tunnel.env"
unsafe_mode_physical=$(physical_state)
run_apply off
assert_run_failure 'off rejects non-ipip6 original snapshot mode'
test_start 'invalid original mode is never executed'
assert_eq "$(physical_state)" "$unsafe_mode_physical"

# Fix round 1: first-apply rollback removes its invocation-created snapshot.
new_case first-apply-complete-rollback
first_rollback_physical=$(physical_state)
STUB_FAIL_RULE_PREF=10001
export STUB_FAIL_RULE_PREF
run_apply apply
unset STUB_FAIL_RULE_PREF
assert_run_failure 'first apply mid-policy failure rolls back'
test_start 'first apply rollback restores original physical state'
assert_eq "$(physical_state)" "$first_rollback_physical"
test_start 'first apply complete rollback removes original snapshot and state'
assert_eq "$(find "$STATE" -mindepth 1 -print)" ''

# Fix round 1: system inspection and lock acquisition signals fail safely.
new_case systemctl-inspection-error
run_apply apply
assert_run_success 'systemctl error fixture converges'
systemctl_error_physical=$(physical_state)
systemctl_error_runtime=$(runtime_state)
printf 'unifi-jpix-tunnel-repair-watch.service\n' >"$STUB_STATE_DIR/systemctl.fail"
run_apply off
assert_run_failure 'off blocks on systemctl inspection error'
test_start 'systemctl inspection error preserves physical state'
assert_eq "$(physical_state)" "$systemctl_error_physical"
test_start 'systemctl inspection error preserves runtime state'
assert_eq "$(runtime_state)" "$systemctl_error_runtime"

new_case lock-acquisition-signal
V6PLUS_TEST_SIGNAL_DURING_LOCK=1
export V6PLUS_TEST_SIGNAL_DURING_LOCK
run_apply --dry-run apply
unset V6PLUS_TEST_SIGNAL_DURING_LOCK
assert_run_failure 'signal during lock acquisition exits nonzero'
test_start 'signal during lock acquisition leaves no owned lock'
if [ ! -e "$V6PLUS_LOCK_DIR" ]; then pass; else fail 'lock directory remains after acquisition signal'; fi

# Fix round 2 A: dry-run read probes are tri-state and fail closed.
new_case dry-inspect-address
dry_inspect_physical=$(physical_state)
dry_inspect_runtime=$(runtime_state)
printf '2|ip -6 addr show dev eth9\n' >"$STUB_STATE_DIR/fail-at.invocations"
run_apply --dry-run apply
assert_run_failure 'dry-run address inspection error is surfaced'
test_start 'dry-run address inspection reports a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=dry_run'
test_start 'dry-run address inspection error writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_inspect_physical$dry_inspect_runtime"

new_case dry-inspect-route
dry_inspect_physical=$(physical_state)
dry_inspect_runtime=$(runtime_state)
printf '2|ip -4 route show table 300\n' >"$STUB_STATE_DIR/fail-at.invocations"
run_apply --dry-run apply
assert_run_failure 'dry-run route inspection error is surfaced'
test_start 'dry-run route inspection reports a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=dry_run'
test_start 'dry-run route inspection error writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_inspect_physical$dry_inspect_runtime"

new_case dry-inspect-rule
dry_inspect_physical=$(physical_state)
dry_inspect_runtime=$(runtime_state)
printf '2|ip -4 rule show\n' >"$STUB_STATE_DIR/fail-at.invocations"
run_apply --dry-run apply
assert_run_failure 'dry-run policy-rule inspection error is surfaced'
test_start 'dry-run rule inspection reports a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=dry_run'
test_start 'dry-run rule inspection error writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_inspect_physical$dry_inspect_runtime"

new_case dry-inspect-ipv4-membership
dry_inspect_physical=$(physical_state)
dry_inspect_runtime=$(runtime_state)
printf '%s\n' 'iptables -t nat -C UBIOS_POSTROUTING_USER_HOOK -s 192.168.20.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42' >"$STUB_STATE_DIR/fail.invocations"
run_apply --dry-run apply
assert_run_failure 'dry-run IPv4 membership inspection error is surfaced'
test_start 'dry-run IPv4 membership inspection reports a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=dry_run'
test_start 'dry-run IPv4 membership error writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_inspect_physical$dry_inspect_runtime"

new_case dry-inspect-ipv6-membership
dry_inspect_physical=$(physical_state)
dry_inspect_runtime=$(runtime_state)
printf 'ip6tables -C UBIOS_INPUT_USER_HOOK -s 2001:db8:ffff::1/128 -d %s/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' "$LOCAL_V6" >"$STUB_STATE_DIR/fail.invocations"
run_apply --dry-run apply
assert_run_failure 'dry-run IPv6 membership inspection error is surfaced'
test_start 'dry-run IPv6 membership inspection reports a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=dry_run'
test_start 'dry-run IPv6 membership error writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_inspect_physical$dry_inspect_runtime"

new_case dry-inspect-outer-scan
write_config auto
dry_inspect_physical=$(physical_state)
dry_inspect_runtime=$(runtime_state)
printf '2|ip6tables -S UBIOS_INPUT_USER_HOOK\n' >"$STUB_STATE_DIR/fail-at.invocations"
run_apply --dry-run apply
assert_run_failure 'dry-run unmanaged outer inspection error is surfaced'
test_start 'dry-run unmanaged outer inspection reports a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=dry_run'
test_start 'dry-run unmanaged outer inspection error writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_inspect_physical$dry_inspect_runtime"

# Fix round 2 B: ownership uses semantic kernel evidence, not one -S spelling.
new_case realistic-firewall-serialization
run_apply apply
assert_run_success 'realistic firewall serialization fixture converges'
cat >"$STUB_STATE_DIR/iptables.nat.s-output" <<'EOF'
-A UBIOS_POSTROUTING_USER_HOOK --source 192.168.20.0/24 --out-interface ip6tnl1 --match comment --comment "unifi-jpix-tunnel-repair" --jump SNAT --to-source 203.0.113.42
-A UBIOS_POSTROUTING_USER_HOOK -s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
EOF
cat >"$STUB_STATE_DIR/iptables.mangle.s-output" <<'EOF'
-A FORWARD --out-interface ip6tnl1 --protocol 6 --match tcp --tcp-flags SYN,RST SYN --match comment --comment "unifi-jpix-tunnel-repair" --jump TCPMSS --set-mss 1420
-A FORWARD --in-interface ip6tnl1 -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
-A OUTPUT -o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment "unifi-jpix-tunnel-repair" -j TCPMSS --set-mss 1420
EOF
cat >"$STUB_STATE_DIR/ip6tables.s-output" <<EOF
-A UBIOS_INPUT_USER_HOOK --source 2001:db8:ffff::1/128 --destination $LOCAL_V6/128 --protocol 4 --match comment --comment "unifi-jpix-tunnel-repair" --jump ACCEPT
EOF
run_apply apply
assert_run_success 'later ownership accepts realistic equivalent firewall serializations'

new_case missing-known-firewall-rule
run_apply apply
assert_run_success 'missing known firewall fixture converges'
PATH=$APPLY_PATH iptables -t nat -D UBIOS_POSTROUTING_USER_HOOK -s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
run_apply apply
assert_run_success 'later apply repairs a missing known tagged rule'
test_start 'repaired known tagged rule is restored exactly once'
assert_eq "$(grep -F -c -- 'nat|UBIOS_POSTROUTING_USER_HOOK|-s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42' "$STUB_STATE_DIR/iptables.state")" 1

new_case unknown-realistic-tagged-rule
run_apply apply
assert_run_success 'unknown realistic tag fixture converges'
cat >"$STUB_STATE_DIR/iptables.nat.s-output" <<'EOF'
-A UBIOS_POSTROUTING_USER_HOOK --source 192.168.20.0/24 --out-interface ip6tnl1 --match comment --comment "unifi-jpix-tunnel-repair" --jump SNAT --to-source 203.0.113.42
-A UBIOS_POSTROUTING_USER_HOOK -s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
-A POSTROUTING --protocol tcp --match comment --comment "unifi-jpix-tunnel-repair" --jump ACCEPT
EOF
cat >"$STUB_STATE_DIR/iptables.mangle.s-output" <<'EOF'
-A FORWARD -o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
-A FORWARD -i ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
-A OUTPUT -o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
EOF
cat >"$STUB_STATE_DIR/ip6tables.s-output" <<EOF
-A UBIOS_INPUT_USER_HOOK -s 2001:db8:ffff::1/128 -d $LOCAL_V6/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT
EOF
assert_rejected_unchanged 'singleton unknown realistically serialized tagged rule'

# Fix round 2 C: dry-run represents NAT-chain-only transitions exactly.
new_case dry-nat-chain-transition
run_apply apply
assert_run_success 'dry NAT-chain transition fixture converges'
printf 'iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK\n' >"$STUB_STATE_DIR/absent.invocations"
dry_transition_physical=$(physical_state)
dry_transition_runtime=$(runtime_state)
run_apply --dry-run apply
assert_run_failure 'dry-run rejects a missing UniFi NAT user hook instead of planning global fallback'
test_start 'rejected dry-run writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_transition_physical$dry_transition_runtime"

# Fix round 2 D: status accounts for every tagged identity and current chain.
new_case status-unknown-ipv4-tag
run_apply apply
assert_run_success 'status unknown IPv4 tag fixture converges'
printf 'nat|POSTROUTING|-s 10.0.0.0/8 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >>"$STUB_STATE_DIR/iptables.state"
status_unknown_before=$(physical_state)
run_apply status
assert_run_failure 'status rejects a singleton unknown tagged IPv4 rule'
test_start 'status reports exact tagged-rule drift for IPv4'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR tagged_rules='
test_start 'unknown IPv4 tag status is read-only'
assert_eq "$(physical_state)" "$status_unknown_before"

new_case status-unknown-ipv6-tag
run_apply apply
assert_run_success 'status unknown IPv6 tag fixture converges'
printf 'INPUT|-s 2001:db8:aaaa::1/128 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >>"$STUB_STATE_DIR/ip6tables.state"
status_unknown_before=$(physical_state)
run_apply status
assert_run_failure 'status rejects a singleton unknown tagged IPv6 rule'
test_start 'status reports exact tagged-rule drift for IPv6'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR tagged_rules='
test_start 'unknown IPv6 tag status is read-only'
assert_eq "$(physical_state)" "$status_unknown_before"

new_case status-current-nat-chain
run_apply apply
assert_run_success 'status current NAT chain fixture converges'
printf 'iptables -t nat -S UBIOS_POSTROUTING_USER_HOOK\n' >"$STUB_STATE_DIR/absent.invocations"
status_chain_before=$(physical_state)
run_apply status
assert_run_failure 'status rejects primary-to-fallback NAT chain drift'
test_start 'status reports current NAT chain drift explicitly'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR nat_chain=inspection_failed expected=UBIOS_POSTROUTING_USER_HOOK'
test_start 'NAT chain drift status is read-only'
assert_eq "$(physical_state)" "$status_chain_before"

# Fix round 2 E: endpoint transition plans redact both old and new provider data.
new_case dry-endpoint-transition-redaction
run_apply apply
assert_run_success 'dry endpoint redaction fixture converges'
printf '2001:db8:1234:21::\n' >"$STUB_STATE_DIR/endpoint6.prefix"
dry_endpoint_physical=$(physical_state)
dry_endpoint_runtime=$(runtime_state)
run_apply --dry-run apply
assert_run_success 'dry endpoint transition produces a redacted plan'
dry_endpoint_output=$(cat "$RUN_OUTPUT")
for secret_address in "$LOCAL_V6" "$NEXT_LOCAL_V6" 203.0.113.42 2001:db8:ffff::1; do
  test_start "dry endpoint transition hides $secret_address"
  assert_not_contains "$dry_endpoint_output" "$secret_address"
done
test_start 'dry endpoint transition identifies prior local endpoint with a stable placeholder'
assert_contains "$dry_endpoint_output" '[OLD_LOCAL_V6]'
test_start 'dry endpoint transition still identifies the new local endpoint shape'
assert_contains "$dry_endpoint_output" '[LOCAL_V6]'
test_start 'dry endpoint transition writes no state'
assert_eq "$(physical_state)$(runtime_state)" "$dry_endpoint_physical$dry_endpoint_runtime"

# Fix round 2 F: rollback restores exact firewall positions among unmanaged rules.
new_case firewall-position-late-failure
run_apply apply
assert_run_success 'firewall position late-failure fixture converges'
install_interleaved_firewall_duplicates
firewall_position_physical=$(physical_state)
firewall_position_runtime=$(runtime_state)
V6PLUS_TEST_FAIL_OFF_REMOVE=managed
export V6PLUS_TEST_FAIL_OFF_REMOVE
run_apply off
unset V6PLUS_TEST_FAIL_OFF_REMOVE
assert_run_failure 'late off failure rolls back interleaved firewall deletions'
test_start 'late firewall rollback restores IPv4 and IPv6 chain order byte-exact'
assert_eq "$(physical_state)$(runtime_state)" "$firewall_position_physical$firewall_position_runtime"

new_case firewall-position-prerecord-failure
run_apply apply
assert_run_success 'firewall pre-record failure fixture converges'
install_interleaved_firewall_duplicates
firewall_position_physical=$(physical_state)
firewall_position_runtime=$(runtime_state)
printf 'ip6tables -D UBIOS_INPUT_USER_HOOK -s 2001:db8:ffff::1/128 -d %s/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' "$LOCAL_V6" >"$STUB_STATE_DIR/fail-once.invocations"
run_apply off
assert_run_failure 'failure after firewall journal and before delete is surfaced'
test_start 'pre-record replay preserves interleaved firewall order byte-exact'
assert_eq "$(physical_state)$(runtime_state)" "$firewall_position_physical$firewall_position_runtime"

new_case firewall-position-signal
run_apply apply
assert_run_success 'firewall signal rollback fixture converges'
install_interleaved_firewall_duplicates
firewall_position_physical=$(physical_state)
firewall_position_runtime=$(runtime_state)
printf 'ip6tables -D UBIOS_INPUT_USER_HOOK -s 2001:db8:ffff::1/128 -d %s/128 -p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' "$LOCAL_V6" >"$STUB_STATE_DIR/signal-after.invocations"
run_apply off
assert_run_failure 'signal after exact managed firewall deletion is surfaced'
test_start 'signal rollback restores interleaved IPv4 and IPv6 order byte-exact'
assert_eq "$(physical_state)$(runtime_state)" "$firewall_position_physical$firewall_position_runtime"

# Fix round 2 G: legal route argv is validated, journaled, and restored exactly.
new_case route-attribute-rollback
run_apply apply
assert_run_success 'route attribute rollback fixture converges'
awk -F'|' 'BEGIN { OFS="|" } $2 == "192.168.10.0/24" { $4="proto static metric 10 src 203.0.113.42" } { print }' \
  "$STUB_STATE_DIR/routes.state" >"$STUB_STATE_DIR/routes.tmp"
mv "$STUB_STATE_DIR/routes.tmp" "$STUB_STATE_DIR/routes.state"
printf 'br0 192.168.20.0/24\n' >"$CONFIG/routed-networks.conf"
route_attribute_physical=$(physical_state)
route_attribute_runtime=$(runtime_state)
V6PLUS_TEST_FAIL_JOURNAL_TYPE=STATE_MANAGED_RESTORE
export V6PLUS_TEST_FAIL_JOURNAL_TYPE
run_apply apply
unset V6PLUS_TEST_FAIL_JOURNAL_TYPE
assert_run_failure 'later state-journal failure rolls back attributed route deletion'
test_start 'route rollback restores every legal attribute byte-exact'
assert_eq "$(physical_state)$(runtime_state)" "$route_attribute_physical$route_attribute_runtime"

new_case unsafe-route-token
run_apply apply
assert_run_success 'unsafe route token fixture converges'
cat >"$STUB_STATE_DIR/route.s-output" <<'EOF'
default dev ip6tnl1 proto static metric 10
192.168.20.0/24 dev br0 proto static;bad metric 10
192.168.10.0/24 dev br10 proto static metric 10
EOF
assert_rejected_unchanged 'unsafe persisted route token'

# Fix round 2 H: off removes every exact policy-rule duplicate and rolls back counts.
new_case duplicate-policy-off
run_apply apply
assert_run_success 'duplicate policy off fixture converges'
PATH=$APPLY_PATH ip -4 rule add pref 10000 from 192.168.20.0/24 iif br0 lookup 300
PATH=$APPLY_PATH ip -4 rule add pref 10001 from 192.168.10.0/24 iif br10 lookup 300
run_apply off
assert_run_success 'off removes all exact managed policy-rule duplicates'
test_start 'off leaves no managed policy rule duplicate'
assert_eq "$(cat "$STUB_STATE_DIR/rules.state")" ''

new_case duplicate-policy-rollback
run_apply apply
assert_run_success 'duplicate policy rollback fixture converges'
PATH=$APPLY_PATH ip -4 rule add pref 10000 from 192.168.20.0/24 iif br0 lookup 300
PATH=$APPLY_PATH ip -4 rule add pref 10001 from 192.168.10.0/24 iif br10 lookup 300
duplicate_policy_physical=$(physical_state)
duplicate_policy_runtime=$(runtime_state)
V6PLUS_TEST_FAIL_OFF_REMOVE=managed
export V6PLUS_TEST_FAIL_OFF_REMOVE
run_apply off
unset V6PLUS_TEST_FAIL_OFF_REMOVE
assert_run_failure 'late off failure rolls back duplicate policy rules'
test_start 'policy rollback restores exact duplicate count and order'
assert_eq "$(physical_state)$(runtime_state)" "$duplicate_policy_physical$duplicate_policy_runtime"

new_case off-unknown-reserved-rule
run_apply apply
assert_run_success 'off unknown reserved-rule fixture converges'
printf '10000|192.168.20.0/24|evil0|999\n' >>"$STUB_STATE_DIR/rules.state"
off_unknown_rule_physical=$(physical_state)
off_unknown_rule_runtime=$(runtime_state)
off_unknown_rule_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply off
assert_run_failure 'off rejects unknown rule at a reserved preference'
test_start 'off reserved-rule rejection invokes no mutation command'
assert_eq "$(mutation_log_after "$off_unknown_rule_log_lines")" ''
test_start 'off reserved-rule rejection preserves all state'
assert_eq "$(physical_state)$(runtime_state)" "$off_unknown_rule_physical$off_unknown_rule_runtime"

# Fix round 2 I: off binds current configuration to its immutable snapshot.
new_case off-config-tunnel-identity
run_apply apply
assert_run_success 'off tunnel identity fixture converges'
sed 's/^TUN_IF=.*/TUN_IF=ip6tnl2/' "$CONFIG/gateway.conf" >"$CONFIG/v6plus.tmp"
mv "$CONFIG/v6plus.tmp" "$CONFIG/gateway.conf"
sed 's/^TUN_IF=.*/TUN_IF=ip6tnl2/' "$STUB_STATE_DIR/tunnel.state" >"$STUB_STATE_DIR/tunnel.tmp"
mv "$STUB_STATE_DIR/tunnel.tmp" "$STUB_STATE_DIR/tunnel.state"
sed 's/^ip6tnl1|/ip6tnl2|/' "$STUB_STATE_DIR/addr4.state" >"$STUB_STATE_DIR/addr4.tmp"
mv "$STUB_STATE_DIR/addr4.tmp" "$STUB_STATE_DIR/addr4.state"
sed 's/|ip6tnl1/|ip6tnl2/g' "$STUB_STATE_DIR/routes.state" >"$STUB_STATE_DIR/routes.tmp"
mv "$STUB_STATE_DIR/routes.tmp" "$STUB_STATE_DIR/routes.state"
sed 's/ip6tnl1/ip6tnl2/g' "$STUB_STATE_DIR/iptables.state" >"$STUB_STATE_DIR/iptables.tmp"
mv "$STUB_STATE_DIR/iptables.tmp" "$STUB_STATE_DIR/iptables.state"
off_identity_physical=$(physical_state)
off_identity_runtime=$(runtime_state)
off_identity_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply off
assert_run_failure 'off rejects configuration tunnel identity mismatch'
test_start 'off tunnel identity rejection is stable'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR tunnel identity mismatch'
test_start 'off identity mismatch invokes no mutation command'
assert_eq "$(mutation_log_after "$off_identity_log_lines")" ''
test_start 'off identity mismatch preserves physical and authoritative runtime state'
assert_eq "$(physical_state)$(runtime_state)" "$off_identity_physical$off_identity_runtime"

# Fix round 3: the management tag is reserved across every available firewall table.
new_case global-first-ipv4-filter-tag
printf 'filter|INPUT|-p tcp -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >"$STUB_STATE_DIR/iptables.state"
global_first_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
assert_rejected_unchanged 'first apply IPv4 filter management-tag collision'
test_start 'first apply IPv4 filter tag collision invokes no mutation command'
assert_eq "$(mutation_log_after "$global_first_log_lines")" ''

new_case global-first-ipv6-nat-tag
printf 'nat|PREROUTING|-p 4 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >"$STUB_STATE_DIR/ip6tables-extra.state"
global_first_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
assert_rejected_unchanged 'first apply IPv6 non-filter management-tag collision'
test_start 'first apply IPv6 non-filter tag collision invokes no mutation command'
assert_eq "$(mutation_log_after "$global_first_log_lines")" ''

new_case global-later-ipv4-raw-tag
run_apply apply
assert_run_success 'later IPv4 raw tag fixture converges'
printf 'raw|PREROUTING|-s 10.1.0.0/16 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >>"$STUB_STATE_DIR/iptables.state"
assert_rejected_unchanged 'later apply IPv4 raw unknown management tag'

new_case global-later-ipv4-filter-tag
run_apply apply
assert_run_success 'later IPv4 filter tag fixture converges'
printf 'filter|FORWARD|-s 10.2.0.0/16 -m comment --comment unifi-jpix-tunnel-repair -j DROP\n' >>"$STUB_STATE_DIR/iptables.state"
assert_rejected_unchanged 'later apply IPv4 filter unknown management tag'

new_case global-later-ipv6-nat-tag
run_apply apply
assert_run_success 'later IPv6 nat tag fixture converges'
printf 'nat|OUTPUT|-d 2001:db8:aaaa::/64 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >>"$STUB_STATE_DIR/ip6tables-extra.state"
assert_rejected_unchanged 'later apply IPv6 nat unknown management tag'

new_case global-later-ipv6-mangle-tag
run_apply apply
assert_run_success 'later IPv6 mangle tag fixture converges'
printf 'mangle|FORWARD|-d 2001:db8:bbbb::/64 -m comment --comment unifi-jpix-tunnel-repair -j DROP\n' >>"$STUB_STATE_DIR/ip6tables-extra.state"
assert_rejected_unchanged 'later apply IPv6 mangle unknown management tag'

new_case global-status-outside-tag
run_apply apply
assert_run_success 'global status tag fixture converges'
printf 'security|OUTPUT|-d 192.0.2.0/24 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >>"$STUB_STATE_DIR/iptables.state"
printf 'raw|PREROUTING|-s 2001:db8:cccc::/64 -m comment --comment unifi-jpix-tunnel-repair -j ACCEPT\n' >>"$STUB_STATE_DIR/ip6tables-extra.state"
global_status_before=$(physical_state)
run_apply status
assert_run_failure 'status rejects management tags outside target tables'
test_start 'global status tag drift has a stable invariant'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR tagged_rules='
test_start 'global status tag drift is read-only'
assert_eq "$(physical_state)" "$global_status_before"

new_case global-off-outside-tag
run_apply apply
assert_run_success 'global off tag fixture converges'
printf 'filter|INPUT|-s 10.3.0.0/16 -m comment --comment unifi-jpix-tunnel-repair -j DROP\n' >>"$STUB_STATE_DIR/iptables.state"
global_off_physical=$(physical_state)
global_off_runtime=$(runtime_state)
global_off_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply off
assert_run_failure 'off refuses an out-of-scope management tag'
test_start 'global off tag refusal invokes no mutation command'
assert_eq "$(mutation_log_after "$global_off_log_lines")" ''
test_start 'global off tag refusal preserves physical and runtime state'
assert_eq "$(physical_state)$(runtime_state)" "$global_off_physical$global_off_runtime"

# Every lifecycle entry point fails closed when the authoritative inventory cannot be read.
new_case global-inventory-first-failure
printf 'iptables-save\n' >"$STUB_STATE_DIR/fail.invocations"
global_first_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
assert_rejected_unchanged 'first apply global firewall inventory failure'
test_start 'first apply inventory failure invokes no mutation command'
assert_eq "$(mutation_log_after "$global_first_log_lines")" ''

new_case global-inventory-missing-command
global_missing_physical=$(physical_state)
global_missing_runtime=$(runtime_state)
V6_IPTABLES_SAVE_CMD=v6plus-no-such-iptables-save
export V6_IPTABLES_SAVE_CMD
run_apply apply
unset V6_IPTABLES_SAVE_CMD
assert_run_failure 'first apply rejects a missing global inventory dependency'
test_start 'missing inventory dependency performs no state mutation'
assert_eq "$(physical_state)$(runtime_state)" "$global_missing_physical$global_missing_runtime"

new_case global-inventory-dry-failure
printf 'ip6tables-save\n' >"$STUB_STATE_DIR/fail.invocations"
global_dry_physical=$(physical_state)
global_dry_runtime=$(runtime_state)
run_apply --dry-run apply
assert_run_failure 'dry-run global firewall inventory failure is surfaced'
test_start 'dry-run inventory failure has a stable phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=preflight'
test_start 'dry-run inventory failure performs zero writes'
assert_eq "$(physical_state)$(runtime_state)" "$global_dry_physical$global_dry_runtime"

new_case global-inventory-later-failure
run_apply apply
assert_run_success 'later inventory failure fixture converges'
printf 'iptables-save\n' >"$STUB_STATE_DIR/fail.invocations"
assert_rejected_unchanged 'later apply global firewall inventory failure'

new_case global-inventory-status-failure
run_apply apply
assert_run_success 'status inventory failure fixture converges'
printf 'ip6tables-save\n' >"$STUB_STATE_DIR/fail.invocations"
global_status_failure_before=$(physical_state)
run_apply status
assert_run_failure 'status global firewall inventory failure is surfaced'
test_start 'status inventory failure has a stable invariant'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR tagged_rules=inspection_failed'
test_start 'status inventory failure is read-only'
assert_eq "$(physical_state)" "$global_status_failure_before"

new_case global-inventory-off-failure
run_apply apply
assert_run_success 'off inventory failure fixture converges'
printf 'iptables-save\n' >"$STUB_STATE_DIR/fail.invocations"
global_off_failure_physical=$(physical_state)
global_off_failure_runtime=$(runtime_state)
global_off_failure_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply off
assert_run_failure 'off global firewall inventory failure is surfaced'
test_start 'off inventory failure invokes no mutation command'
assert_eq "$(mutation_log_after "$global_off_failure_log_lines")" ''
test_start 'off inventory failure preserves physical and runtime state'
assert_eq "$(physical_state)$(runtime_state)" "$global_off_failure_physical$global_off_failure_runtime"

# This fixture is hand-written save output, independent from the production normalizer.
new_case global-realistic-multitable
run_apply apply
assert_run_success 'realistic global inventory fixture converges'
cat >"$STUB_STATE_DIR/iptables-save.output" <<'EOF'
# Generated by iptables-save v1.8.7 on Fri Aug 21 12:00:00 2026
*raw
:PREROUTING ACCEPT [0:0]
-A PREROUTING --source 10.10.0.0/16 --jump ACCEPT
COMMIT
*mangle
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD --out-interface ip6tnl1 --protocol 6 --match tcp --tcp-flags SYN,RST SYN --match comment --comment "unifi-jpix-tunnel-repair" --jump TCPMSS --set-mss 1420
-A FORWARD --in-interface ip6tnl1 -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment unifi-jpix-tunnel-repair -j TCPMSS --set-mss 1420
-A OUTPUT -o ip6tnl1 -p tcp --tcp-flags SYN,RST SYN -m comment --comment "unifi-jpix-tunnel-repair" -j TCPMSS --set-mss 1420
COMMIT
*nat
:POSTROUTING ACCEPT [0:0]
:UBIOS_POSTROUTING_USER_HOOK - [0:0]
-A UBIOS_POSTROUTING_USER_HOOK --source 192.168.20.0/24 --out-interface ip6tnl1 --match comment --comment "unifi-jpix-tunnel-repair" --jump SNAT --to-source 203.0.113.42
-A UBIOS_POSTROUTING_USER_HOOK -s 192.168.10.0/24 -o ip6tnl1 -m comment --comment unifi-jpix-tunnel-repair -j SNAT --to-source 203.0.113.42
COMMIT
*filter
:INPUT ACCEPT [0:0]
-A INPUT -s 10.20.0.0/16 -j ACCEPT
COMMIT
*security
:INPUT ACCEPT [0:0]
COMMIT
# Completed on Fri Aug 21 12:00:00 2026
EOF
cat >"$STUB_STATE_DIR/ip6tables-save.output" <<EOF
# Generated by ip6tables-save v1.8.7 on Fri Aug 21 12:00:00 2026
*raw
:PREROUTING ACCEPT [0:0]
COMMIT
*mangle
:FORWARD ACCEPT [0:0]
-A FORWARD --source 2001:db8:eeee::/64 --jump ACCEPT
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
COMMIT
*filter
:INPUT ACCEPT [0:0]
:UBIOS_INPUT_USER_HOOK - [0:0]
-A UBIOS_INPUT_USER_HOOK --source 2001:db8:ffff::1/128 --destination $LOCAL_V6/128 --protocol 4 --match comment --comment "unifi-jpix-tunnel-repair" --jump ACCEPT
COMMIT
*security
:INPUT ACCEPT [0:0]
COMMIT
# Completed on Fri Aug 21 12:00:00 2026
EOF
: >"$STUB_LOG"
global_realistic_before=$(physical_state)
run_apply apply
assert_run_success 'hard-coded multi-table inventory is semantically accepted'
test_start 'IPv4 authoritative inventory command is required'
assert_contains "$(cat "$STUB_LOG")" 'iptables-save'
test_start 'IPv6 authoritative inventory command is required'
assert_contains "$(cat "$STUB_LOG")" 'ip6tables-save'
test_start 'realistic read-only inventory leaves firewall bytes unchanged'
assert_eq "$(physical_state)" "$global_realistic_before"

new_case global-untagged-unrelated
printf 'filter|INPUT|-s 10.40.0.0/16 -j ACCEPT\n' >"$STUB_STATE_DIR/iptables.state"
printf 'mangle|FORWARD|-s 2001:db8:dddd::/64 -j ACCEPT\n' >"$STUB_STATE_DIR/ip6tables-extra.state"
run_apply apply
assert_run_success 'unrelated untagged all-table rules are allowed'
test_start 'apply leaves unrelated IPv4 non-target rule untouched'
assert_contains "$(cat "$STUB_STATE_DIR/iptables.state")" 'filter|INPUT|-s 10.40.0.0/16 -j ACCEPT'
test_start 'apply leaves unrelated IPv6 non-target rule untouched'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables-extra.state")" 'mangle|FORWARD|-s 2001:db8:dddd::/64 -j ACCEPT'
run_apply off
assert_run_success 'off permits unrelated untagged all-table rules'
test_start 'off leaves unrelated IPv4 non-target rule untouched'
assert_eq "$(cat "$STUB_STATE_DIR/iptables.state")" 'filter|INPUT|-s 10.40.0.0/16 -j ACCEPT'
test_start 'off leaves unrelated IPv6 non-target rule untouched'
assert_eq "$(cat "$STUB_STATE_DIR/ip6tables-extra.state")" 'mangle|FORWARD|-s 2001:db8:dddd::/64 -j ACCEPT'

# Fix round 4: authoritative save output must describe complete table/chain structure.
new_case inventory-empty-first-ipv4
: >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'successful empty IPv4 inventory on first apply'

new_case inventory-empty-dry-ipv6
: >"$STUB_STATE_DIR/ip6tables-save.output"
inventory_empty_dry_physical=$(physical_state)
inventory_empty_dry_runtime=$(runtime_state)
inventory_empty_dry_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply --dry-run apply
assert_run_failure 'successful empty IPv6 inventory on dry-run is rejected'
test_start 'successful empty dry-run inventory reports the preflight phase'
assert_contains "$(cat "$RUN_ERROR")" 'ERROR phase=preflight'
test_start 'successful empty dry-run inventory invokes no mutation command'
assert_eq "$(mutation_log_after "$inventory_empty_dry_log_lines")" ''
test_start 'successful empty dry-run inventory preserves physical and runtime state'
assert_eq "$(physical_state)$(runtime_state)" "$inventory_empty_dry_physical$inventory_empty_dry_runtime"

new_case inventory-empty-later-ipv4
run_apply apply
assert_run_success 'later successful-empty inventory fixture converges'
: >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'successful empty IPv4 inventory on later apply'

new_case inventory-empty-status-ipv6
run_apply apply
assert_run_success 'status successful-empty inventory fixture converges'
: >"$STUB_STATE_DIR/ip6tables-save.output"
inventory_empty_status_physical=$(physical_state)
inventory_empty_status_runtime=$(runtime_state)
inventory_empty_status_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply status
assert_run_failure 'status rejects successful empty IPv6 inventory'
test_start 'status successful-empty inventory has a stable error'
assert_contains "$(cat "$RUN_OUTPUT")" 'ERROR tagged_rules=inspection_failed expected=exact'
test_start 'status successful-empty inventory invokes no mutation command'
assert_eq "$(mutation_log_after "$inventory_empty_status_log_lines")" ''
test_start 'status successful-empty inventory preserves physical and runtime state'
assert_eq "$(physical_state)$(runtime_state)" "$inventory_empty_status_physical$inventory_empty_status_runtime"

new_case inventory-empty-off-ipv4
run_apply apply
assert_run_success 'off successful-empty inventory fixture converges'
: >"$STUB_STATE_DIR/iptables-save.output"
inventory_empty_off_physical=$(physical_state)
inventory_empty_off_runtime=$(runtime_state)
inventory_empty_off_log_lines=$(wc -l <"$STUB_LOG" | tr -d ' ')
run_apply off
assert_run_failure 'off rejects successful empty IPv4 inventory'
test_start 'off successful-empty inventory invokes no mutation command'
assert_eq "$(mutation_log_after "$inventory_empty_off_log_lines")" ''
test_start 'off successful-empty inventory preserves authoritative state'
assert_eq "$(physical_state)$(runtime_state)" "$inventory_empty_off_physical$inventory_empty_off_runtime"

new_case inventory-table-without-chain
printf '%s\n' '*filter' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'table section without a chain declaration'

new_case inventory-chain-bare-colon
printf '%s\n' '*filter' ':' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'bare-colon chain declaration'

new_case inventory-chain-missing-name
printf '%s\n' '*filter' ': ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with a missing name'

new_case inventory-chain-unsafe-name
printf '%s\n' '*filter' ':IN/PUT ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with an unsafe name'

new_case inventory-chain-invalid-policy
printf '%s\n' '*filter' ':INPUT MAYBE [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with an invalid policy'

new_case inventory-chain-queue-policy
printf '%s\n' '*filter' ':INPUT QUEUE [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with a rule-only QUEUE target as policy'

new_case inventory-chain-return-policy
printf '%s\n' '*filter' ':INPUT RETURN [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with a rule-only RETURN target as policy'

new_case inventory-chain-missing-policy
printf '%s\n' '*filter' ':INPUT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with a missing policy'

new_case inventory-chain-invalid-counters
printf '%s\n' '*filter' ':INPUT ACCEPT [-1:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with invalid counters'

new_case inventory-chain-unbracketed-counters
printf '%s\n' '*filter' ':INPUT ACCEPT 0:0' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with unbracketed counters'

new_case inventory-chain-missing-counters
printf '%s\n' '*filter' ':INPUT ACCEPT' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with missing counters'

new_case inventory-chain-extra-field
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0] extra' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with an extra field'

new_case inventory-chain-control-character
printf '*filter\n:INPUT\tACCEPT [0:0]\nCOMMIT\n' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with a control character'

new_case inventory-chain-delimiter
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]|suffix' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'chain declaration with the inventory delimiter'

new_case inventory-chain-duplicate
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' ':INPUT ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'duplicate chain declaration in one table'

new_case inventory-rule-undeclared-chain
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '-A FORWARD -j ACCEPT' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'rule referencing an undeclared same-table chain'

new_case inventory-rule-unsafe-chain
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '-A INPUT;uname -j ACCEPT' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'rule with an unsafe target chain token'

new_case inventory-rule-before-table
printf '%s\n' '-A INPUT -j ACCEPT' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'rule before the first table section'

new_case inventory-rule-after-commit
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT' '-A INPUT -j ACCEPT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'rule after an exact COMMIT'

new_case inventory-nested-table
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '*nat' ':POSTROUTING ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'nested table section'

new_case inventory-duplicate-table
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT' '*filter' ':OUTPUT ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'duplicate table section'

new_case inventory-missing-commit
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'table section with missing COMMIT'

new_case inventory-extra-commit
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'extra COMMIT outside a table section'

new_case inventory-unknown-record
printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' '-N USER_CHAIN' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'unknown record type inside a table section'

new_case inventory-unsafe-table
printf '%s\n' '*fil/ter' ':INPUT ACCEPT [0:0]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
assert_inventory_rejected_before_mutation 'unsafe table name'

new_case inventory-chain-same-name-cross-table
printf '%s\n' '# safe chain identity is scoped to each table' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT' '' '*security' ':INPUT ACCEPT [5:10]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
run_apply apply
assert_run_success 'the same safe chain name in different tables is accepted'

new_case inventory-valid-zero-rules
printf '%s\n' '*filter' ':INPUT DROP [12:345]' 'COMMIT' >"$STUB_STATE_DIR/iptables-save.output"
run_apply apply
assert_run_success 'a valid declared-chain table with zero rules is accepted'

new_case inventory-valid-declared-user-chain-rule
cat >"$STUB_STATE_DIR/iptables-save.output" <<'EOF'
# Hand-written independently from the save stubs and production parser.
*filter
:INPUT ACCEPT [0:0]
:UBIOS.USER-HOOK_1 - [7:99]
-A UBIOS.USER-HOOK_1 -s 10.50.0.0/16 -j RETURN
COMMIT
EOF
run_apply apply
assert_run_success 'a rule referencing its declared dotted and hyphenated user chain is accepted'

test_finish
