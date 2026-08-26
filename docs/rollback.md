# Rollback

ネットワーク変更前に、ローカルconsoleまたは別管理経路を確保してください。SSHだけに依存すると、routeやfirewallの誤設定時に復旧できません。

## Managed state rollback

```sh
sudo systemctl stop unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh off
```

`off` は保存した元トンネル状態を復元し、このプロジェクトがtag付けしたroute、rule、netfilter stateだけを削除します。失敗した場合は出力を公開せず、共有用診断だけを添えてIssueを作成してください。

## Disable boot automation

```sh
sudo systemctl disable unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
sudo systemctl daemon-reload
```

unitとfileの削除は自動化していません。設定とstateは復旧資料になり得るため、必要性を確認してから個別にバックアップまたは削除してください。
