# Rollback

ネットワーク変更前にローカルconsoleまたは別管理経路を確保してください。SSHだけに依存すると、routeやfirewallの誤設定時に復旧できません。

## 1. 自動処理を停止する

```sh
sudo systemctl stop unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer unifi-jpix-tunnel-repair-update.service
```

applyやupdateが実行中でないことを確認します。同時実行を避けるため、lockを手動削除しないでください。

## 2. 現在状態を確認する

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
```

失敗しても繰り返しapplyせず、share-safe診断と実機内の完全診断を保全します。

## 3. Managed stateを戻す

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh off
```

`off`は保存した元トンネル状態を復元し、このプロジェクトがtag付けしたroute、rule、netfilter stateだけを削除します。所有権を証明できない既存状態は削除しません。

`off`が失敗した場合は手動削除へ進まず、出力と保存stateを実機内で保全してください。公開Issueには通常のshare-safe診断だけを添付します。

## 4. 通信を確認する

- UniFi管理トンネルが元のlocal、remote、mode、MTUへ戻った
- 通常のIPv4経路が復帰した
- native IPv6とDNSが維持されている
- 対象外LANが変化していない
- このプロジェクトのtag付きroute、rule、netfilter stateだけが消えた

## 5. Boot automationを無効化する

```sh
sudo systemctl disable unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
sudo systemctl daemon-reload
```

## 6. ファイルを保持または削除する

unitとfileの削除は自動化していません。configとstateは復旧資料になるため、必要性とbackupを確認してから個別に扱います。credentialを含むconfigを通常のarchiveやIssueへ入れないでください。

再導入する場合は、残ったstateを流用せず、原因を解消してpreflightから再検証してください。
