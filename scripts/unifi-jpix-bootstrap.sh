#!/bin/sh
set -eu
umask 077

ROOT=${UNIFI_JPIX_ROOT:-/data/unifi-jpix-tunnel-repair}
CURRENT=$ROOT/current
UNIT_DIR=${UNIFI_JPIX_UNIT_DIR:-/etc/systemd/system}
BIN_DIR=${UNIFI_JPIX_BIN_DIR:-/usr/local/bin}
SYSTEMCTL=${UNIFI_JPIX_SYSTEMCTL:-systemctl}

die() { printf 'unifi_jpix_boot status=failed reason=%s\n' "$1" >&2; exit 1; }

[ -L "$CURRENT" ] || die current-release-missing
CURRENT_REAL=$(readlink -f "$CURRENT") || die current-release-invalid
case $CURRENT_REAL in "$ROOT"/releases/*) ;; *) die current-release-unsafe ;; esac
[ -f "$CURRENT_REAL/release-manifest.json" ] || die release-manifest-missing
command -v python3 >/dev/null 2>&1 || die python3-missing

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$CURRENT_REAL/src python3 - "$ROOT" "$CURRENT_REAL" <<'PY' || exit 1
from pathlib import Path
import sys
from unifi_jpix.release import ReleaseManager
ReleaseManager(Path(sys.argv[1])).verify_installed(Path(sys.argv[2]))
PY

install -d -m 0755 "$UNIT_DIR"
for unit in "$CURRENT_REAL"/systemd-v2/*; do
  [ -f "$unit" ] || continue
  install -m 0644 "$unit" "$UNIT_DIR/${unit##*/}"
done
install -d -m 0755 "$BIN_DIR"
ln -sfn "$CURRENT/bin/unifi-jpix" "$BIN_DIR/unifi-jpix"

"$SYSTEMCTL" daemon-reload
"$SYSTEMCTL" enable unifi-jpix-reconcile.timer unifi-jpix-event-monitor.service >/dev/null
if ! "$SYSTEMCTL" start unifi-jpix-reconcile.service; then
  [ "${UNIFI_JPIX_ROLLBACK_ATTEMPTED:-0}" = 0 ] || die release-health-failed
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$CURRENT_REAL/src python3 - "$ROOT" <<'PY' || die release-rollback-failed
from pathlib import Path
import sys
from unifi_jpix.release import ReleaseManager
ReleaseManager(Path(sys.argv[1])).rollback()
PY
  UNIFI_JPIX_ROLLBACK_ATTEMPTED=1
  export UNIFI_JPIX_ROLLBACK_ATTEMPTED
  exec "$ROOT/current/scripts/unifi-jpix-bootstrap.sh"
fi
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$CURRENT_REAL/src python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
from unifi_jpix.release import ReleaseManager
ReleaseManager(Path(sys.argv[1])).mark_verified()
PY
"$SYSTEMCTL" start unifi-jpix-reconcile.timer unifi-jpix-event-monitor.service
printf '%s\n' 'unifi_jpix_boot status=ready'
