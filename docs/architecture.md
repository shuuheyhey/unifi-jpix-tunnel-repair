# Architecture

Python CLIを共通の実行入口とし、systemdから繰り返しdesired stateへ収束させます。version文字列の一致ではなく、BR宛て経路、link、bridgeのprefix、firewall hookと所有権を検査します。[設定](configuration.md)・[操作](guide.md)・[復旧](rollback.md)は別文書です。

## Componentと所有境界

| Component | 責務 |
| --- | --- |
| [cli.py](../src/unifi_jpix/cli.py) / [launcher](../bin/unifi-jpix) | CLI引数、結果表示、mode別reconciler、release操作の呼び出し |
| [core.py](../src/unifi_jpix/core.py) | schema、capability、資源割当、standalone tunnel、route/rule/firewall、transaction、provider通知 |
| [router.py](../src/unifi_jpix/router.py) / [wan_policy.py](../src/unifi_jpix/wan_policy.py) | opt-inの単一WAN経路・monitor補正、standaloneと既存WAN policyの接続 |
| [managed.py](../src/unifi_jpix/managed.py) / [integration.py](../src/unifi_jpix/integration.py) | 明示enrollmentした管理WANの限定補正、移行・確認・未確定時の復旧 |
| [release.py](../src/unifi_jpix/release.py) / [bootstrap](../scripts/unifi-jpix-bootstrap.sh) | release検証・選択、unit復元、初回reconcile、verified昇格 |

standaloneは専用tunnel、専用table、連続policy priority、project tag付きruleとendpoint addressを管理します。UniFi管理トンネルは変更しません。router recoveryを有効にした場合だけ、単一WANのmonitor bind flagも限定補正します。

unifi-managedはenrollment済みWANの限定fieldとkernel endpointを補正します。UniFiは論理WANのidentityとnative route/ruleを引き続き所有します。両modeは同時使用しません。対象外LANやtagのないruleを推測で削除せず、未知の構成では変更前に拒否します。具体的なWAN field・policy境界は[運用ガイド](guide.md)を参照してください。

## 永続レイアウト

```text
/data/unifi-jpix-tunnel-repair/
  releases/<version>/           不変のcode・unit・manifest
  current -> releases/...      選択中release
  verified -> releases/...     bootstrap health成功release
  previous -> releases/...     切替前release（健全性の保証ではない）
  config-v2.json                契約・LAN・mode設定
  credentials-v2.json           provider認証情報（別パスも指定可能）
  release-signing-public.pem    任意の登録済みtrust anchor
  state-v2/                    private runtime・health・所有権・移行記録
```

state directoryはmode `0700`、JSONは`0600`です。runtimeにはendpointや割当資源が含まれ、共有用ではありません。`transaction.json`は理由・進捗、`health.json`は直近結果、`quarantine.json`は隔離理由、`pending-provider.json`は通知の再試行状態です。これらを削除して再検出を強制すると所有権の証拠を失う可能性があります。

## 起動・event・定期実行

| Unit | 起動条件・役割 |
| --- | --- |
| `unifi-jpix-bootstrap.service` | boot時。manifest確認、unitコピー、CLI symlink配置、初回reconcile、verified昇格と監視開始 |
| `unifi-jpix-reconcile.service` | 通常のoneshot。`reconcile --retry`、timeout 180秒 |
| `unifi-jpix-reconcile.timer` | boot後2分を初回目安に、対象serviceがinactiveになってから5分。`AccuracySec=10s` |
| `unifi-jpix-event-monitor.service` | `ip monitor link address route rule`。1秒の集約窓を経て通常oneshotを起動。監視processは失敗時に再起動 |
| `unifi-jpix-udapi.path` | UniFiのUDAPI stateファイル変更を監視し、専用oneshotを起動 |
| `unifi-jpix-udapi-reconcile.service` | 1秒待機後に`reconcile --retry`。timeout 210秒 |

enableするのはbootstrap・timer・event monitor・UDAPI pathの4つです。reconcileの2serviceは必要時だけ実行するため、平常時の`inactive`は異常ではありません。UDAPI監視対象は`/data/udapi-config/ubios-udapi-server/ubios-udapi-server.state`です。

各reconcileは同じ`operation.lock`をnon-blocking flockで取得します。installer、releaseのdownload・symlink切替までを共通lockで直列化しているわけではありません。更新時の監視停止・実行中処理の終了確認は[Installation](installation.md#稼働中のsource更新)に従います。

bootstrap unitやenablement自体が失われると、bootで自己復元できません。unitの再配置もファイル単位の`install`であり、一式の原子的切替ではありません。OS更新後は`doctor`に加え実際のunit状態と疎通を確認します。

## Transactionと通知

1. lock取得後にcapability・所有権・変更予定を検査します。前提不成立とforeign conflictではnetworkを変更せず、失敗・隔離理由を記録します。
2. actionを適用し、理由と進捗をjournalへ記録します。逆操作は実行中のメモリに保持します。
3. health成功後にruntimeとhealthを記録し、隔離を解除します。失敗時は今回記録した逆操作を逆順で試みます。
4. endpoint変更またはpending時だけprovider通知を行います。通知のtransport失敗は独立して再試行し、正常なdata planeは戻しません。

SIGINT/SIGTERMは逆操作の対象ですが、電源断・SIGKILL後のjournal replayと完全なruntime snapshot復元は未実装です。隔離記録は以後のreconcileを永続停止するcircuit breakerではありません。毎回前提と所有権を再検査します。逆操作失敗時は[復旧手順](rollback.md#適用中の失敗)に従い、追加の自動処理を管理者が止めて調べます。

任意webhookはproject、major version、model family、状態、reason codeだけを送ります。実address・CIDR・credentialはpayloadへ含めません。正確な導入releaseや実機modelを報告する仕組みではなく、配送成功を保証する永続queueもありません。

## Releaseの検証

source installerはローカルsourceからSHA-256 manifestを作ります。これは内容の整合性確認であり、入手元の署名検証ではありません。既存releaseを上書きしないため、source更新には別release名を使います。

署名付き`upgrade`は、登録済み公開鍵でchecksumファイルのdetached signatureを検証し、archiveのSHA-256、安全な展開、全fileのmanifestを確認します。その後`current`を切り替えbootstrapを実行します。配布鍵はこのcheckoutに同梱しておらず、鍵の信頼確認と登録は管理者の作業です。

ReleaseManagerのsymlink切替はtemporary linkからのreplaceですが、source installerの切替やunitコピーを含む導入全体が原子的という意味ではありません。`verified`も、そのreleaseのbootstrap healthが成功した記録であり、全機種・障害・実端末・provider通知の合格印ではありません。
