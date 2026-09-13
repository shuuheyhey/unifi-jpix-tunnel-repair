# unifi-jpix-tunnel-repair

UniFi Dream Machine Pro系で、**JPIX「v6プラス」固定IPサービスの固定IPv4 1個**を終端するための非公式・実験的な実装です。v2はPython reconcilerと小さなPOSIX shell boot基盤で構成します。既定はproject-owned tunnelを使うstandalone方式で、明示移行した単一WANではUniFi管理トンネルを補正する統合方式も利用できます。従来のshell実装はv1移行元として残しています。

> [!WARNING]
> UDM Pro系はJPIXの公式対応機器ではありません。v2はversion文字列で停止せずcapabilityを確認しますが、実機gateとtimed recoveryなしの有効化は推奨しません。

新規導入とv1移行は[v2 reconciler](docs/v2.md)を正本とします。以下のv1資料は既存導入の保守と移行確認のために残しています。

## 対応範囲

このプロジェクトの対応対象は、次の条件を**すべて**満たす構成だけです。

| 項目 | 対応対象 |
| --- | --- |
| サービス | JPIX「v6プラス」固定IPサービス |
| IPv4品目 | 固定IPv4 1個。トンネルへ単一`/32`を設定し、対象LANをそのアドレスへSNAT |
| IPv4 over IPv6方式 | 固定IP用BRとのIPIPトンネル。IPv6のNext HeaderはIPv4を示すProtocol 4 |
| 機器 | UDM Pro、UDM SE、UDM Pro Max（後二者はpreview） |
| OS・IPv6構成 | versionに依存せず、必要なkernel、route、firewall capabilityを一意に確認 |
| トンネル所有者 | 既定はproject専用`jpix0`。明示移行した単一WANのみUniFi管理トンネルの限定fieldとkernel endpointを補正 |

### 対応していないもの

- 通常の「v6プラス」で使用するMAP-E、共有IPv4、割り当てポート方式
- JPIX固定IPの8/16/32/64 IP品目、複数グローバルIPv4のroute、1:1 NAT、静的NAT
- HB46PP、DS-Lite、Lightweight 4over6、MAP-T、464XLAT、および他VNEのサービス
- RAだけで構成する接続、UDM Pro系以外の機器、capabilityを一意に確認できない環境
- 受信公開用のDNAT、port forwarding、公開サーバー用firewall policy

IPIPというデータ転送方式が同じでも、JPIX固定IPとHB46PP対応IPIPでは、パラメータを得る制御方式が異なります。この実装はHB46PPのDNS発見、HTTP(S)プロビジョニング、JSON解析、方式選択、TTL管理を実装していません。詳しくは[サービスと方式の技術解説](docs/service-and-protocols.md)を参照してください。

## v2の検証状況

現在の実機releaseは`v2.0.0-dev.22`です。2026-09-14、standalone所有権方針の見直しを明示承認したうえで、単一WANの`unifi-managed`方式へ移行しました。**管理画面の速度測定が成功し、下り4.46 Gbps・上り2.49 Gbps、ISP名と固定IPv4の表示復帰を確認しました。** 実通信はUniFiの論理WANへ統一し、旧`jpix0`と稼働中のroute/rule/firewall参照は残っていません。統合後のUDM IPv4/IPv6 HTTPS、UDP/TCP DNS、7 monitorが正常で、Windows PCのYouTubeとゲーム接続もユーザー確認済みです。単発の速度測定であり性能保証ではありません。

