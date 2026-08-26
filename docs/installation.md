# Installation

この手順はファイル配置から手動検証までを段階的に進めます。途中で失敗した場合は次の段階へ進まないでください。

## 1. 取得内容を確認する

信頼できる端末でリポジトリを取得し、実行対象commitと差分を確認します。rootで実行されるため、未確認のforkやpatchをUDMへ直接コピーしないでください。

```sh
git status --short --branch
git log -1 --oneline
git diff --check
```

## 2. Share-safe preflightを実行する

インストールやconfig作成前に、UDM上で読み取り専用preflightを実行します。

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
```

終了statusは`ready-for-config`が`0`、`needs-attention`が`1`、使い方の誤りが`2`です。`PREFLIGHT_MODE=share-safe`がない出力は共有しないでください。

### UniFi OS 5の既知の誤判定

UniFi OS 5では、DHCPv6-PDが成功していてもaggregate routeを残さず、LAN bridge向け`/64`の`proto kernel` routeだけを展開する場合があります。この場合、現行preflightは`DHCPV6_PD_ROUTE=absent`と`RESULT=needs-attention`を返します。

この1項目だけが`absent`の場合も自動的に無視せず、[Troubleshooting](troubleshooting.md)に沿ってUniFi WAN設定、DHCPv6 client、IA_PD、LANへのglobal `/64`配布を追加確認してください。

## 3. ファイルを配置する

```sh
sudo ./scripts/install.sh
```

インストーラーは次だけを行います。

- `/data/unifi-jpix-tunnel-repair`へscriptとconfig exampleを配置
- `/etc/systemd/system`へunitを配置
- ownerとmodeを安全な値へ設定

実configの生成、既存実configの上書き、serviceのenableやstart、ネットワーク変更は行いません。

## 4. Private configを作成する

[Configuration](configuration.md)に沿ってexampleを実configへコピーし、実値へ置換します。

```sh
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/gateway.conf.example /data/unifi-jpix-tunnel-repair/config/gateway.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/routed-networks.conf.example /data/unifi-jpix-tunnel-repair/config/routed-networks.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/provider-update.conf.example /data/unifi-jpix-tunnel-repair/config/provider-update.conf
```

実configをGit、Issue、chat、shell historyへ貼り付けないでください。

## 5. 診断とdry-runを行う

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh --full-output /data/unifi-jpix-tunnel-repair/state/diagnostic.txt
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh --dry-run apply
```

- 通常診断は`DIAGNOSTIC_MODE=share-safe`と`RESULT`だけをstdoutへ返します。
- 完全診断fileは毎回新しいabsolute pathを指定します。既存fileやsymlinkは拒否されます。
- dry-runは完全addressを表示せず、変更予定だけを出力します。物理状態とstateを書き換えません。

## 6. 手動applyを行う

ローカルconsoleまたは別管理経路と、[Rollback](rollback.md)の手順を準備してから実行します。

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
```

`status`が成功し、[Validation](validation.md)の対象LAN・対象外LAN確認が終わるまで自動化へ進まないでください。

## 7. 自動化を有効にする

手動適用、IPv4/IPv6、prefix変更、再起動、rollbackを確認した後だけ実行します。

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
```

## 8. 更新する

新しいcommitを確認した後、同じインストーラーを再実行します。実configとstateは上書きされません。

```sh
sudo systemctl stop unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer unifi-jpix-tunnel-repair-update.service
sudo ./scripts/install.sh
sudo systemctl daemon-reload
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh --dry-run apply
```

UniFi OS upgrade後は互換性を推測せず、preflightから再検証してください。
