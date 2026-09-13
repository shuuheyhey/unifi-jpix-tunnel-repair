# UniFi JPIX tunnel repair

JPIX「v6プラス」固定IPサービスの固定IPv4 1個を対象にした、**非公式・実験的**なUniFi gateway向け自己修復ツールです。通常の「v6プラス」で使用するMAP-E、HB46PP、複数固定IPv4は対象外です。ISPやUbiquitiの公式対応・将来互換性を保証しません。

## v2のみを配布します

旧v1のshell実装、installer、systemd unit、設定雛形、移行・v1復帰コマンドを廃止しました。v1が稼働中または自動起動が有効な場合、新installerは配置前に拒否します。暗黙の停止・移行はしません。[廃止記録](docs/v1-retirement.md)と[廃止前のコード・手順](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/tree/9ea09313dd25d6fe326391619551d0ee247aadc3)を参照してください。旧手順を稼働中のv2へ実行しないでください。

v2は実際のBR宛てIPv6経路とLANのdelegated prefixからWANとendpointを検出します。standalone modeは専用 `jpix0` を所有し、明示選択するunifi-managed modeはUniFi管理WANの限定fieldを補正します。後者もv2であり、使用中の `ip6tnl1` を旧v1資産として削除してはいけません。

起動時bootstrap、netlink event monitor、UDAPI path監視、5分timerが同じlockでreconcileします。曖昧な所有権・未知capabilityでは変更せず停止します。releaseは `/data` に保持し、manifest検証とhealth確認後にverifiedへ昇格します。

## 導入

1. [対応サービスと方式](docs/service-and-protocols.md)を契約情報と照合します。
2. [v2ガイド](docs/v2.md#初期導入)に従い非アクティブ配置し、`discover → config編集 → check → plan` を行います。
3. 別管理経路と復旧先を確保して明示activateします。
4. IPv4・IPv6・DNS・対象LANの実端末通信を確認します。

設定とcredentialはrelease外の別JSONです。credential、address、config、state、raw logは公開しないでください。source installerによる開発版配置と、署名付き公開releaseのupgradeは別経路です。

## 検証範囲

UDM Proで限定的な通信・復旧検証を実施しています。UDM SEとUDM Pro Maxはpreviewです。過去の再起動成功を別modeや新版の再起動検証に読み替えません。設定保存時の短い通信断は既知の制約であり、無停止は保証しません。[実機検証記録](docs/validation.md)と[v2の制約](docs/v2.md#現実装の制約と次の検証)を確認してください。

## ドキュメント

- [Architecture](docs/architecture.md) / [Configuration](docs/configuration.md)
- [Installation](docs/installation.md) / [UDM Pro runbook](docs/udm-pro-setup.md)
- [Rollback](docs/rollback.md) / [Troubleshooting](docs/troubleshooting.md)
- [Contributing](CONTRIBUTING.md) / [Security](SECURITY.md) / [References](NOTICE.md)

## Tests and license

```sh
sh tests/run.sh
git diff --check
```

MIT license。GPLコードをコピーせず設計パターンを独自実装しています。

Unofficial, experimental v2-only recovery for the JPIX v6 Plus single static IPv4 service. Ordinary MAP-E and HB46PP are not supported.
