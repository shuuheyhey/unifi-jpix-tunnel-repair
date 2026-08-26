# Installation

## 1. Review

実機へ入る前に、このリポジトリを信頼できる端末で取得し、commitと差分を確認します。rootで実行されるため、未確認のforkやpatchを直接インストールしないでください。

## 2. Install files

```sh
sudo ./scripts/install.sh
```

インストーラーは `/data/unifi-jpix-tunnel-repair` とsystemd unitを作成し、所有者とmodeを設定します。例ファイルだけを配置し、実設定の生成、サービスのenable、start、ネットワーク変更は行いません。既存の実設定は上書きしません。

## 3. Create private configuration

例を別名でコピーし、[Configuration](configuration.md)に沿って編集します。

```sh
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/gateway.conf.example /data/unifi-jpix-tunnel-repair/config/gateway.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/routed-networks.conf.example /data/unifi-jpix-tunnel-repair/config/routed-networks.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/provider-update.conf.example /data/unifi-jpix-tunnel-repair/config/provider-update.conf
```

## 4. Diagnose and dry-run

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh --full-output /data/unifi-jpix-tunnel-repair/state/diagnostic.txt
sudo DRY_RUN=1 /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
```

完全診断fileは毎回新しいpathを指定してください。既存fileやsymlinkへの出力は拒否されます。

## 5. Manual apply

[Validation](validation.md)の事前項目と[Rollback](rollback.md)を確認してから実行します。

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
```

## 6. Enable automation

手動適用、IPv4/IPv6、prefix変更、再起動、rollbackが成功した後だけ有効化します。

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
```
