#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

for path in README.md LICENSE NOTICE.md SECURITY.md CONTRIBUTING.md .gitignore \
  docs/architecture.md docs/configuration.md docs/installation.md docs/rollback.md \
  docs/troubleshooting.md docs/validation.md \
  config/gateway.conf.example config/routed-networks.conf.example config/provider-update.conf.example \
  scripts/install.sh \
  scripts/unifi-jpix-tunnel-repair-apply.sh \
  scripts/unifi-jpix-tunnel-repair-diag.sh \
  scripts/unifi-jpix-tunnel-repair-lib.sh \
  scripts/unifi-jpix-tunnel-repair-trigger.sh \
  scripts/unifi-jpix-tunnel-repair-update.sh \
  scripts/unifi-jpix-tunnel-repair-wait-wan.sh \
  scripts/unifi-jpix-tunnel-repair-watch.sh \
  systemd/unifi-jpix-tunnel-repair-apply.service \
  systemd/unifi-jpix-tunnel-repair-trigger.service \
  systemd/unifi-jpix-tunnel-repair-update.service \
  systemd/unifi-jpix-tunnel-repair-update.timer \
  systemd/unifi-jpix-tunnel-repair-watch.service \
  .github/pull_request_template.md \
  .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/config.yml
do
  test_start "repository contains $path"
  assert_file_exists "$ROOT/$path"
done

test_start "main example contains route table"
assert_contains "$(cat "$ROOT/config/gateway.conf.example" 2>/dev/null || true)" 'ROUTE_TABLE=300'
test_start 'HTTPS is the update example default'
assert_contains "$(cat "$ROOT/config/provider-update.conf.example")" 'UPDATE_URL=https://'

test_start 'legacy HTTP is disabled in the update example'
assert_contains "$(cat "$ROOT/config/provider-update.conf.example")" 'ALLOW_INSECURE_UPDATE_HTTP=no'

test_start 'README identifies the project as unofficial and experimental'
assert_contains "$(cat "$ROOT/README.md")" '非公式・実験的'

test_start 'public artifacts do not use the legacy v6plus filename namespace'
if find "$ROOT/config" "$ROOT/scripts" "$ROOT/systemd" -maxdepth 1 -type f \
  \( -name 'v6plus-*' -o -name 'v6plus.env.example' -o -name 'networks.conf.example' -o -name 'update.env.example' \) \
  -print | grep . >/dev/null; then
  fail 'legacy public artifact filename found'
else
  pass
fi

test_start 'tracked public tree excludes internal plans and checkpoints'
if find "$ROOT" -path "$ROOT/.git" -prune -o \
  \( -path '*/docs/superpowers/*' -o -name 'checkpoint-*' -o -name '*live-validation*' \) -print | grep . >/dev/null; then
  fail 'internal operational artifact found'
else
  pass
fi

test_start 'main config example does not add obsolete ONU management addresses'
case $(cat "$ROOT/config/gateway.conf.example") in
  *192.168.1.1*|*192.168.1.2*) fail 'obsolete ONU management address found' ;;
  *) pass ;;
esac

test_start 'public documentation contains no complete deployment address literals'
if find "$ROOT/docs" "$ROOT/.github" -type f -print0 | \
  xargs -0 grep -IlE '(^|[^0-9])(1[0-9]{2}|2[0-4][0-9]|25[0-5])([.][0-9]{1,3}){3}([^0-9]|$)|[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){2,}' >/dev/null || \
  grep -IlE '(^|[^0-9])(1[0-9]{2}|2[0-4][0-9]|25[0-5])([.][0-9]{1,3}){3}([^0-9]|$)|[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){2,}' \
    "$ROOT/README.md" "$ROOT/NOTICE.md" "$ROOT/CONTRIBUTING.md" "$ROOT/SECURITY.md" >/dev/null; then
  fail 'address-like deployment metadata found outside tests and examples'
else
  pass
fi
test_finish