この統合方式はpreviewです。UDAPIの静的IPv6送信元指定が実機で未実装だったため、対応済みのAPI field更新とkernel endpoint補正を組み合わせています。初回失敗時のstandalone復帰を確認し、最終移行は10分の復旧timer付きで実行して通信確認後に確定しました。`dev.22`は設定保存時の修復待機を短縮し、Pythonテスト79件をローカルとUDMで確認しています。利用者の設定保存1回ではWAN down判定は発生せず、設定再適用開始から約7秒後にIPv4 probeが復帰しましたが、短い通信失敗は残りました。無停止保証ではありません。新方式での再起動・WAN切替・Network application restartは未実施です。手順と所有権境界は[v2ガイド](docs/v2.md#unifi管理wanへの統合preview)を参照してください。

2026-09-13、UDM Proを`v2.0.0-dev.15`へ更新しました。明示opt-inの単一WAN adapterで、UDM自身の通常IPv4/DNS経路と回線監視を補正します。監視更新後のUniFi user-hook再生成にも再reconcileで対応し、限定した経路rule・monitor/firewall drift試験で自動復元を確認しました。詳細と制約は[v2ガイド](docs/v2.md)を参照してください。

2026-09-07、UDM Proで開発版`v2.0.0-dev.13`への移行とprovider更新が成功しました。IPv4・native IPv6 health check、bootstrap・event monitor・timerの起動、v1 automation停止を確認しました。project-ownedな接続route欠落試験は観測処理全体が6.7秒で完了し、復元後の`healthy`を確認しています。

同日、`dev.15`でUDMを実際に再起動し、Boot ID変更、手動補正なしの自動復旧、IPv4/IPv6、DNSを伴うHTTPS、回線監視を確認しました。Windows PCのYouTube再生とゲーム接続もユーザーが成功を確認しています。WAN切替・断復帰、Network全体のrestart/reprovision、prefix変更、対象外LANの実端末検証は未完了です。24時間shadow観察は省略しています。この開発版はstable公開や全機種・全障害への対応保証ではありません。[検証一覧](docs/validation.md#v2の実機検証範囲)と[現実装の制約](docs/v2.md#現実装の制約と次の検証)を参照してください。

## v1の検証状況

- ローカル自動テストは、設定解析、dry-run、適用、ロールバック、診断、更新通知、systemd連携を対象にしています。
- UDM Pro・UniFi OS 5系で、exact platform、native IPv6、DHCPv6-PD LAN `/64` evidence、UniFi管理トンネル、検証済みuser hookを確認しました。endpointは明示したdelegated-prefix LAN bridgeの一意なkernel `/64`から生成します。
- 旧実装からのdry-run、手動apply、provider通知、対象LAN通信、timed recovery、`off`、rollback、再applyを確認しました。
- 新しい`trigger.service`、`watch.service`、`update.timer`をenableし、UDM再起動後のboot apply、unit稼働、対象LAN通信復帰、2分間・9回の`status`エラー0、provider timer初回tick成功を確認しました。旧実装はdisabled/inactiveです。
- provider更新先は、公開資料と実機到達性確認で正式なHTTPS提供を確認できなかったため、推測で切り替えずHTTPを継続しています。
- UniFi reprovision、prefix変更、独立トンネル比較、PMTUD・UDP・VPN、対象外LAN実端末と変更後browser判定は[Issue #3〜#7](docs/validation.md#現在の実機検証範囲)で追跡しています。

以下は既存v1の実績です。v2の実機gateは[v2ガイド](docs/v2.md)のrollout手順で別に管理します。

詳細なv1完了・未完了一覧は[Validation](docs/validation.md#現在の実機検証範囲)を正本とします。

## v1の設計上の区別

以下の説明は移行前のv1にだけ該当します。v2は既定で独立したproject-owned tunnelを作ります。v2の`unifi-managed`は別の明示移行方式であり、v1 automationやstandalone tunnelと同時に有効化しません。

## 主なコンポーネント

v2の主な入口は`unifi-jpix` CLI、`unifi-jpix-bootstrap.service`、event monitor、UDAPI path監視、5分timerです。詳細は[v2ガイド](docs/v2.md)を参照してください。次表はv1互換コンポーネントです。

| コンポーネント | 役割 | ネットワーク変更 |
| --- | --- | --- |
| `unifi-jpix-tunnel-repair-preflight.sh` | 未インストール状態で前提を共有安全に確認 | なし |
| `unifi-jpix-tunnel-repair-diag.sh` | 設定後の共有診断と完全診断 | なし |
| `unifi-jpix-tunnel-repair-apply.sh` | `apply`、`status`、`off`を実行 | `apply`と`off`のみ |
| `unifi-jpix-tunnel-repair-trigger.sh` | netlink変化後に再適用 | あり |
| `unifi-jpix-tunnel-repair-watch.sh` | 管理状態を監視し、必要時に修復 | あり |
| `unifi-jpix-tunnel-repair-update.sh` | endpoint更新をproviderへ通知 | 通知通信のみ |

## v1の対象

- UDM Pro
- exact verified tuple: UniFi OS、UniFi Network、kernel、iproute2、iptables/ip6tables backendが`config/verified-platforms.conf`の1行へ完全一致
- JPIX「v6プラス」固定IPサービスの1 IP品目
- ひかり電話なしのDHCPv6-PD構成
- UniFiがBR向けIPIP6トンネルを生成済みの環境

10GbEは必須ではありません。WAN物理速度ではなく、トンネル、委任prefix、BR、固定IPv4、対象LANの実値を環境ごとに確認してください。

## 安全な導入順序

v2は`discover → config編集 → check → plan → activate`の順で導入します。v1からは`migrate-v1`で案を確認してから`--activate`を明示します。以下はv1を直接導入する場合の旧手順です。

1. 最初に[UDM Pro導入・移行runbook](docs/udm-pro-setup.md)を上から順に実行します。
2. [構成と安全境界](docs/architecture.md)と[設定リファレンス](docs/configuration.md)で値の意味を確認します。
3. UDM上でshare-safe preflight、`--discover`、完全診断、dry-runを順番に合格させます。
4. timed recoveryを予約してから、競合する旧automationを停止し、手動apply、provider `--force`、通信確認を行います。
5. [ロールバック](docs/rollback.md)を実測し、再applyまで確認します。
6. automationは既定で無効です。手動apply、rollback、再applyまで成功した環境だけ、[runbookのactivation gate](docs/udm-pro-setup.md#13-automationを有効化して再起動検証する)に従って明示的に有効化し、実際の再起動で検証します。

## v2の最初のコマンド

```sh
sudo ./scripts/install-v2.sh
sudo /data/unifi-jpix-tunnel-repair/current/bin/unifi-jpix discover
```

UDM上のreview済みsource directoryで実行します。設定・credential作成、`check`・`plan`、timed recoveryとactivateは[v2ガイド](docs/v2.md)に従ってください。`migrate-v1`の設定案、実設定、state、provider responseはprivateに確認し、公開Issueへ貼り付けないでください。

## ドキュメント

- [Architecture](docs/architecture.md)
- [v2 reconciler](docs/v2.md)
- [UDM Pro setup and migration runbook](docs/udm-pro-setup.md)
- [Service and protocol guide](docs/service-and-protocols.md)
- [Configuration](docs/configuration.md)
- [Installation](docs/installation.md)
- [Validation](docs/validation.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Rollback](docs/rollback.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Protocol and service references](NOTICE.md)

## English summary

An unofficial and experimental reconciler for one static IPv4 address on JPIX's v6 Plus static-IP service. v2 defaults to a dedicated `jpix0` tunnel, dynamically discovers the WAN and delegated endpoint, and restores scoped state after drift. An explicitly enrolled single-WAN preview integrates the UniFi-managed tunnel through narrowly scoped UDAPI fields and a kernel endpoint correction; the dashboard speed test and ISP display were verified on one UDM Pro. Native WAN identity, routes and policy remain owned by UniFi. UDM SE and UDM Pro Max remain preview until their hardware gates pass. The legacy shell implementation is retained only as the v1 migration source.

## License

[MIT](LICENSE)
