#!/bin/sh
set -eu

SYSTEMCTL=${UNIFI_JPIX_SYSTEMCTL:-systemctl}
IP=${UNIFI_JPIX_IP:-ip}
DEBOUNCE=${UNIFI_JPIX_DEBOUNCE_SECONDS:-1}
RUNTIME_DIR=${UNIFI_JPIX_RUNTIME_DIR:-/run/unifi-jpix}

case $DEBOUNCE in ''|*[!0-9]*|0) printf '%s\n' 'invalid debounce interval' >&2; exit 2 ;; esac
command -v "$IP" >/dev/null 2>&1 || exit 1
command -v "$SYSTEMCTL" >/dev/null 2>&1 || exit 1
install -d -m 0700 "$RUNTIME_DIR"
rmdir "$RUNTIME_DIR/debounce" 2>/dev/null || :

# ip monitor exits when netlink becomes unavailable; systemd restarts this
# service. Reconcile is a flock-serialized oneshot, so burst events collapse.
"$IP" monitor link address route rule | while IFS= read -r _event; do
  if mkdir "$RUNTIME_DIR/debounce" 2>/dev/null; then
    (
      sleep "$DEBOUNCE"
      "$SYSTEMCTL" start --no-block unifi-jpix-reconcile.service || :
      rmdir "$RUNTIME_DIR/debounce" 2>/dev/null || :
    ) &
  fi
done
