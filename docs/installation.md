# Installation

## 1. Review

実機へ入る前に、このリポジトリを信頼できる端末で取得し、commitと差分を確認します。rootで実行されるため、未確認のforkやpatchを直接インストールしないでください。

## 2. Install files

```sh
sudo ./scripts/install.sh
```

インストーラーは `/data/v6plus` とsystemd unitを作成し、所有者とmodeを設定します。例ファイルだけを配置し、実設定の生成、サービスのenable、start、ネットワーク変更は行いません。既存の実設定は上書きしません。

## 3. Create private configuration

例を別名でコピーし、[Configuration](configuration.md)に沿って編集します。

```sh
sudo install -m 600 /data/v6plus/config/v6plus.env.example /data/v6plus/config/v6plus.env
sudo install -m 600 /data/v6plus/config/networks.conf.example /data/v6plus/config/networks.conf
sudo install -m 600 /data/v6plus/config/update.env.example /data/v6plus/config/update.env
```

## 4. Diagnose and dry-run

```sh
sudo /data/v6plus/scripts/v6plus-diag.sh
sudo /data/v6plus/scripts/v6plus-diag.sh --full-output /data/v6plus/state/diagnostic.txt
sudo DRY_RUN=1 /data/v6plus/scripts/v6plus-apply.sh apply
```

完全診断fileは毎回新しいpathを指定してください。既存fileやsymlinkへの出力は拒否されます。

## 5. Manual apply

[Validation](validation.md)の事前項目と[Rollback](rollback.md)を確認してから実行します。

```sh
sudo /data/v6plus/scripts/v6plus-apply.sh apply
sudo /data/v6plus/scripts/v6plus-apply.sh status
```

## 6. Enable automation

手動適用、IPv4/IPv6、prefix変更、再起動、rollbackが成功した後だけ有効化します。

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now v6plus-trigger.service v6plus-watch.service v6plus-update.timer
```
