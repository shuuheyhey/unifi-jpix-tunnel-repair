# Rollback

`unifi-jpix rollback` は互換性を確認した以前のreleaseを選択し、そのbootstrapで現行設定へ再収束します。設定や通信方式を過去のsnapshotへ戻す操作ではありません。

1. 現在のhealthと `current/verified/previous`、復旧先manifestを確認します。
2. 復旧先が現行integrationとrouter recoveryに対応していることを確認します。
3. 別管理経路を確保し、明示的に `unifi-jpix rollback` を実行します。
4. release選択、health、IPv4・IPv6・DNS、対象LAN通信を確認します。

これはuninstallや方式の解除ではありません。`previous` は必ずしも健全版ではなく、source installerが選択した未検証版の可能性もあります。[制約](guide.md#現実装の制約と次の検証)を確認してください。

既存の不変releaseを個別編集するとmanifestが壊れます。更新は別releaseとして配置し、復旧先の整合性を保持してください。
