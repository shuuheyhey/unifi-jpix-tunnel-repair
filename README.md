# unifi-jpix-tunnel-repair

UniFi Dream Machine Pro（UDM Pro）で、UniFiが生成したトンネルを補正し、日本のJPIX v6プラス固定IPを終端するための非公式・実験的なPOSIX shell実装です。

> [!WARNING]
> UDM Pro は JPIX の公式対応機器ではありません。このリポジトリは UniFi が生成した IPv6 トンネルを補正するため、UniFi OS の更新や WAN 再設定で動作が変わる可能性があります。必ず診断、dry-run、手動適用、ロールバック試験の順に検証してください。

## 設計上の区別

このプロジェクトは、独立したIPIP6トンネルを新規作成するツールではありません。既存のUniFi管理トンネルがBRへのIPv4経路として動作していることを確認し、そのトンネルを固定IP用に補正します。独自トンネルを作成する実装や、UniFi管理トンネルを削除するwatchdogとは互換性がないため、併用しないでください。

## 主な機能

- DHCPv6-PD から選ばれた IPv6 を使い、固定IPv4向け IP-in-IP トンネルを構成
- 対象LANごとのポリシールーティング、SNAT、TCP MSS 調整
- IPv6プレフィックス変更後の再適用と固定IP更新通知
- systemd による起動時適用、監視、定期通知
- インストールや設定の前に実行できる、読み取り専用の共有安全preflight
- 秘密情報を含まない共有用診断と、明示指定した非公開ファイルへの完全診断
- 構文・権限・symlink・予約ルートの衝突を fail-closed で検査

## 対象

- UDM Pro
- UniFi OS 5 系（バージョンごとの実機検証が必要）
- JPIX v6プラス固定IP相当の IPv4 over IPv6 サービス
- ひかり電話なしの DHCPv6-PD 構成

10GbE は必須ではありません。WAN物理速度に依存せず同じ構成を使えますが、利用するポート、トンネル名、委任プレフィックス、BR、固定IPv4は各環境で確認してください。

## 安全な導入順序

1. [構成と前提](docs/architecture.md)を確認します。
2. UDM上で共有安全preflightを実行し、導入前提を確認します。
3. [設定方法](docs/configuration.md)に沿って、実値をGit管理外の設定ファイルへ入力します。
4. [インストール](docs/installation.md)を実行します。インストーラーはサービスを有効化・起動しません。
5. 共有用診断、完全診断、dry-run、手動applyを順に実行します。
6. [検証項目](docs/validation.md)を満たした後だけ自動化を有効にします。
7. 事前に[ロールバック](docs/rollback.md)を試験します。

## 最小コマンド

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
sudo ./scripts/install.sh
sudo install -m 600 config/gateway.conf.example /data/unifi-jpix-tunnel-repair/config/gateway.conf
sudo install -m 600 config/routed-networks.conf.example /data/unifi-jpix-tunnel-repair/config/routed-networks.conf
sudo install -m 600 config/provider-update.conf.example /data/unifi-jpix-tunnel-repair/config/provider-update.conf
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh --full-output /data/unifi-jpix-tunnel-repair/state/diagnostic.txt
sudo DRY_RUN=1 /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
```

preflightは設定ファイルを読み込まず、ネットワーク状態を変更しません。`PREFLIGHT_MODE=share-safe`の出力は、実address、prefix、MAC address、interface名、device IDを含まないため、導入前の遠隔確認にそのまま共有できます。

例ファイルをそのまま実機へ適用しないでください。完全診断にはネットワーク情報が含まれるため、公開Issueへ貼り付けないでください。

## Documentation

- [Architecture](docs/architecture.md)
- [Configuration](docs/configuration.md)
- [Installation](docs/installation.md)
- [Validation](docs/validation.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Rollback](docs/rollback.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## English summary

An unofficial and experimental POSIX-shell implementation that repairs a UniFi-managed tunnel to terminate Japan's JPIX v6 Plus fixed-IP service on a UniFi Dream Machine Pro. It does not create a standalone replacement tunnel. It installs inertly, validates privileged files before reading them, defaults provider updates to HTTPS, and emits share-safe diagnostics by default.

## License

[MIT](LICENSE)
