# Rollback

ネットワーク変更前に、ローカルconsoleまたは別管理経路を確保してください。SSHだけに依存すると、routeやfirewallの誤設定時に復旧できません。

## Managed state rollback

```sh
sudo systemctl stop v6plus-trigger.service v6plus-watch.service v6plus-update.timer
sudo /data/v6plus/scripts/v6plus-apply.sh off
```

`off` は保存した元トンネル状態を復元し、このプロジェクトがtag付けしたroute、rule、netfilter stateだけを削除します。失敗した場合は出力を公開せず、共有用診断だけを添えてIssueを作成してください。

## Disable boot automation

```sh
sudo systemctl disable v6plus-trigger.service v6plus-watch.service v6plus-update.timer
sudo systemctl daemon-reload
```

unitとfileの削除は自動化していません。設定とstateは復旧資料になり得るため、必要性を確認してから個別にバックアップまたは削除してください。
