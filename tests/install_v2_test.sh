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
EOF
chmod 755 "$TMP/bin/id" "$TMP/bin/systemctl"

run_install() {
  PATH="$TMP/bin:$PATH" \
  UNIFI_JPIX_ROOT="$TMP/root" \
  UNIFI_JPIX_UNIT_DIR="$TMP/units" \
    "$REPO/scripts/install-v2.sh" "$@"
}

test_start 'v2 installer stages an immutable release without activation'
run_install >/dev/null
assert_file_exists "$TMP/root/releases/v2.0.0-dev/release-manifest.json"
test_start 'v2 installer selects current release atomically'
assert_eq "$(readlink "$TMP/root/current")" 'releases/v2.0.0-dev'
test_start 'v2 installer leaves only an example configuration'
assert_file_exists "$TMP/root/config-v2.json.example"
[ ! -e "$TMP/root/config-v2.json" ] || fail 'installer created a live configuration'
test_start 'v2 installer installs bootstrap but does not enable or activate it by default'
case $(cat "$TMP/systemctl.log") in
  *'enable unifi-jpix-bootstrap.service'*|*'restart unifi-jpix-bootstrap.service'*) fail 'installer enabled bootstrap by default' ;;
  *) pass ;;
esac

cp "$TMP/root/config-v2.json.example" "$TMP/root/config-v2.json"
chmod 600 "$TMP/root/config-v2.json"
test_start 'v2 installer reuses the same immutable release for explicit activation'
run_install --activate >/dev/null
assert_contains "$(cat "$TMP/systemctl.log")" 'enable unifi-jpix-bootstrap.service'
assert_contains "$(cat "$TMP/systemctl.log")" 'restart unifi-jpix-bootstrap.service'

test_start 'v2 bootstrap verifies the release and marks it verified after health'
UNIFI_JPIX_ROOT="$TMP/root" \
UNIFI_JPIX_UNIT_DIR="$TMP/units" \
UNIFI_JPIX_BIN_DIR="$TMP/bin-installed" \
UNIFI_JPIX_SYSTEMCTL="$TMP/bin/systemctl" \
  "$TMP/root/current/scripts/unifi-jpix-bootstrap.sh" >/dev/null
assert_eq "$(readlink "$TMP/root/verified")" 'releases/v2.0.0-dev'
test_start 'v2 bootstrap restores the CLI symlink'
assert_file_exists "$TMP/bin-installed/unifi-jpix"

test_start 'v2 release builder produces a verifiable detached signature'
openssl genrsa -out "$TMP/private.pem" 2048 >/dev/null 2>&1
openssl rsa -in "$TMP/private.pem" -pubout -out "$TMP/public.pem" >/dev/null 2>&1
"$REPO/scripts/build-v2-release.sh" v2.1.0 "$TMP/private.pem" "$TMP/output" >/dev/null
openssl dgst -sha256 -verify "$TMP/public.pem" -signature "$TMP/output/v2.1.0.sha256.sig" "$TMP/output/v2.1.0.sha256" >/dev/null
pass

test_finish
