# unifi-jpix-tunnel-repair

UniFi Dream Machine Pro（UDM Pro）で、UniFiが生成したトンネルを補正し、日本のJPIX v6プラス固定IPを終端するための非公式・実験的なPOSIX shell実装です。

> [!WARNING]
> UDM ProはJPIXの公式対応機器ではありません。UniFi OSの更新、WAN設定、DHCPv6-PDの表現、netfilter chainの変更により動作条件が変わります。preflight、診断、dry-run、手動適用、ロールバック試験を順番に完了するまで自動化を有効にしないでください。

## 現在の検証状況

- ローカル自動テストは、設定解析、dry-run、適用、ロールバック、診断、更新通知、systemd連携を対象にしています。
- UDM Pro・UniFi OS 5系でshare-safe preflightを実行し、native IPv6、UniFi管理トンネル候補、UniFi user chain、DHCPv6-PDの動作を確認しました。
- UniFi OS 5の実機では、DHCPv6-PDが動作していてもaggregate routeを残さず、LAN bridge向け`/64`の`proto kernel` routeだけを展開する場合があります。preflightはこの状態を`DHCPV6_PD_ROUTE=absent`、`DHCPV6_PD_LAN64_EVIDENCE=present`として区別し、PD成立の証拠として扱います。
- 設定投入後のdry-run、固定IPv4通信、再起動復帰、ロールバックは未完了です。進捗は[Issue #1](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/1)で管理します。

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
- JPIX v6プラス固定IP相当のIPv4 over IPv6サービス
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
- [Configuration](docs/configuration.md)
- [Installation](docs/installation.md)
- [Validation](docs/validation.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Rollback](docs/rollback.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Protocol and service references](NOTICE.md)

## English summary

An unofficial and experimental POSIX-shell implementation that repairs a UniFi-managed tunnel for Japan's JPIX v6 Plus static IPv4 service. It does not create a standalone replacement tunnel. It installs inertly, validates privileged files before reading them, defaults provider updates to HTTPS, and emits share-safe preflight and diagnostic output. Live validation is still in progress and is required before production use.

## License

[MIT](LICENSE)
