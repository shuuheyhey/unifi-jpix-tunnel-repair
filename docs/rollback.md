# Rollback

releaseの切戻し、1回のapplyの逆操作、未確定のWAN統合の復旧は別の処理です。`unifi-jpix rollback`は以前のcodeで**現行configへ再収束**させます。configや通信方式を過去のsnapshotへ戻すコマンドではありません。

| 状況 | 対応する処理 | 戻せないもの・注意 |
| --- | --- | --- |
| reconcile中にhealth失敗 | 今回のactionの逆操作 | SIGKILL・電源断からの自動journal replayはない |
| 新releaseに問題がある | `unifi-jpix rollback` | config・credentials・UniFi設定全体のsnapshot復元ではない |
| managed統合をまだconfirmしていない | `unifi-jpix integrate-wan --recover` | 専用のprivate移行記録と所有権検証が必要 |
| managed統合をconfirm済み | 一般向け方式解除CLIは未実装 | `--recover`はno-op。release rollbackでstandaloneに戻らない |

## Releaseの切戻し

1. ローカル管理経路を確保し、`status --json`、`doctor`と以下のlinkをprivateに確認します。`--version`だけでは導入releaseを特定できません。

```sh
readlink /data/unifi-jpix-tunnel-repair/current
readlink /data/unifi-jpix-tunnel-repair/verified
readlink /data/unifi-jpix-tunnel-repair/previous
```

2. 復旧先を確認します。選択は`previous`優先、存在しない場合だけ`verified`です。`previous`が不正・非対応・currentと同一なら、そのまま`verified`へ次善fallbackするわけではありません。manifestと、managed・router recovery・WAN policy adapterの互換性が検査されます。
3. 自動監視・他の手動操作とrelease切替を競合させない作業時間を確保し、[更新時と同じ監視停止・処理終了確認](installation.md#稼働中のsource更新)を行ってから実行します。

```sh
unifi-jpix rollback
```

4. 実際の`current`と`verified`、`status`、監視unitの再開を確認し、IPv4・native IPv6・通常DNS・filter DNS・対象LAN端末を再試験します。失敗メッセージだけで復旧完了とは判断しません。

`previous`はsource installerが選択しただけの未検証版の場合もあります。健全性・現行configへの対応を確認できないreleaseへ戻さないでください。既存の不変releaseの中身を編集してmanifestを作り直す操作も復旧手順には含めません。

## 自動切戻しの限界

bootstrapは初回reconcile失敗時に1回だけ別releaseのbootstrapへ移ります。manifest検証など、それ以前の処理で止まった場合は同じ自動復旧経路を通りません。初回導入で復旧先がない場合も戻せません。

`upgrade`の失敗処理にはrelease linkを戻すだけの経路があります。linkが以前の値へ戻っていても、unit再配置・runtimeの復旧・監視再開まで成功した証拠ではありません。選択されたreleaseでのbootstrap完了と疎通を確認してください。判断できなければ再実行を重ねず、privateなログと状態を保全して原因を調べます。

## 適用中の失敗

通常例外・SIGINT・SIGTERMでは、実行中に保持した逆操作を逆順で試みます。`rollback-failed`は少なくとも一つの逆操作が失敗した状態です。完全なverified runtime復元や、以後の自動mutation停止を保証するものではありません。

この場合はtimer・event monitor・UDAPI pathによる追加起動を止め、進行中のreconcileを確認したうえで、所有権・journal・実際のroute/rule/firewallをprivateに照合します。network設定を一括flushしたり、`state-v2`を消したり、稼働中processをSIGKILLして最初からやり直したりしないでください。

## 未確定の管理WAN統合

`integrate-wan --activate`だけが固有名の10分復旧timerを準備します。通常のsource install・upgradeにはこのtimerは付きません。試行中の復旧は`integrate-wan --recover`、疎通確認後の確定は`integrate-wan --confirm`を使います。

復旧処理も所有権不明・同時変更・実行環境の異常で停止し得ます。timerを独立した管理経路の代わりにしないでください。記録済みのconfigと限定WAN fieldを使う処理であり、UniFi全体のsnapshot restoreではありません。詳細は[管理WAN統合](guide.md#unifi管理wanへの統合preview)を参照してください。

汎用uninstallコマンドはありません。source内部の`deactivate()`を直接呼び出して、managed modeの解除や全資産の安全な削除ができると解釈しないでください。
