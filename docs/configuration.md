# Configuration

設定は`/data/unifi-jpix-tunnel-repair/config`へ置きます。directoryはroot所有・mode `0700`、各fileはroot所有・mode `0600`です。設定はshellとしてsourceされず、未知key、重複key、不正な値、symlink、安全でないownerやmodeがあれば処理を中止します。

> [!IMPORTANT]
> このschemaはJPIX「v6プラス」固定IPサービスの1 IP品目専用です。通常v6プラスのMAP-E、複数IP品目、HB46PP、他VNEのparameterを入力しないでください。同じ`BR`、`IID`、`username`、`password`という名称でも意味や配布方式が異なります。

例ファイルのaddressはdocumentation用のsynthetic valueです。実値に置換しない限りvalidationで拒否されます。

## `gateway.conf`

| Key | 内容 | 制約 |
| --- | --- | --- |
| `WAN_IF` | BRへのIPv6 routeが選ぶWAN interface | 実機のrouteで確認 |
| `TUN_IF` | UniFiが作成したBR一致トンネル | 独自作成しない |
| `ENDPOINT_IF` | 契約IIDを載せるdelegated LAN `/64`のkernel routeを持つLAN bridge | bridgeとして存在し、global kernel `/64`がexact interface上で一意 |
| `STATIC_V4` | 契約で割り当てられた固定IPv4 | 単一address、tunnelへ`/32`で設定 |
| `BR_V6` | 契約資料のBR IPv6 | トンネルremoteと照合 |
| `IID` | 固定IPサービス用interface identifier | 4組の16bit hexadecimal表記 |
| `TUN_MTU` | トンネルMTU | `1280`〜`1500`、かつ`TUN_MTU + 40 <= underlay MTU` |
| `TCP_MSS` | clampするTCP MSS | `536`〜`1460`、かつ`TCP_MSS <= TUN_MTU - 40` |
| `ROUTE_TABLE` | 対象LAN専用のIPv4 table | `1`〜`4294967295`、既存用途と重複不可 |
| `RULE_PREF_BASE` | policy ruleの開始priority | `1`〜`32700`、対象LAN数を含む範囲が空いていること |
| `WATCH_INTERVAL_SECONDS` | watchの検査間隔 | 1秒以上の整数 |
| `UPDATE_INTERVAL_SECONDS` | provider再通知の最小間隔 | 0で定期通知無効、最大10桁の整数 |
| `OUTER_IPIP_ALLOW` | outer IPIP accept ruleの扱い | `auto`、`yes`、`no` |

`STATIC_V4`は1個の固定IPv4だけを受け付け、常にtunnelへ`/32`で設定します。IPv4 prefix、address range、MAP-Eの共有IPv4やPSIDは表現できません。`BR_V6`と`IID`も契約情報として手動設定するため、HB46PP responseを取り込むinterfaceではありません。

`WAN_IF`のroute source上位64bitをlocal endpointへ流用しません。WANのIA_NA prefixとLANへdelegationされたprefixは異なることがあります。local endpointは、LAN bridgeである`ENDPOINT_IF`の一意なglobal kernel `/64`と`IID`だけから合成します。WANや非bridge interfaceは指定できません。bridge自身にglobal addressが表示されなくてもkernel `/64` routeが存在する構成があります。

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
- CIDRはRFC1918内のcanonical network addressだけを受理します。host bit、先頭zero、public CIDRを拒否します。
- CIDRは指定interfaceのIPv4 connected routeと完全一致する必要があります。
- interface、CIDR、生成されるrule priorityの重複と、対象CIDR同士のoverlapを拒否します。
- policy ruleは`from CIDR iif IFACE lookup TABLE`の形で、sourceとingress interfaceの両方へ限定されます。
- 対象外LANはこのprojectのpolicy routingやSNATへ入れません。
- 実機のinterface名とCIDRを公開Issueへ貼り付けないでください。

## `provider-update.conf`

