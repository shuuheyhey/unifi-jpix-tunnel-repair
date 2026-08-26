# unifi-jpix-tunnel-repair

UniFi Dream Machine Pro（UDM Pro）で、UniFiが生成したトンネルを補正し、**JPIX「v6プラス」固定IPサービスの固定IPv4 1個**を終端するための非公式・実験的なPOSIX shell実装です。

> [!WARNING]
> UDM ProはJPIXの公式対応機器ではありません。UniFi OSの更新、WAN設定、DHCPv6-PDの表現、netfilter chainの変更により動作条件が変わります。preflight、診断、dry-run、手動適用、ロールバック試験を順番に完了するまで自動化を有効にしないでください。

## 対応範囲

このプロジェクトの対応対象は、次の条件を**すべて**満たす構成だけです。

| 項目 | 対応対象 |
| --- | --- |
| サービス | JPIX「v6プラス」固定IPサービス |
| IPv4品目 | 固定IPv4 1個。トンネルへ単一`/32`を設定し、対象LANをそのアドレスへSNAT |
| IPv4 over IPv6方式 | 固定IP用BRとのIPIPトンネル。IPv6のNext HeaderはIPv4を示すProtocol 4 |
| 機器 | UDM Pro |
| OS・IPv6構成 | UniFi OS 5系、現在の実機で確認したDHCPv6-PD構成 |
| トンネル所有者 | UniFiが作成済みの管理トンネルを補正。独立トンネルは作成しない |

### 対応していないもの

- 通常の「v6プラス」で使用するMAP-E、共有IPv4、割り当てポート方式
- JPIX固定IPの8/16/32/64 IP品目、複数グローバルIPv4のroute、1:1 NAT、静的NAT
- HB46PP、DS-Lite、Lightweight 4over6、MAP-T、464XLAT、および他VNEのサービス
- RAだけで構成する接続、UDM Pro以外の機器、UniFi OS 5系以外の未検証環境
- 受信公開用のDNAT、port forwarding、公開サーバー用firewall policy

IPIPというデータ転送方式が同じでも、JPIX固定IPとHB46PP対応IPIPでは、パラメータを得る制御方式が異なります。この実装はHB46PPのDNS発見、HTTP(S)プロビジョニング、JSON解析、方式選択、TTL管理を実装していません。詳しくは[サービスと方式の技術解説](docs/service-and-protocols.md)を参照してください。

## 現在の検証状況

- ローカル自動テストは、設定解析、dry-run、適用、ロールバック、診断、更新通知、systemd連携を対象にしています。
- UDM Pro・UniFi OS 5系でshare-safe preflightを実行し、native IPv6、UniFi管理トンネル候補、UniFi user chain、DHCPv6-PDの動作を確認しました。
- UniFi OS 5の実機では、DHCPv6-PDが動作していてもaggregate routeを残さず、LAN bridge向け`/64`の`proto kernel` routeだけを展開する場合があります。preflightはこの状態を`DHCPV6_PD_ROUTE=absent`、`DHCPV6_PD_LAN64_EVIDENCE=present`として区別し、PD成立の証拠として扱います。
- 2026-08-26の実機接続試験では、JPIX判定`5999`（v6プラス固定IP）、IPv4、IPv6、フレッツ西日本到達性、v6プラス用試験が成功しました。これはその時点の回線状態を確認した結果であり、このツールによる修復成功を単独で証明するものではありません。[接続判定ページの使い方と読み方](docs/service-and-protocols.md#9-jpnejpix-ipv4ipv6接続判定ページ)も確認してください。
- このツールの実configを使ったdry-run、手動apply、prefix変更追従、再起動復帰、ロールバックは未完了です。進捗は[Issue #1](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/1)で管理します。

実機検証が完了するまで、検証環境以外へ適用しないでください。

## 設計上の区別

このプロジェクトは独立したIPIP6トンネルを新規作成しません。既存のUniFi管理トンネルがBRへのIPv4経路として動作していることを確認し、そのトンネルを固定IP用に補正します。独自トンネルを作成する実装や、UniFi管理トンネルを削除するwatchdogとは併用できません。

## 主なコンポーネント

| コンポーネント | 役割 | ネットワーク変更 |
| --- | --- | --- |
| `unifi-jpix-tunnel-repair-preflight.sh` | 未インストール状態で前提を共有安全に確認 | なし |
| `unifi-jpix-tunnel-repair-diag.sh` | 設定後の共有診断と完全診断 | なし |
| `unifi-jpix-tunnel-repair-apply.sh` | `apply`、`status`、`off`を実行 | `apply`と`off`のみ |
| `unifi-jpix-tunnel-repair-trigger.sh` | netlink変化後に再適用 | あり |
| `unifi-jpix-tunnel-repair-watch.sh` | 管理状態を監視し、必要時に修復 | あり |
| `unifi-jpix-tunnel-repair-update.sh` | endpoint更新をproviderへ通知 | 通知通信のみ |

## 対象

- UDM Pro
- UniFi OS 5系。各バージョンで実機確認が必要
- JPIX「v6プラス」固定IPサービスの1 IP品目
- ひかり電話なしのDHCPv6-PD構成
- UniFiがBR向けIPIP6トンネルを生成済みの環境

10GbEは必須ではありません。WAN物理速度ではなく、トンネル、委任prefix、BR、固定IPv4、対象LANの実値を環境ごとに確認してください。

## 安全な導入順序

1. [構成と安全境界](docs/architecture.md)を確認します。
2. UDM上でshare-safe preflightを実行します。
3. [設定リファレンス](docs/configuration.md)に沿って、実値をGit管理外へ保存します。
4. [インストール手順](docs/installation.md)でファイルだけを配置します。
5. 共有診断、完全診断、dry-run、手動applyを順番に実行します。
6. [検証チェックリスト](docs/validation.md)を完了します。
7. [ロールバック](docs/rollback.md)を実際に試験してから自動化を有効にします。

## 最小コマンド

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
sudo ./scripts/install.sh
sudo install -m 600 config/gateway.conf.example /data/unifi-jpix-tunnel-repair/config/gateway.conf
sudo install -m 600 config/routed-networks.conf.example /data/unifi-jpix-tunnel-repair/config/routed-networks.conf
sudo install -m 600 config/provider-update.conf.example /data/unifi-jpix-tunnel-repair/config/provider-update.conf
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh --dry-run apply
```

preflightと通常診断のstdoutは共有安全です。完全診断、設定ファイル、state、provider responseは公開Issueへ貼り付けないでください。例ファイルはsynthetic valueであり、そのまま実機へ適用できません。

## ドキュメント

- [Architecture](docs/architecture.md)
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

An unofficial and experimental POSIX-shell implementation for one static IPv4 address on JPIX's v6 Plus static-IP service, using a UniFi-managed tunnel on UDM Pro. It does not support ordinary MAP-E v6 Plus, multi-address static-IP plans, HB46PP, other VNE services, or standalone tunnel creation. It installs inertly, validates privileged files before reading them, defaults provider updates to HTTPS, and emits share-safe preflight and diagnostic output. Live validation is still in progress and is required before production use.

## License

[MIT](LICENSE)
