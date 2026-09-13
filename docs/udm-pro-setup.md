# UDM Pro runbook (v2)

導入は[Installation](installation.md)、コマンドとcapabilityは[v2ガイド](v2.md)、機種別の確認範囲は[Validation](validation.md)を正本とします。

1. review済みsourceを `git archive` 等でまとめ、転送物のchecksumを照合して `scp` でprivate stagingへ配置します。credentialをarchiveへ含めません。
2. UDM上で非activate配置し、discover・設定編集・check・planを確認します。
3. 新しい開発release名、健全なv2復旧先、別管理経路を確認してactivateします。
4. 通常IPv4・native IPv6・DNS・filter DNS・WAN監視と対象LANの実端末を確認します。
5. timer・event monitor・UDAPI pathとverifiedを確認して、試行用復旧timerを解除します。

設定保存、再起動、WAN物理切替は別の実機phaseです。ソーステストやmanifest一致だけで合格にしません。旧v1は現行配布に含まれず、稼働中v1との併存はinstallerが拒否します。[歴史資料](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/tree/9ea09313dd25d6fe326391619551d0ee247aadc3/docs/udm-pro-setup.md)の旧offや旧復帰timerを現在のv2へ実行しないでください。
