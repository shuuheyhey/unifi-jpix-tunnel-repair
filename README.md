# UniFi JPIX tunnel repair

JPIX「v6プラス」固定IPサービスの固定IPv4 1個を対象にした、**非公式・実験的**なUniFi gateway向け自己修復ツールです。通常の「v6プラス」で使用するMAP-E、HB46PP、複数固定IPv4は対象外です。ISPやUbiquitiの公式対応・将来互換性を保証しません。

## 仕組み

実際のBR宛てIPv6経路とLANのdelegated prefixからWANとendpointを検出します。既定のstandalone modeは専用 `jpix0` を所有し、明示選択するunifi-managed modeはUniFi管理WANの限定fieldを補正します。使用中の `ip6tnl1` を名前だけで不要と判断せず、所有権と通信経路を確認してください。

起動時bootstrap、netlink event monitor、UDAPI path監視、5分timerからreconcileを呼び出し、reconcile同士を同じlockで排他します。曖昧な所有権・未知capabilityではその適用を拒否します。releaseは `/data` に保持し、bootstrapのmanifest検証とhealth確認後にverifiedへ昇格します。無停止や、すべてのOS更新・障害からの自動復旧を保証するものではありません。

## 導入

1. [対応サービスと方式](docs/service-and-protocols.md)を契約情報と照合します。
2. [新規導入手順](docs/installation.md#新規導入)で配置し、`discover → config編集 → check → plan` を行います。
3. 別管理経路と復旧先を確保して明示activateします。
4. [受入チェック](docs/udm-pro-setup.md#有効化後の受入チェック)でIPv4・IPv6・DNS・実端末通信と監視unitを確認します。

稼働中なら[更新手順](docs/installation.md#稼働中のsource更新)を使います。`--activate`なしでもcurrent選択とunit配置は変わります。設定とcredentialはrelease外の別JSONです。credential、address、config、state、raw logは公開しないでください。source installerによる開発版配置と、署名付きreleaseのupgradeは別経路で、配布用公開鍵はこのcheckoutに同梱していません。

## 検証範囲

UDM Proで限定的な通信・復旧検証を実施しています。UDM SEとUDM Pro Maxはpreviewです。過去の再起動成功を別modeや新版の再起動検証に読み替えません。設定保存時の短い通信断は既知の制約であり、無停止は保証しません。[実機検証記録](docs/validation.md)と[実装の制約](docs/guide.md#現実装の制約と次の検証)を確認してください。

## ドキュメント

| 目的 | 文書 |
| --- | --- |
| 導入・更新する | [Installation](docs/installation.md) / [Configuration](docs/configuration.md) |
| CLI・mode・healthの意味を知る | [運用ガイド](docs/guide.md) |
| 起動・所有権・releaseの構造を知る | [Architecture](docs/architecture.md) |
| 異常を調べる・復旧する | [Troubleshooting](docs/troubleshooting.md) / [Rollback](docs/rollback.md) |
| 実機で確認する・確認済み範囲を知る | [UDM Pro runbook](docs/udm-pro-setup.md) / [Validation](docs/validation.md) |
| 仕様の背景・開発・安全性を確認する | [Service and protocols](docs/service-and-protocols.md) / [Contributing](CONTRIBUTING.md) / [Security](SECURITY.md) / [References](NOTICE.md) |

## Tests and license

```sh
PYTHONDONTWRITEBYTECODE=1 sh tests/run.sh
git diff --check
```

ローカルテストと実機検証は別です。CIはpull requestと`main`へのpushで実行します。`develop`へのpushだけではCI成功を確認したことになりません。

MIT license。GPLコードをコピーせず設計パターンを独自実装しています。

Unofficial, experimental recovery for the JPIX v6 Plus single static IPv4 service. Ordinary MAP-E and HB46PP are not supported.
