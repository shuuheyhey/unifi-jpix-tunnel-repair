#!/bin/sh
set -u
umask 077

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

TRIGGER=$ROOT/systemd/v6plus-trigger.service
WATCH=$ROOT/systemd/v6plus-watch.service
UPDATE=$ROOT/systemd/v6plus-update.service
TIMER=$ROOT/systemd/v6plus-update.timer

for unit in "$TRIGGER" "$WATCH" "$UPDATE" "$TIMER"; do
  test_start "runtime unit exists: ${unit##*/}"
  if [ -f "$unit" ]; then pass; else fail "missing unit $unit"; fi
done
if [ ! -f "$TRIGGER" ] || [ ! -f "$WATCH" ] || [ ! -f "$UPDATE" ] || [ ! -f "$TIMER" ]; then
  test_finish
fi

unit_values() {
  unit=$1
  wanted_section=$2
  wanted_key=$3
  awk -v wanted_section="$wanted_section" -v wanted_key="$wanted_key" '
    /^[[:space:]]*\[/ {
      section=$0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      next
    }
    section == wanted_section && index($0, wanted_key "=") == 1 {
      print substr($0, length(wanted_key) + 2)
    }
  ' "$unit"
}

for unit in "$TRIGGER" "$WATCH"; do
  name=${unit##*/}
  test_start "$name requires successful boot apply"
  assert_eq "$(unit_values "$unit" Unit Requires)" 'v6plus-apply.service'
  test_start "$name starts after boot apply"
  assert_eq "$(unit_values "$unit" Unit After)" 'v6plus-apply.service'
  test_start "$name is a simple long-running service"
  assert_eq "$(unit_values "$unit" Service Type)" simple
  test_start "$name always restarts"
  assert_eq "$(unit_values "$unit" Service Restart)" always
  test_start "$name restart delay is five seconds"
  assert_eq "$(unit_values "$unit" Service RestartSec)" 5
  test_start "$name is explicitly enableable for multi-user boot"
  assert_eq "$(unit_values "$unit" Install WantedBy)" multi-user.target
  test_start "$name unit mode is 0644"
  assert_eq "$(stat -c %a "$unit")" 644
  test_start "$name runs with the hardened root boundary"
  assert_eq "$(unit_values "$unit" Service User):$(unit_values "$unit" Service Group):$(unit_values "$unit" Service UMask):$(unit_values "$unit" Service NoNewPrivileges)" 'root:root:0077:yes'
done

test_start 'trigger service invokes the production trigger path'
assert_eq "$(unit_values "$TRIGGER" Service ExecStart)" '/data/v6plus/scripts/v6plus-trigger.sh'
test_start 'watch service invokes the production watchdog path'
assert_eq "$(unit_values "$WATCH" Service ExecStart)" '/data/v6plus/scripts/v6plus-watch.sh'

test_start 'update tick waits until apply ordering'
assert_eq "$(unit_values "$UPDATE" Unit After)" 'v6plus-apply.service'
test_start 'update tick is a oneshot'
assert_eq "$(unit_values "$UPDATE" Service Type)" oneshot
test_start 'update tick runs with the hardened root boundary'
assert_eq "$(unit_values "$UPDATE" Service User):$(unit_values "$UPDATE" Service Group):$(unit_values "$UPDATE" Service UMask):$(unit_values "$UPDATE" Service NoNewPrivileges)" 'root:root:0077:yes'
test_start 'update tick delegates interval authority to the updater without force'
assert_eq "$(unit_values "$UPDATE" Service ExecStart)" '/data/v6plus/scripts/v6plus-update.sh'
test_start 'update oneshot is not independently installable'
assert_eq "$(unit_values "$UPDATE" Install WantedBy)" ''

test_start 'timer has the approved scheduler-only description'
assert_eq "$(unit_values "$TIMER" Unit Description)" 'Check whether the JPIX v6plus address update is due'
test_start 'timer first tick is ten minutes after boot'
assert_eq "$(unit_values "$TIMER" Timer OnBootSec)" 10min
test_start 'timer ticks once per minute'
assert_eq "$(unit_values "$TIMER" Timer OnUnitActiveSec)" 1min
test_start 'timer accuracy is ten seconds'
assert_eq "$(unit_values "$TIMER" Timer AccuracySec)" 10s
test_start 'timer catches up after downtime'
assert_eq "$(unit_values "$TIMER" Timer Persistent)" true
test_start 'timer targets only the interval-gated update service'
assert_eq "$(unit_values "$TIMER" Timer Unit)" v6plus-update.service
test_start 'timer is explicitly enableable for timers target'
assert_eq "$(unit_values "$TIMER" Install WantedBy)" timers.target
test_start 'update unit and timer modes are 0644'
assert_eq "$(stat -c %a "$UPDATE"):$(stat -c %a "$TIMER")" '644:644'

test_finish
