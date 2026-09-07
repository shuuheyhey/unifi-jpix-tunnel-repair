# unifi-jpix-tunnel-repair

UniFi Dream Machine Pro系で、**JPIX「v6プラス」固定IPサービスの固定IPv4 1個**をproject-owned tunnelへ終端するための非公式・実験的な実装です。v2はPython reconcilerと小さなPOSIX shell boot基盤で構成し、UniFi管理トンネルを変更しません。従来のshell実装はv1移行元として残しています。

> [!WARNING]
> UDM Pro系はJPIXの公式対応機器ではありません。v2はversion文字列で停止せずcapabilityを確認しますが、実機gateとtimed recoveryなしの有効化は推奨しません。

新規導入とv1移行は[v2 standalone reconciler](docs/v2.md)を正本とします。以下のv1資料は既存導入の保守と移行確認のために残しています。

## 対応範囲

このプロジェクトの対応対象は、次の条件を**すべて**満たす構成だけです。

| 項目 | 対応対象 |
| --- | --- |
| サービス | JPIX「v6プラス」固定IPサービス |
| IPv4品目 | 固定IPv4 1個。トンネルへ単一`/32`を設定し、対象LANをそのアドレスへSNAT |
| IPv4 over IPv6方式 | 固定IP用BRとのIPIPトンネル。IPv6のNext HeaderはIPv4を示すProtocol 4 |
| 機器 | UDM Pro、UDM SE、UDM Pro Max（後二者はpreview） |
| OS・IPv6構成 | versionに依存せず、必要なkernel、route、firewall capabilityを一意に確認 |
| トンネル所有者 | project専用`jpix0`。UniFi管理トンネルは読み取り専用 |

### 対応していないもの

- 通常の「v6プラス」で使用するMAP-E、共有IPv4、割り当てポート方式
- JPIX固定IPの8/16/32/64 IP品目、複数グローバルIPv4のroute、1:1 NAT、静的NAT
- HB46PP、DS-Lite、Lightweight 4over6、MAP-T、464XLAT、および他VNEのサービス
- RAだけで構成する接続、UDM Pro系以外の機器、capabilityを一意に確認できない環境
- 受信公開用のDNAT、port forwarding、公開サーバー用firewall policy

IPIPというデータ転送方式が同じでも、JPIX固定IPとHB46PP対応IPIPでは、パラメータを得る制御方式が異なります。この実装はHB46PPのDNS発見、HTTP(S)プロビジョニング、JSON解析、方式選択、TTL管理を実装していません。詳しくは[サービスと方式の技術解説](docs/service-and-protocols.md)を参照してください。

## v2の検証状況

2026-09-07、UDM Proで開発版`v2.0.0-dev.13`への移行とprovider更新が成功しました。IPv4・native IPv6 health check、bootstrap・event monitor・timerの起動、v1 automation停止を確認しました。project-ownedな接続route欠落試験は観測処理全体が6.7秒で完了し、復元後の`healthy`を確認しています。

v2の実再起動、WAN切替・断復帰、Network restart・reprovision、prefix変更、対象LAN/対象外LANの実端末検証は未完了です。24時間shadow観察は省略しています。この開発版はstable公開や全機種・全障害への対応保証ではありません。[検証一覧](docs/validation.md#v2の実機検証範囲)と[現実装の制約](docs/v2.md#現実装の制約と次の検証)を参照してください。

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

以下の説明は移行前のv1にだけ該当します。v2は独立したproject-owned tunnelを作り、UniFi管理トンネルを変更しません。2方式を同時に有効化しません。

## 主なコンポーネント

v2の主な入口は`unifi-jpix` CLI、`unifi-jpix-bootstrap.service`、event monitor、5分timerです。詳細は[v2ガイド](docs/v2.md)を参照してください。次表はv1互換コンポーネントです。

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
- [v2 standalone reconciler](docs/v2.md)
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

An unofficial and experimental reconciler for one static IPv4 address on JPIX's v6 Plus static-IP service. v2 owns a dedicated `jpix0` tunnel, discovers the active WAN and delegated endpoint at runtime, isolates ambiguous capabilities, and restores its scoped state after link, route, firewall, or boot drift. UDM Pro is the first verified model; UDM SE and UDM Pro Max remain preview until their hardware gates pass. The legacy UniFi-managed-tunnel shell implementation remains available only as the v1 migration source.

## License

[MIT](LICENSE)
