# UDM Pro runbook

これは導入・更新の受入チェックです。実行コマンドは[Installation](installation.md)、CLIの意味は[運用ガイド](guide.md)、過去の合格範囲は[Validation](validation.md)に分けています。別のreleaseやmodeの実績を今回の成功扱いにしません。

## 作業前

1. 契約と対象LAN、現在のmode・release・planを確認し、新規導入か更新かを決めます。
2. インターネット断でも利用できる管理経路と、今回の変更に対応する復旧方法を確保します。初回には過去のreleaseがありません。
3. review済みsourceを`git archive`等でまとめ、checksumを照合してUDMのprivate stagingへ転送します。契約config・credential・stateはarchiveへ含めません。
4. 新規導入ではdiscover・config・check・plan、更新では復旧先の互換性・監視停止・実行中処理の終了確認を済ませます。
5. 明示activateし、エラーなら受入チェックに進まず[Rollback](rollback.md)で状態を確認します。

## 有効化後の受入チェック

| 層 | 確認すること | 成功しても証明しないこと |
| --- | --- | --- |
| 配置 | 意図した`current`と`verified`、manifest検証を含むbootstrap成功 | 新しいsourceが署名済み公開releaseであること |
| 自動実行 | bootstrap・timer・event monitor・UDAPI pathの4 unitがenabled/active。次回timerと直近oneshot結果も確認 | OS更新後のunit保持、実再起動後の成功 |
| 状態 | `status --json`でpending repairs 0、直近health成功、余分なproject rule/参照なし | 全アプリ・全LANの疎通 |
| UDM通信 | 通常IPv4、native IPv6、DNSとHTTPS、回線監視。managedなら管理画面のISP表示と速度測定も別に確認 | LAN端末からの到達性、持続的な回線速度 |
| DNS・端末 | 通常/フィルター経由のA/AAAA・UDP/TCP、保護機能の期待応答、対象LANと対象外LANの実端末通信 | 全カテゴリ・動画・ゲーム・VPNの動作 |

provider通知が設定されている場合はpendingの有無も確認します。`doctor`だけではcredential認証やfreshな通知成功を検証できません。WAN情報、filter構成、生成されたresolverの内容はprivateに照合します。

確認に使ったcommand、release、mode、結果、未実施項目を記録します。raw configやaddressを共有文書へ転記しません。一般的なsource更新には10分復旧timerはないので、存在しないtimerを前提に作業しないでください。管理WAN統合中だけは合格後に`integrate-wan --confirm`を実行します。別途用意した復旧手段は、正確な対象と復旧確認を済ませてから解除します。

## 障害試験は別phaseで実施

1. UniFi設定保存と、Network application全体のrestart/reprovisionを区別します。
2. UDM実再起動ではBoot IDの変化と、手動reconcileなしの復帰をprivateに確認します。
3. 物理WAN切替・ケーブル断復帰と、DHCPv6-PD prefix変更を別々に試します。
4. 欠落ruleの復元、重複なし、対象外資産保持と、実際の通信復帰時間をそれぞれ測定します。
5. 各phaseの後に上の受入チェックへ戻り、失敗・説明できない差分があれば次へ進みません。

これらは接続断を伴い得る試験です。通常のドキュメント更新やsourceテストの一環として自動実行しません。eventの30秒・timerの5分は目標であって上限保証ではなく、現時点の未検証gateは[Validation](validation.md#未検証の実機gate)を参照してください。
