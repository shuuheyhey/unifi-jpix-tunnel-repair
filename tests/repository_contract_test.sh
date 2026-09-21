#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/testlib.sh"

for path in README.md LICENSE NOTICE.md SECURITY.md CONTRIBUTING.md .gitignore \
  docs/architecture.md docs/configuration.md docs/installation.md docs/rollback.md \
  docs/service-and-protocols.md docs/troubleshooting.md docs/udm-pro-setup.md docs/validation.md docs/guide.md \
  config/config-v2.json.example config/credentials-v2.json.example \
  bin/unifi-jpix scripts/install-v2.sh scripts/build-v2-release.sh \
  scripts/unifi-jpix-bootstrap.sh scripts/unifi-jpix-event-monitor.sh \
  systemd-v2/unifi-jpix-bootstrap.service systemd-v2/unifi-jpix-reconcile.service \
  systemd-v2/unifi-jpix-reconcile.timer systemd-v2/unifi-jpix-event-monitor.service \
  systemd-v2/unifi-jpix-udapi-reconcile.service systemd-v2/unifi-jpix-udapi.path \
  src/unifi_jpix/__init__.py src/unifi_jpix/core.py src/unifi_jpix/cli.py src/unifi_jpix/release.py \
  tests/event_monitor_v2_test.sh tests/install_v2_test.sh \
  tests_v2/test_cli.py tests_v2/test_core.py tests_v2/test_release.py \
  tests_v2/test_repository.py \
  .github/pull_request_template.md \
  .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/config.yml
do
  test_start "repository contains $path"
  assert_file_exists "$ROOT/$path"
done

test_start 'v2 uses a project-owned tunnel'
assert_contains "$(cat "$ROOT/docs/guide.md")" 'project-owned tunnel'

test_start 'event monitor does not create a bootstrap start cycle'
if grep -Eq '^After=.*unifi-jpix-bootstrap\.service' "$ROOT/systemd-v2/unifi-jpix-event-monitor.service"; then
  fail 'event monitor waits for the bootstrap that synchronously starts it'
else
  pass
fi

test_start 'v2 config does not accept a WAN interface'
if grep -Eq '"wan(_interface)?"[[:space:]]*:' "$ROOT/config/config-v2.json.example"; then
  fail 'v2 config contains a fixed WAN selector'
else
  pass
fi

test_start 'README identifies the project as unofficial and experimental'
assert_contains "$(cat "$ROOT/README.md")" '非公式・実験的'

test_start 'README limits support to JPIX static IPv4 one-address service'
assert_contains "$(cat "$ROOT/README.md")" 'JPIX「v6プラス」固定IPサービスの固定IPv4 1個'

test_start 'README explicitly excludes ordinary MAP-E v6 Plus'
assert_contains "$(cat "$ROOT/README.md")" '通常の「v6プラス」で使用するMAP-E'

test_start 'README explicitly excludes HB46PP'
assert_contains "$(cat "$ROOT/README.md")" 'HB46PP'

test_start 'protocol guide documents the JPNE connection diagnostic page'
assert_contains "$(cat "$ROOT/docs/service-and-protocols.md")" 'http://wa.kiriwake.jpne.co.jp/'

test_start 'protocol guide distinguishes the displayed port from an IPIP tunnel port'
assert_contains "$(cat "$ROOT/docs/service-and-protocols.md")" '表示portは「IPIP tunnel port」ではありません'

test_start 'validation marks connection-test captures as unsafe to share'
assert_contains "$(cat "$ROOT/docs/validation.md")" '接続判定ページのcopyやscreenshotは共有安全ではありません'

test_start 'tracked public tree excludes internal plans and checkpoints'
if find "$ROOT" -path "$ROOT/.git" -prune -o \
  \( -path '*/docs/superpowers/*' -o -name 'checkpoint-*' -o -name '*live-validation*' \) -print | grep . >/dev/null; then
  fail 'internal operational artifact found'
else
  pass
fi

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
