# v1 retirement audit

## 状態

2026-09-14、commit `9ea0931`とUDM Proの事前調査後、利用者の明示承認を受けて以下の廃止を実施しました。

1. repositoryの旧v1資産89ファイルを削除し、CLI移行処理とv1復帰scriptの梱包を撤去しました。Git履歴には残ります。
2. source installerで `v2.0.0-dev.23` を配置しました。current/verifiedはdev.23、previousはdev.22です。署名済み公開releaseではありません。
3. 以下で限定したUDMの旧unit・script・設定・state計24ファイルを削除し、systemdを再読み込みしました。旧config・stateの削除はGitから復元できません。
4. v2のhealth、通信、保護対象の内容一致を再検証し、試行用v2 release復旧timerを解除しました。再起動、実端末の再試験、実rollback、commit/pushは行っていません。

ローカルとUDMでPython 80テスト・v2 shell suiteが成功しました。ローカルのshell構文検査・ShellCheck・diff検査も成功しました。実機ではIPv4/IPv6 HTTPS 204、通常DNS・WAN専用DNS・Content Filter経由DNSのA/AAAA・UDP/TCPがすべてNOERRORです。最終statusはhealthy・pending repairs 0、boot persistenceはready、provider pendingはありません。配布用署名鍵は未登録のままです。

v2 config、credential、activation-confirmed marker、UDAPI設定全体、非project IPv4/IPv6 firewallの正規化digest、残した14個の診断ファイルは前後一致しました。旧5 unitはnot-found、調査範囲の旧実行hook/processはありません。dev.23と復旧先dev.22のmanifest・managed capabilityは検証済みです。旧不変release・過去のsource stagingは保持しているため、その内部の休眠v1コードまで消去したわけではありません。

## 削除前の実機調査

| 項目 | 結果 |
| --- | --- |
| 現行release | current/verifiedはdev.22、previousはdev.21 |
| release整合性 | 両releaseのmanifest検証成功、managed adapterのcapability 2を確認。rollbackの実行試験ではない |
| v2の状態 | unifi-managed、healthy、pending repairs 0 |
| v1のunit | apply、trigger、watch、update service、update timerの5つともinactive/dead。trigger/watch/timerはdisabled、残る2 serviceはstatic |
| v1の稼働参照 | 実行プロセス0、v1 tag付きIPv4/IPv6 firewall rule各0、旧専用tableのroute・policy-rule参照各0 |
| 起動経路 | 調査したsystemd/cron/on-boot/rc.local/CLI配置範囲では、停止中のv1 unit以外にv1実行参照なし。v2 unitのdrop-inなし |
| credential | 現行v2は独立したcredentials-v2.jsonを参照し、旧config/provider-update.confに依存しない。内容は非公開 |
| 通信 | IPv4/IPv6 HTTPS 204、WAN専用DNSとContent Filter経由DNSでYouTubeがNOERROR |

この調査は再起動試験ではなく、任意の外部管理ツールからの将来の手動実行まで否定するものではありません。

## 先に取り除く依存関係

1. `src/unifi_jpix/cli.py`の`migrate-v1`コマンド、`_migrate_v1()`とdispatch。通常のv2 reconcile/managed integration/rollbackは別経路です。
2. `scripts/unifi-jpix-timed-recovery.sh`。これはv2 release rollbackではなく、v2を停止してv1 applyを呼ぶ旧移行専用scriptです。
3. `scripts/install-v2.sh`と`scripts/build-v2-release.sh`による同scriptの梱包。
4. v1 migrationテストと旧ファイルの存在を要求するrepository contract、README・旧導入/復旧手順。

新installerは稼働中のv1との併存を拒否し、暗黙にv1の`off`や切替を実行しない方針とします。今後v1から移行する利用者向けには、廃止前のGit revisionを明記し、新版に実行可能なv1復帰経路を残さないようにします。

## リポジトリの廃止範囲

| 区分 | 範囲 |
| --- | --- |
| v1実装 | `scripts/install.sh`と`unifi-jpix-tunnel-repair-`で始まる8 script（apply/diag/lib/preflight/trigger/update/wait-wan/watch） |
| v1 systemd | `systemd/`の5 unit |
| v1設定雛形 | `config/gateway.conf.example`、`config/routed-networks.conf.example`、`config/provider-update.conf.example`、`config/verified-platforms.conf` |
| v1専用テスト | apply/diag/install/ipv6/lib/preflight/systemd_apply/systemd_runtime/trigger/update/wait_wan/watchの12 shell testと、58個のstub/fixture |
| v1移行 | CLIの該当部分、旧timed-recovery、移行専用のPythonテスト |

`tests/testlib.sh`はv2 shell testも使用しているため残します。`tests/run.sh`、repository contract、v2 installer/event monitorテスト、`tests_v2`全体は削除せず、v1部分のみ整理します。JPIX方式の説明と過去の検証証跡は、現行手順と区別して残します。廃止する実装はGit履歴から復元できます。

## UDMの廃止範囲と除外対象

基準rootは`/data/unifi-jpix-tunnel-repair`です。新v2 releaseの配置・通信確認後、実行直前に所有権と参照を再確認します。

- `/etc/systemd/system/`の上記v1 5 unit。
- root直下の`scripts/`で確認したv1 9 file。
- root直下の`config/`で確認した旧設定・雛形7 file。旧provider credentialを含むため、公開archive・Gitへコピーしません。
- `state/last-trigger`、`state/last-provider-update.state`、`state/original-tunnel.env`の旧runtime state。

`state/`にはさらに14個の診断ファイルがあります。v2運用時の記録が混在する可能性があるため、ディレクトリ一括削除の対象にしません。過去のsource staging directory、古いv2 releaseの一括清掃も今回のv1廃止から分離します。

次のものは削除しません。

- 使用中のUniFi管理WANトンネル、そのroute・rule・firewall・DNS・Content Filter。
- v2の`config-v2.json`、`credentials-v2.json`、`state-v2/`、CLI symlink、systemd-v2のunit。
- `current`、`verified`、`previous`と、それらが指すrelease全体。
- `state-v2/activation-confirmed`。旧releaseに残る移行復帰scriptの誤実行防止にも使用されます。

**既存release内のファイルは直接削除しません。** dev.21/dev.22のmanifestには旧timed-recoveryも含まれるため、削除するとboot/rollbackのchecksum検証が失敗します。v1の実行入口を梱包しない新releaseへ切り替え、互換性のある旧v2 releaseは履歴・復旧用途に不変で保持します。保持した旧releaseにv1関連コードが文字列として残ることと、稼働中のv1 automationは区別します。

## 実施順序と停止条件

1. repositoryのv1依存を解消し、v2-onlyのinstaller、CLI、release梱包、rollbackテストを通す。
2. 新releaseを配置し、現行v2設定の保持、IPv4/IPv6、フィルターDNS、起動unit、復旧先のmanifest/互換性を確認する。
3. 上記の明示対象だけを削除または非実行のprivate退避領域へ移し、unit登録を再読み込みする。v1の`off`は実行しない。
4. v1 unit/process/起動参照の消失とv2通信維持を再確認する。Git commit/pushやUDM再起動は別途明示された場合に行う。

旧config・stateの完全削除はGitから復元できません。実削除前に、対象とv1復帰不可になることを確認します。v2のhealth不良、復旧先不明、稼働中の旧unit、未知の所有権・参照を見つけた場合は削除しません。
