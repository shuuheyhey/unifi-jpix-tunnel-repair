#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

INSTALLER=$ROOT/scripts/install.sh
TMP_BASE=$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=${TMP_BASE%/}/v6plus-install-test.$$
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || :; rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/root/data" "$TMP/root/etc/systemd/system"
chmod 755 "$TMP/root" "$TMP/root/data" "$TMP/root/etc" "$TMP/root/etc/systemd" "$TMP/root/etc/systemd/system"

test_start 'installer exists and is executable'
[ -x "$INSTALLER" ] && pass || fail 'missing executable installer'

set +e
V6PLUS_ALLOW_NONROOT=1 "$INSTALLER" --destdir "$TMP/root" >"$TMP/stdout" 2>"$TMP/stderr"
status=$?
set -e
test_start 'installer creates an inert deployment tree'
assert_eq "$status" 0

for script in "$TMP/root/data/v6plus/scripts"/*.sh; do
  test_start "installed script is mode 0755: ${script##*/}"
  assert_eq "$(stat -c %a "$script")" 755
done
for unit in "$TMP/root/etc/systemd/system"/v6plus-*; do
  test_start "installed unit is mode 0644: ${unit##*/}"
  assert_eq "$(stat -c %a "$unit")" 644
done

test_start 'installer does not create live configuration from examples'
if find "$TMP/root/data/v6plus/config" -type f ! -name '*.example' -print | grep . >/dev/null; then
  fail 'live config was created'
else
  pass
fi

test_start 'installer does not enable or start services'
if grep -E 'enable|start' "$TMP/stdout" "$TMP/stderr" >/dev/null; then
  fail 'installer activated runtime services'
else
  pass
fi

chmod 777 "$TMP/root/data/v6plus/scripts"
printf 'must-remain-unchanged\n' >"$TMP/root/data/v6plus/scripts/hostile-marker"
set +e
V6PLUS_ALLOW_NONROOT=1 "$INSTALLER" --destdir "$TMP/root" >"$TMP/unsafe-stdout" 2>"$TMP/unsafe-stderr"
unsafe_status=$?
set -e
test_start 'installer rejects an unsafe pre-existing deployment subtree'
assert_eq "$unsafe_status" 2
test_start 'installer does not promote content from the unsafe subtree'
assert_eq "$(cat "$TMP/root/data/v6plus/scripts/hostile-marker")" must-remain-unchanged

test_finish
