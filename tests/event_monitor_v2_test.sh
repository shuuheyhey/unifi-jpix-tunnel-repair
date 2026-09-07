#!/bin/sh
set -eu
umask 077

REPO=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$REPO/tests/testlib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cat >"$TMP/ip" <<'EOF'
#!/bin/sh
printf '%s\n' 'link event' 'address event' 'route event' 'rule event'
EOF
cat >"$TMP/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/systemctl.log"
EOF
chmod 755 "$TMP/ip" "$TMP/systemctl"

test_start 'v2 event monitor collapses a burst into one reconcile trigger'
UNIFI_JPIX_IP="$TMP/ip" \
UNIFI_JPIX_SYSTEMCTL="$TMP/systemctl" \
UNIFI_JPIX_RUNTIME_DIR="$TMP/run" \
UNIFI_JPIX_DEBOUNCE_SECONDS=1 \
  "$REPO/scripts/unifi-jpix-event-monitor.sh"
sleep 2
assert_eq "$(wc -l <"$TMP/systemctl.log" | tr -d ' ')" 1
test_start 'v2 event monitor uses the serialized oneshot service'
assert_contains "$(cat "$TMP/systemctl.log")" 'start --no-block unifi-jpix-reconcile.service'

test_finish
