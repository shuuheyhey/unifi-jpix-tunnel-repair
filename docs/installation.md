# Installation (v2)

導入コマンド・公開鍵登録・初期設定は[v2ガイドの初期導入](v2.md#初期導入)を参照してください。

1. 契約値と対応capabilityを確認し、別管理経路を用意します。
2. review済みsourceをUDMへ配置して `scripts/install-v2.sh` を実行します。
3. `discover → config編集 → check → plan` を実行します。
4. 復旧先を確認したうえで `scripts/install-v2.sh --activate` を明示実行します。
5. `status --json`、`doctor` と実端末のIPv4・IPv6・DNSを確認します。

稼働中のv2では、非activateでもcurrent選択とbootstrap unit配置が変わります。無影響のstagingと解釈しないでください。同じrelease名の再コピーは行わず、開発版更新は新しい `UNIFI_JPIX_INSTALL_VERSION` を指定します。

旧v1がactive、移行中、enable済み、またはunit状態不明ならinstallerは変更前に拒否します。旧v1を暗黙に停止しません。[廃止前の移行資料](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/tree/9ea09313dd25d6fe326391619551d0ee247aadc3/docs/v2.md)は専用の移行計画のための歴史資料で、現行版には移行コマンドを同梱しません。