これはJPIX固定IPのCPE側IPv6 endpointをアドレス解決サーバーへ通知する設定です。HB46PPのprovisioning server設定ではありません。両者の違いは[サービスと方式の技術解説](service-and-protocols.md#47-アドレス解決サーバーへの通知)を参照してください。

| Key | 内容 |
| --- | --- |
| `UPDATE_URL` | providerが指定する更新endpoint |
| `UPDATE_USERNAME` | 更新用username |
| `UPDATE_PASSWORD` | 更新用password |
| `ALLOW_INSECURE_UPDATE_HTTP` | HTTPへの明示opt-in。既定は`no` |
| `INSECURE_UPDATE_HTTP_HOST` | HTTP時だけ、URL authorityと完全一致させるhost |

公開されているαWebの設定ガイドとFAQ、CiscoのJPIX設定例では、更新・再設定endpointとして`http://fcs.enabler.ne.jp/update`が案内されています。契約ISPの最新通知書でも同じ値が指定されている場合は、次の形で設定します。

```text
UPDATE_URL=http://fcs.enabler.ne.jp/update
UPDATE_USERNAME=replace-with-reconfiguration-user-id
UPDATE_PASSWORD=replace-with-reconfiguration-password
ALLOW_INSECURE_UPDATE_HTTP=yes
INSECURE_UPDATE_HTTP_HOST=fcs.enabler.ne.jp
```

`UPDATE_USERNAME`には固定IP登録完了通知の「再設定ユーザID」、`UPDATE_PASSWORD`には「再設定パスワード」を使用します。UniFi API key、UniFi login、SSH password、device SSH password、ISP会員ページのpasswordを入力しません。credentialを`UPDATE_URL`のqueryへ手作業で追加する必要もありません。projectが`user`と`pass`をURL encodeしてGET parameterとして送信します。

URLはpathを含む契約値です。`http://fcs.enabler.ne.jp/`へ短縮せず、`/update`まで正確に指定します。ただし、契約ISPの通知書が別のhost、path、schemeを明示している場合は推測せず、その値とISP supportを優先してください。詳しいrequest flow、手動再設定画面との違い、資料間の表記差は[サービスと方式の技術解説](service-and-protocols.md#471-fcsenablernejpとは何か)を参照してください。

HTTPSでは次を維持します。

```text
ALLOW_INSECURE_UPDATE_HTTP=no
INSECURE_UPDATE_HTTP_HOST=
```

HTTPしか提供されない場合、認証情報を通信経路上で暗号化できません。`fcs.enabler.ne.jp`の公開例もHTTPであり、この危険は変わりません。2026-08-26の公開資料確認と検証回線からの到達性確認でも正式なHTTPS提供を確認できなかったため、検証実機はHTTPを継続しています。リスクを受け入れた場合だけ`yes`を指定し、URL authorityとhost設定を完全一致させます。providerが明示していないHTTPS URLへ推測で変更しません。明示portを含むauthorityは許可されません。URL内userinfo、control character、未知key、重複keyは拒否されます。

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

## 値を決めるworksheet

実値はこの文書やIssueへ書かず、UDM内のroot-only memoで次の順に確定します。

1. 契約通知から固定IPv4、BR IPv6、IID、provider再設定情報を転記する。
2. BRへのIPv6 routeから`WAN_IF`を確定する。
3. `--discover`でBR remoteと一致するUniFi tunnelを一意にし、`TUN_IF`を確定する。
4. UniFi LAN設定、bridge inventory、kernel routeを照合し、delegated global `/64`が一意なLAN bridgeを`ENDPOINT_IF`にする。
5. underlay link MTUから`TUN_MTU`を決め、IPv6 outer header 40 bytesが収まることを確認する。
6. `TCP_MSS`がtunnel MTUからIPv4 header 40 bytesを引いた値以下であることを確認する。
7. 対象LANだけを列挙し、connected route完全一致とnon-overlapを確認する。
8. route tableと連続するrule priorityが既存用途と重複しないことを確認する。
