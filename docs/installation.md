# Installation

## 1. Review

実機へ入る前に、このリポジトリを信頼できる端末で取得し、commitと差分を確認します。rootで実行されるため、未確認のforkやpatchを直接インストールしないでください。

## 2. Run share-safe preflight

インストールや設定ファイルの作成前に、UDM上で読み取り専用preflightを実行します。

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
```

出力は実address、prefix、MAC address、interface名、device ID、認証情報を含みません。`RESULT=needs-attention`の場合はインストールへ進まず、出力全体を確認してください。終了statusはreadyが`0`、要確認が`1`、使い方の誤りが`2`です。

## 3. Install files

```sh
sudo ./scripts/install.sh
```

インストーラーは `/data/unifi-jpix-tunnel-repair` とsystemd unitを作成し、所有者とmodeを設定します。例ファイルだけを配置し、実設定の生成、サービスのenable、start、ネットワーク変更は行いません。既存の実設定は上書きしません。

## 4. Create private configuration

例を別名でコピーし、[Configuration](configuration.md)に沿って編集します。

```sh
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/gateway.conf.example /data/unifi-jpix-tunnel-repair/config/gateway.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/routed-networks.conf.example /data/unifi-jpix-tunnel-repair/config/routed-networks.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/provider-update.conf.example /data/unifi-jpix-tunnel-repair/config/provider-update.conf
```

## 5. Diagnose and dry-run

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh --full-output /data/unifi-jpix-tunnel-repair/state/diagnostic.txt
sudo DRY_RUN=1 /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
```

完全診断fileは毎回新しいpathを指定してください。既存fileやsymlinkへの出力は拒否されます。

## 6. Manual apply

[Validation](validation.md)の事前項目と[Rollback](rollback.md)を確認してから実行します。

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
```

## 7. Enable automation

手動適用、IPv4/IPv6、prefix変更、再起動、rollbackが成功した後だけ有効化します。

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
```
