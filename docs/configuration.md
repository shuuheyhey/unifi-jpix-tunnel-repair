# Configuration

設定は`/data/unifi-jpix-tunnel-repair/config`へ置きます。directoryはroot所有・mode `0700`、各fileはroot所有・mode `0600`です。設定はshellとしてsourceされず、未知key、重複key、不正な値、symlink、安全でないownerやmodeがあれば処理を中止します。

例ファイルのaddressはdocumentation用のsynthetic valueです。実値に置換しない限りvalidationで拒否されます。

## `gateway.conf`

| Key | 内容 | 制約 |
| --- | --- | --- |
| `WAN_IF` | BRへのIPv6 routeが選ぶWAN interface | 実機のrouteで確認 |
| `TUN_IF` | UniFiが作成したBR一致トンネル | 独自作成しない |
| `STATIC_V4` | 契約で割り当てられた固定IPv4 | 単一address、tunnelへ`/32`で設定 |
| `BR_V6` | 契約資料のBR IPv6 | トンネルremoteと照合 |
| `IID` | 固定IPサービス用interface identifier | 4組の16bit hexadecimal表記 |
| `TUN_MTU` | トンネルMTU | `1280`〜`1500` |
| `TCP_MSS` | clampするTCP MSS | `536`〜`1460` |
| `ROUTE_TABLE` | 対象LAN専用のIPv4 table | `1`〜`4294967295`、既存用途と重複不可 |
| `RULE_PREF_BASE` | policy ruleの開始priority | `1`〜`32700`、対象LAN数を含む範囲が空いていること |
| `WATCH_INTERVAL_SECONDS` | watchの検査間隔 | 1秒以上の整数 |
| `UPDATE_INTERVAL_SECONDS` | provider再通知の最小間隔 | 0で定期通知無効、最大10桁の整数 |
| `OUTER_IPIP_ALLOW` | outer IPIP accept ruleの扱い | `auto`、`yes`、`no` |

### `OUTER_IPIP_ALLOW`

- `auto`: 既存の完全一致accept ruleを検査します。確認できなくてもruleを追加せず警告します。初回はこれを使用します。
- `yes`: BRからローカルendpointへのIPIPだけを許可するtag付きruleを管理します。通信要件と既存firewallを確認した後だけ使用します。
- `no`: このプロジェクトはouter accept ruleを管理しません。別の安全な許可経路が必要です。

## `routed-networks.conf`

1行に`IFACE CIDR`を記載します。空行と行頭commentを使用できます。

```text
bridge-interface private-ipv4-cidr
```

- 固定IPv4経路へ送るLANだけを列挙します。
- interface、CIDR、生成されるrule priorityの重複は拒否されます。
- 対象外LANはこのprojectのpolicy routingやSNATへ入れません。
- 実機のinterface名とCIDRを公開Issueへ貼り付けないでください。

## `provider-update.conf`

| Key | 内容 |
| --- | --- |
| `UPDATE_URL` | providerが指定する更新endpoint |
| `UPDATE_USERNAME` | 更新用username |
| `UPDATE_PASSWORD` | 更新用password |
| `ALLOW_INSECURE_UPDATE_HTTP` | HTTPへの明示opt-in。既定は`no` |
| `INSECURE_UPDATE_HTTP_HOST` | HTTP時だけ、URL authorityと完全一致させるhost |

HTTPSでは次を維持します。

```text
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
```

HTTPしか提供されない場合、認証情報を通信経路上で暗号化できません。リスクを受け入れた場合だけ`yes`を指定し、URL authorityとhost設定を完全一致させます。明示portを含むauthorityは許可されません。URL内userinfo、control character、未知key、重複keyは拒否されます。

## Configの作成

```sh
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/gateway.conf.example /data/unifi-jpix-tunnel-repair/config/gateway.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/routed-networks.conf.example /data/unifi-jpix-tunnel-repair/config/routed-networks.conf
sudo install -m 600 /data/unifi-jpix-tunnel-repair/config/provider-update.conf.example /data/unifi-jpix-tunnel-repair/config/provider-update.conf
```

編集後にownerとmodeを確認します。

```sh
sudo stat -c '%U:%G %a %n' /data/unifi-jpix-tunnel-repair/config /data/unifi-jpix-tunnel-repair/config/*
```

期待値はdirectoryが`root:root 700`、各configが`root:root 600`です。config、state、完全診断はGitへ追加しないでください。
