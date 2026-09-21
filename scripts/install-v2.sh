#!/bin/sh
set -eu
umask 077

SOURCE_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
ROOT=${UNIFI_JPIX_ROOT:-/data/unifi-jpix-tunnel-repair}
UNIT_DIR=${UNIFI_JPIX_UNIT_DIR:-/etc/systemd/system}
VERSION=${UNIFI_JPIX_INSTALL_VERSION:-v2.0.0-dev}
ACTIVATE=0
PUBLIC_KEY=

usage() { printf 'usage: %s [--activate] [--release-public-key FILE]\n' "$0" >&2; }
while [ "$#" -gt 0 ]; do
  case $1 in
    --activate) [ "$ACTIVATE" -eq 0 ] || { usage; exit 2; }; ACTIVATE=1; shift ;;
    --release-public-key) [ -z "$PUBLIC_KEY" ] && [ "$#" -ge 2 ] || { usage; exit 2; }; PUBLIC_KEY=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'installer must run as root' >&2; exit 1; }
printf '%s\n' "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' || { printf '%s\n' 'invalid install version' >&2; exit 2; }
for command in python3 systemctl install awk sort sed; do command -v "$command" >/dev/null 2>&1 || { printf 'missing dependency: %s\n' "$command" >&2; exit 1; }; done

# Inspect project-scoped automation before modifying files or release links.
# Additional enabled/running units could race the reconciler. Never stop them.
unit_files=$(LC_ALL=C systemctl list-unit-files --no-legend --no-pager 'unifi-jpix*' 2>/dev/null) || {
  printf '%s\n' 'unifi_jpix_install status=blocked reason=automation-inventory-unavailable' >&2; exit 1;
}
loaded_units=$(LC_ALL=C systemctl list-units --all --plain --no-legend --no-pager 'unifi-jpix*' 2>/dev/null) || {
  printf '%s\n' 'unifi_jpix_install status=blocked reason=automation-inventory-unavailable' >&2; exit 1;
}
units=$(printf '%s\n%s\n' "$unit_files" "$loaded_units" | awk 'NF {print $1}' | sort -u)
for unit in $units; do
  case $unit in
    unifi-jpix-bootstrap.service|unifi-jpix-reconcile.service|unifi-jpix-reconcile.timer|unifi-jpix-event-monitor.service|unifi-jpix-udapi-reconcile.service|unifi-jpix-udapi.path) continue ;;
  esac
  case $unit in
    *[!A-Za-z0-9@_.:-]*|unifi-jpix) printf '%s\n' 'unifi_jpix_install status=blocked reason=automation-inventory-invalid' >&2; exit 1 ;;
    unifi-jpix*) ;;
    *) printf '%s\n' 'unifi_jpix_install status=blocked reason=automation-inventory-invalid' >&2; exit 1 ;;
  esac
  properties=$(systemctl show "$unit" -p LoadState -p ActiveState -p UnitFileState 2>/dev/null) || {
    printf '%s\n' 'unifi_jpix_install status=blocked reason=automation-state-unknown' >&2; exit 1;
  }
  load=$(printf '%s\n' "$properties" | sed -n 's/^LoadState=//p')
  active=$(printf '%s\n' "$properties" | sed -n 's/^ActiveState=//p')
  enabled=$(printf '%s\n' "$properties" | sed -n 's/^UnitFileState=//p')
  case "$load:$active:$enabled" in
    not-found:inactive:|not-found:inactive:not-found|loaded:inactive:disabled|loaded:inactive:static|masked:inactive:masked) ;;
    *) printf '%s\n' 'unifi_jpix_install status=blocked reason=conflicting-automation' >&2; exit 1 ;;
  esac
done

install -d -m 0755 "$ROOT" "$ROOT/releases"
install -d -m 0700 "$ROOT/state-v2"
if [ -z "$PUBLIC_KEY" ] && [ -f "$SOURCE_ROOT/config/release-signing-public.pem" ]; then
  PUBLIC_KEY=$SOURCE_ROOT/config/release-signing-public.pem
