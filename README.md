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
| OS・IPv6構成 | `config/verified-platforms.conf`に完全一致するtupleと、現在の実機で確認したDHCPv6-PD構成 |
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
- Issue #2のreviewを受け、endpointは明示したdelegated-prefix interfaceの一意なkernel `/64`から生成し、policy ruleはsource CIDRとingress interfaceの両方へ限定しました。exact platform、UniFi hook parent、legacy backend、MTU/MSS、tunnel attributeもmutation前に検査します。
- Issue #2対応版を実機へ移行し、競合する旧実装を停止した後のdry-run、手動apply、`status`、provider通知、対象LANからの固定IPv4出口・native IPv6・DNS、timed recovery、`off`、旧実装への復帰、再applyを確認しました。移行中に見つかったroot所有`0775`のsystemd親directoryと、元トンネルlocalのIPv4-mapped IPv6表現もstrict validationを維持したまま対応済みです。
- service状態変更後にUniFi側の書き戻しとみられるtag付きSNAT ruleのdriftを1回観測し、手動再applyで復旧後も再確認しました。共有トンネルの所有権競合が残る実測証拠として扱い、新旧automationはdisabled/inactiveのままです。
- 再起動、reprovision、prefix変更、独立トンネル比較、PMTUD・UDP・VPN、対象外LAN実端末の外部到達性は未完了です。進捗は[Issue #2](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/2)で管理します。

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
- exact verified tuple: UniFi OS、UniFi Network、kernel、iproute2、iptables/ip6tables backendが`config/verified-platforms.conf`の1行へ完全一致
- JPIX「v6プラス」固定IPサービスの1 IP品目
- ひかり電話なしのDHCPv6-PD構成
- UniFiがBR向けIPIP6トンネルを生成済みの環境

10GbEは必須ではありません。WAN物理速度ではなく、トンネル、委任prefix、BR、固定IPv4、対象LANの実値を環境ごとに確認してください。

## 安全な導入順序

1. 最初に[UDM Pro導入・移行runbook](docs/udm-pro-setup.md)を上から順に実行します。
2. [構成と安全境界](docs/architecture.md)と[設定リファレンス](docs/configuration.md)で値の意味を確認します。
3. UDM上でshare-safe preflight、`--discover`、完全診断、dry-runを順番に合格させます。
4. timed recoveryを予約してから、競合する旧automationを停止し、手動apply、provider `--force`、通信確認を行います。
5. [ロールバック](docs/rollback.md)を実測し、再applyまで確認します。
6. 再起動、reprovision、prefix変更、独立トンネル比較が未完了の間はautomationを有効化しません。

## 最初のコマンド

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
```

ここで`ready-for-config`になった後も、READMEの断片だけでapplyへ進まず、[runbook](docs/udm-pro-setup.md)のarchive/SHA-256/SCP、競合確認、timed recovery、`--discover`から続けてください。preflightと通常診断のstdoutは共有安全です。完全診断、設定ファイル、state、provider responseは公開Issueへ貼り付けないでください。

## ドキュメント

- [Architecture](docs/architecture.md)
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

An unofficial and experimental POSIX-shell implementation for one static IPv4 address on JPIX's v6 Plus static-IP service, using a UniFi-managed tunnel on UDM Pro. It does not support ordinary MAP-E v6 Plus, multi-address static-IP plans, HB46PP, other VNE services, or standalone tunnel creation. It installs inertly, validates an exact platform tuple and delegated LAN /64 before mutation, source-scopes policy rules, forbids global firewall-chain fallback, and emits share-safe preflight and diagnostic output. Manual live migration, rollback and reapply have been verified on the listed platform tuple. Reboot, reprovision, prefix-change and standalone-tunnel comparison remain incomplete; automation must stay disabled.

## License

[MIT](LICENSE)
