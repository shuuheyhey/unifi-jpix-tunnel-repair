#!/bin/sh
set -eu
umask 077

ROOT=${UNIFI_JPIX_ROOT:-/data/unifi-jpix-tunnel-repair}
SYSTEMCTL=${UNIFI_JPIX_SYSTEMCTL:-systemctl}
MARKER=$ROOT/state-v2/activation-confirmed

if [ -f "$MARKER" ]; then
  printf '%s\n' 'unifi_jpix_recovery status=confirmed'
  exit 0
fi

"$SYSTEMCTL" disable --now unifi-jpix-bootstrap.service \
  unifi-jpix-reconcile.timer unifi-jpix-event-monitor.service \
  unifi-jpix-udapi.path unifi-jpix-udapi-reconcile.service >/dev/null 2>&1 || :

PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$ROOT/current/src python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
from unifi_jpix.core import Config, Reconciler
root = Path(sys.argv[1])
Reconciler(Config.load(root / "config-v2.json"), root).deactivate()
PY

"$ROOT/scripts/unifi-jpix-tunnel-repair-apply.sh" apply >/dev/null
"$SYSTEMCTL" enable --now \
  unifi-jpix-tunnel-repair-trigger.service \
  unifi-jpix-tunnel-repair-watch.service \
  unifi-jpix-tunnel-repair-update.timer >/dev/null
printf '%s\n' 'unifi_jpix_recovery status=restored-v1'