fi
if [ -n "$PUBLIC_KEY" ]; then
  [ -f "$PUBLIC_KEY" ] && [ ! -L "$PUBLIC_KEY" ] || { printf '%s\n' 'release public key is invalid' >&2; exit 1; }
  command -v openssl >/dev/null 2>&1 || { printf '%s\n' 'missing dependency: openssl' >&2; exit 1; }
  command -v cmp >/dev/null 2>&1 || { printf '%s\n' 'missing dependency: cmp' >&2; exit 1; }
  openssl pkey -pubin -in "$PUBLIC_KEY" -noout >/dev/null 2>&1 || { printf '%s\n' 'release public key is invalid' >&2; exit 1; }
  if [ -f "$ROOT/release-signing-public.pem" ] && ! cmp -s "$PUBLIC_KEY" "$ROOT/release-signing-public.pem"; then
    printf '%s\n' 'refusing to replace the enrolled release public key' >&2
    exit 1
  fi
  if [ ! -f "$ROOT/release-signing-public.pem" ]; then
    install -m 0644 "$PUBLIC_KEY" "$ROOT/release-signing-public.pem"
  fi
fi
RELEASE=$ROOT/releases/$VERSION
STAGE=
if [ -e "$RELEASE" ] || [ -L "$RELEASE" ]; then
  [ -d "$RELEASE" ] && [ ! -L "$RELEASE" ] && [ -f "$RELEASE/release-manifest.json" ] || { printf '%s\n' 'installed release is invalid' >&2; exit 1; }
fi
if [ ! -d "$RELEASE" ]; then
  STAGE=$(mktemp -d "$ROOT/.install.XXXXXX")
  cleanup() { [ -z "$STAGE" ] || [ ! -d "$STAGE" ] || rm -rf -- "$STAGE"; }
  trap cleanup EXIT HUP INT TERM

  install -d -m 0755 "$STAGE/bin" "$STAGE/scripts" "$STAGE/src/unifi_jpix" "$STAGE/systemd-v2"
  install -m 0755 "$SOURCE_ROOT/bin/unifi-jpix" "$STAGE/bin/unifi-jpix"
  install -m 0755 "$SOURCE_ROOT/scripts/unifi-jpix-bootstrap.sh" "$STAGE/scripts/unifi-jpix-bootstrap.sh"
  install -m 0755 "$SOURCE_ROOT/scripts/unifi-jpix-event-monitor.sh" "$STAGE/scripts/unifi-jpix-event-monitor.sh"
  install -m 0644 "$SOURCE_ROOT"/src/unifi_jpix/*.py "$STAGE/src/unifi_jpix/"
  install -m 0644 "$SOURCE_ROOT"/systemd-v2/* "$STAGE/systemd-v2/"

  PYTHONPATH=$STAGE/src python3 - "$STAGE" "$VERSION" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = {}
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name != "release-manifest.json":
        files[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
(root / "release-manifest.json").write_text(
    json.dumps({"schema": 1, "version": sys.argv[2], "files": files}, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  chmod 0644 "$STAGE/release-manifest.json"
  mv "$STAGE" "$RELEASE"
  STAGE=
fi

if [ -L "$ROOT/current" ]; then
  old=$(readlink "$ROOT/current")
  case $old in "releases/$VERSION") ;; releases/*) ln -sfn "$old" "$ROOT/previous" ;; esac
fi
ln -sfn "releases/$VERSION" "$ROOT/current"

if [ ! -f "$ROOT/config-v2.json" ]; then
  install -m 0600 "$SOURCE_ROOT/config/config-v2.json.example" "$ROOT/config-v2.json.example"
fi
install -d -m 0755 "$UNIT_DIR"
install -m 0644 "$SOURCE_ROOT/systemd-v2/unifi-jpix-bootstrap.service" "$UNIT_DIR/unifi-jpix-bootstrap.service"
systemctl daemon-reload
if [ "$ACTIVATE" -eq 1 ]; then
  [ -f "$ROOT/config-v2.json" ] || { printf '%s\n' 'config-v2.json is required for activation' >&2; exit 1; }
  systemctl enable unifi-jpix-bootstrap.service >/dev/null
  systemctl restart unifi-jpix-bootstrap.service
fi
printf 'unifi_jpix_install status=ready release=%s active=%s\n' "$VERSION" "$ACTIVATE"
