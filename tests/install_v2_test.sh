#!/bin/sh
set -eu
umask 077

REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$REPO/tests/testlib.sh"
TMP=$(mktemp -d)
TMP=$(CDPATH= cd -- "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/root" "$TMP/units"

cat >"$TMP/bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then printf '%s\n' 0; else exec /usr/bin/id "$@"; fi
EOF
cat >"$TMP/bin/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/systemctl.log"
case \${1:-} in
  list-unit-files)
    [ "\${TEST_INVENTORY_FAILURE:-}" != files ] || exit 1
    [ -z "\${TEST_UNIT_FILES:-}" ] || printf '%s\n' "\$TEST_UNIT_FILES"
    ;;
  list-units)
    [ "\${TEST_INVENTORY_FAILURE:-}" != loaded ] || exit 1
    [ -z "\${TEST_LOADED_UNITS:-}" ] || printf '%s\n' "\$TEST_LOADED_UNITS"
    ;;
  show)
    [ "\${TEST_SHOW_FAILED:-0}" = 0 ] || exit 1
    printf '%s\n' "LoadState=\${TEST_UNIT_LOAD:-loaded}" "ActiveState=\${TEST_UNIT_ACTIVE:-inactive}" "UnitFileState=\${TEST_UNIT_ENABLED:-disabled}"
    ;;
esac
EOF
chmod 755 "$TMP/bin/id" "$TMP/bin/systemctl"

run_install() {
  PATH="$TMP/bin:$PATH" \
  UNIFI_JPIX_ROOT="$TMP/root" \
  UNIFI_JPIX_UNIT_DIR="$TMP/units" \
    "$REPO/scripts/install-v2.sh" "$@"
}
assert_blocked() {
  if run_install >"$TMP/result" 2>&1; then fail 'accepted an unsafe automation inventory'; else pass; fi
  [ ! -e "$TMP/root/releases" ] || fail 'mutated releases before checking automation'
  [ ! -e "$TMP/units/unifi-jpix-bootstrap.service" ] || fail 'installed bootstrap before checking automation'
}

test_start 'installer fails closed when either automation inventory is unavailable'
for inventory in files loaded; do
  TEST_INVENTORY_FAILURE=$inventory assert_blocked
done
unset TEST_INVENTORY_FAILURE

TEST_UNIT_FILES='unifi-jpix-other-agent.service disabled'
export TEST_UNIT_FILES
test_start 'installer rejects conflicting automation activity'
for state in active activating deactivating failed unknown; do
  TEST_UNIT_ACTIVE=$state assert_blocked
done
unset TEST_UNIT_ACTIVE
test_start 'installer rejects automation scheduled to start'
TEST_UNIT_ENABLED=enabled assert_blocked
unset TEST_UNIT_ENABLED
test_start 'installer rejects unknown automation state'
TEST_SHOW_FAILED=1 assert_blocked
unset TEST_SHOW_FAILED TEST_UNIT_FILES

test_start 'installer checks loaded units even when their unit file is absent'
TEST_LOADED_UNITS='unifi-jpix-other-agent.service loaded active running Other agent' \
TEST_UNIT_ACTIVE=active assert_blocked
unset TEST_LOADED_UNITS TEST_UNIT_ACTIVE

test_start 'installer rejects malformed inventory entries without mutation'
TEST_UNIT_FILES='../unexpected.service enabled' assert_blocked
unset TEST_UNIT_FILES

test_start 'installer stages an immutable release with only current automation'
TEST_UNIT_FILES='unifi-jpix-bootstrap.service enabled
unifi-jpix-reconcile.service static
unifi-jpix-reconcile.timer enabled
unifi-jpix-event-monitor.service enabled
unifi-jpix-udapi-reconcile.service static
unifi-jpix-udapi.path enabled' \
TEST_UNIT_ACTIVE=active run_install >/dev/null
unset TEST_UNIT_FILES TEST_UNIT_ACTIVE
assert_file_exists "$TMP/root/releases/v2.0.0-dev/release-manifest.json"

test_start 'installer accepts stopped disabled automation without altering it'
TEST_UNIT_FILES='unifi-jpix-other-agent.service disabled' run_install >/dev/null
unset TEST_UNIT_FILES
if grep -E '(stop|disable).*unifi-jpix-other-agent' "$TMP/systemctl.log" >/dev/null; then
  fail 'installer modified another automation'
else
  pass
fi

test_start 'installer selects current release'
assert_eq "$(readlink "$TMP/root/current")" 'releases/v2.0.0-dev'
test_start 'installer leaves only an example configuration'
assert_file_exists "$TMP/root/config-v2.json.example"
[ ! -e "$TMP/root/config-v2.json" ] || fail 'installer created a live configuration'
test_start 'installer does not enable or activate bootstrap by default'
case $(cat "$TMP/systemctl.log") in
  *'enable unifi-jpix-bootstrap.service'*|*'restart unifi-jpix-bootstrap.service'*) fail 'installer enabled bootstrap by default' ;;
  *) pass ;;
esac

cp "$TMP/root/config-v2.json.example" "$TMP/root/config-v2.json"
chmod 600 "$TMP/root/config-v2.json"
test_start 'installer reuses the same immutable release for explicit activation'
run_install --activate >/dev/null
assert_contains "$(cat "$TMP/systemctl.log")" 'enable unifi-jpix-bootstrap.service'
assert_contains "$(cat "$TMP/systemctl.log")" 'restart unifi-jpix-bootstrap.service'

test_start 'bootstrap verifies the release and marks it verified after health'
UNIFI_JPIX_ROOT="$TMP/root" \
UNIFI_JPIX_UNIT_DIR="$TMP/units" \
UNIFI_JPIX_BIN_DIR="$TMP/bin-installed" \
UNIFI_JPIX_SYSTEMCTL="$TMP/bin/systemctl" \
  "$TMP/root/current/scripts/unifi-jpix-bootstrap.sh" >/dev/null
assert_eq "$(readlink "$TMP/root/verified")" 'releases/v2.0.0-dev'
test_start 'bootstrap restores the CLI symlink'
assert_file_exists "$TMP/bin-installed/unifi-jpix"

test_start 'release builder produces a verifiable detached signature'
openssl genrsa -out "$TMP/private.pem" 2048 >/dev/null 2>&1
openssl rsa -in "$TMP/private.pem" -pubout -out "$TMP/public.pem" >/dev/null 2>&1
"$REPO/scripts/build-v2-release.sh" v2.1.0 "$TMP/private.pem" "$TMP/output" >/dev/null
openssl dgst -sha256 -verify "$TMP/public.pem" -signature "$TMP/output/v2.1.0.sha256.sig" "$TMP/output/v2.1.0.sha256" >/dev/null
pass

test_start 'installed and signed releases contain only the supported runtime scripts'
python3 - "$TMP/root/current" "$TMP/output/v2.1.0.tar.gz" <<'PY'
import json
from pathlib import Path
import sys
import tarfile
expected = {"scripts/unifi-jpix-bootstrap.sh", "scripts/unifi-jpix-event-monitor.sh"}
installed = Path(sys.argv[1])
manifest = json.loads((installed / "release-manifest.json").read_text())
assert {name for name in manifest["files"] if name.startswith("scripts/")} == expected
with tarfile.open(sys.argv[2]) as archive:
    signed_manifest = json.load(archive.extractfile("v2.1.0/release-manifest.json"))
    assert {name for name in signed_manifest["files"] if name.startswith("scripts/")} == expected
PY
pass
test_finish
