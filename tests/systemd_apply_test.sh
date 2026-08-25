#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

UNIT=$ROOT/systemd/v6plus-apply.service
test_start 'boot apply unit exists'
if [ -f "$UNIT" ]; then
  pass
else
  fail "missing unit $UNIT"
  test_finish
fi

unit_values() {
  awk -v wanted_section="$1" -v wanted_key="$2" '
    /^[[:space:]]*\[/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    section == wanted_section && index($0, wanted_key "=") == 1 {
      print substr($0, length(wanted_key) + 2)
    }
  ' "$UNIT"
}

test_start 'unit has the approved description'
assert_eq "$(unit_values Unit Description)" 'Apply JPIX v6plus fixed IPv4 tunnel state'
test_start 'unit starts after network-online target'
assert_eq "$(unit_values Unit After)" 'network-online.target'
test_start 'unit wants network-online target'
assert_eq "$(unit_values Unit Wants)" 'network-online.target'
test_start 'all live config files gate the boot apply'
assert_eq "$(unit_values Unit ConditionPathExists)" "/data/v6plus/config/v6plus.env
/data/v6plus/config/networks.conf
/data/v6plus/config/update.env"
test_start 'boot apply service is oneshot'
assert_eq "$(unit_values Service Type)" 'oneshot'
test_start 'boot apply runs as root with a private umask'
assert_eq "$(unit_values Service User):$(unit_values Service Group):$(unit_values Service UMask)" 'root:root:0077'
test_start 'boot apply cannot gain additional privileges'
assert_eq "$(unit_values Service NoNewPrivileges)" yes
test_start 'boot apply treats installed code and config as read-only'
assert_eq "$(unit_values Service ReadOnlyPaths)" '/data/v6plus/scripts /data/v6plus/config'
test_start 'WAN readiness runs before apply with the approved deadline'
assert_eq "$(unit_values Service ExecStartPre)" '/data/v6plus/scripts/v6plus-wait-wan.sh --timeout 300'
test_start 'boot action invokes the shared apply path'
assert_eq "$(unit_values Service ExecStart)" '/data/v6plus/scripts/v6plus-apply.sh apply'
test_start 'notification is forced but non-fatal after successful apply'
assert_eq "$(unit_values Service ExecStartPost)" '-/data/v6plus/scripts/v6plus-update.sh --force'
test_start 'oneshot remains active for dependent services'
assert_eq "$(unit_values Service RemainAfterExit)" 'yes'
test_start 'systemd timeout exceeds readiness plus update retries'
assert_eq "$(unit_values Service TimeoutStartSec)" '480'
test_start 'boot apply is intentionally not enableable yet'
if grep -Eq '^[[:space:]]*\[Install\][[:space:]]*$' "$UNIT"; then
  fail 'unexpected Install section'
else
  pass
fi
test_start 'unit file mode is 0644'
assert_eq "$(stat -c %a "$UNIT")" 644

test_finish
