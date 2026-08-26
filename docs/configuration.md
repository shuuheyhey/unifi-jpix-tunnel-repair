# Configuration

設定は `/data/unifi-jpix-tunnel-repair/config` に置き、root所有、mode `0600` にします。設定ファイルはshellとしてsourceされませんが、改ざんを防ぐため権限検査に失敗すると処理を中止します。

## `gateway.conf`

- `WAN_IF`: BRへのIPv6 routeが選ぶWAN interface
- `TUN_IF`: UniFiが作成したBR一致トンネル
- `STATIC_V4`: 契約で割り当てられた固定IPv4
- `BR_V6`: 契約資料に記載されたBR IPv6
- `IID`: 固定IPサービス用のinterface identifier
- `TUN_MTU`, `TCP_MSS`: サービス要件に合わせた値
- `ROUTE_TABLE`: 他用途と衝突しない専用table番号
- `RULE_PREF_BASE`: 対象LAN数を含めて予約できるrule priority
- `OUTER_IPIP_ALLOW`: `auto`、`yes`、`no`。確認前は `auto`

## `routed-networks.conf`

1行に `IFACE CIDR` を記載します。同じinterface、CIDR、rule priorityの重複は拒否されます。固定IP経路へ送るLANだけを列挙してください。

## `provider-update.conf`

`UPDATE_URL`、`UPDATE_USERNAME`、`UPDATE_PASSWORD` を契約情報から設定します。HTTPSを使用し、次を維持してください。

```text
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
```

更新先がHTTPしか提供しない場合、通信経路上の認証情報を暗号化できません。リスクを受け入れる場合に限り `ALLOW_INSECURE_UPDATE_HTTP=yes` とし、`INSECURE_UPDATE_HTTP_HOST` にURLのhostを完全一致で指定します。

## Permissions

```sh
sudo chown -R root:root /data/unifi-jpix-tunnel-repair
sudo chmod 755 /data/unifi-jpix-tunnel-repair /data/unifi-jpix-tunnel-repair/scripts
sudo chmod 700 /data/unifi-jpix-tunnel-repair/config /data/unifi-jpix-tunnel-repair/state
sudo chmod 755 /data/unifi-jpix-tunnel-repair/scripts/*.sh
sudo chmod 600 /data/unifi-jpix-tunnel-repair/config/*
```
