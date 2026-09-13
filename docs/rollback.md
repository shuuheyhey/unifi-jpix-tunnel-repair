# Rollback (v2)

`unifi-jpix rollback` は互換性を確認した以前のv2 releaseを選択し、そのbootstrapで現行設定へ再収束します。v1 apply、旧トンネルsnapshot、旧provider設定は使いません。

1. 現在のhealthと `current/verified/previous`、復旧先manifestを確認します。
2. 復旧先が現行integrationとrouter recoveryに対応していることを確認します。
3. 別管理経路を確保し、明示的に `unifi-jpix rollback` を実行します。
4. release選択、health、IPv4・IPv6・DNS、対象LAN通信を確認します。

これはuninstallや方式の解除ではありません。`previous` は必ずしも健全版ではなく、source installerが選択した未検証版の可能性もあります。[制約](v2.md#現実装の制約と次の検証)を確認してください。

既存不変release内の旧scriptを個別削除するとmanifestが壊れます。v1廃止では新releaseの梱包を変更し、復旧用旧releaseは変更しません。既存の `state-v2/activation-confirmed` も保持します。[廃止範囲](v1-retirement.md)を参照してください。
