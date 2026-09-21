# UDM Pro runbook

導入は[Installation](installation.md)、コマンドとcapabilityは[運用ガイド](guide.md)、機種別の確認範囲は[Validation](validation.md)を正本とします。

1. review済みsourceを `git archive` 等でまとめ、転送物のchecksumを照合して `scp` でprivate stagingへ配置します。credentialをarchiveへ含めません。
2. UDM上で非activate配置し、discover・設定編集・check・planを確認します。
3. 新しい開発release名、健全な復旧先、別管理経路を確認してactivateします。
4. 通常IPv4・native IPv6・DNS・filter DNS・WAN監視と対象LANの実端末を確認します。
5. timer・event monitor・UDAPI pathとverifiedを確認して、試行用復旧timerを解除します。

設定保存、再起動、WAN物理切替は別の実機phaseです。ソーステストやmanifest一致だけで合格にしません。
