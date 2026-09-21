# Installation

導入コマンド・公開鍵登録・初期設定は[運用ガイドの初期導入](guide.md#初期導入)を参照してください。

1. 契約値と対応capabilityを確認し、別管理経路を用意します。
2. review済みsourceをUDMへ配置して `scripts/install-v2.sh` を実行します。
3. `discover → config編集 → check → plan` を実行します。
4. 復旧先を確認したうえで `scripts/install-v2.sh --activate` を明示実行します。
5. `status --json`、`doctor` と実端末のIPv4・IPv6・DNSを確認します。

すでに稼働中の環境では、非activateでもcurrent選択とbootstrap unit配置が変わります。無影響のstagingと解釈しないでください。同じrelease名の再コピーは行わず、開発版更新は新しい `UNIFI_JPIX_INSTALL_VERSION` を指定します。

installerはproject namespaceの追加automationを検査し、稼働中・起動予定・状態不明なら配置前に拒否します。別のautomationを暗黙に停止・無効化しません。競合を管理者が解消してから再実行してください。
