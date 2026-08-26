# Architecture

## 目的

UniFi OSが管理するnative IPv6接続を維持しながら、JPIX「v6プラス」固定IPサービスの**固定IPv4 1個**に必要なIPv4 over IPv6の状態を補正します。UniFiの設定DBは編集せず、Linuxの既存トンネル、address、route、policy rule、netfilterへ限定して処理します。

通常の「v6プラス」MAP-E、複数固定IPv4、HB46PP、他VNEのIPIPは対象外です。方式の違いと非対応理由は[サービスと方式の技術解説](service-and-protocols.md)を参照してください。

## 前提

- UniFiがBRをremote endpointとするIPIP6トンネルを作成済みであり、共有所有の制約を理解している
- WANでnative IPv6が利用でき、BRへのroute sourceを取得できる
- delegated LAN `/64`のkernel routeを一意に持つLAN bridgeを`ENDPOINT_IF`として明示できる
- 契約で固定IPv4、BR IPv6、interface identifierが提供されている
- 固定IPv4へ送るLAN interfaceとCIDRを明示できる
- root以外が配置済みscript、config、stateを書き換えられない

独自トンネルの新規作成、UniFi管理トンネルの削除、受信DNAT、公開server用firewall、複数固定IPv4のroute/NATは、この設計の対象外です。

## コンポーネント

1. `preflight`はconfigを読まず、exact platform tuple、legacy backend、IPv6、PD route、IPIP6候補、UniFi user chainと親jumpを共有安全に観測します。
2. `diag`はconfigを検証し、BR route、WAN、対象トンネル、予約table、policy rule、netfilterを読み取ります。stdoutは共有安全で、完全値は明示指定した新規mode `0600` fileだけへ出力します。
3. `apply`は現在状態を完全に検査してから、固定IPv4、endpoint、専用route table、policy rule、SNAT、MSS、任意のouter IPIP許可を収束させます。
4. `trigger`はnetlink変化を監視し、endpoint変更時に再適用とprovider通知を行います。
5. `watch`は一定間隔でinvariantを検査し、driftだけを修復します。
6. `update`はHTTPSを既定としてproviderへendpointを通知し、検証済み成功だけをstateへ保存します。

## データフロー

1. BRへのIPv6 routeからunderlay deviceとsource addressを検証します。このsource prefixをendpointへ流用しません。
2. 明示したLAN bridge `ENDPOINT_IF`の一意なglobal kernel `/64`と契約IIDからローカルトンネルendpointを導出します。WANや非bridge interfaceは拒否します。
3. 設定されたトンネルがBR remote、許可されたattribute shape、IPIP6 mode、意図したIPv4を持つことを確認します。
4. 対象LANだけを`from CIDR iif IFACE lookup TABLE`で専用route tableへ送り、固定IPv4でSNATします。
5. `TUN_MTU + 40 <= underlay MTU`と`TCP_MSS <= TUN_MTU - 40`を検証し、TCP MSSを往復方向で調整します。
6. UniFi parent chainから一意に接続されたuser hookだけを使用し、global chainへfallbackしません。
7. endpoint変更時だけprovider通知を行います。

## systemdの起動関係

- `apply.service`はWAN readinessを待ってからapplyし、成功後に更新通知を試行します。
- `trigger.service`と`watch.service`は`apply.service`を必須とします。インストーラーはenableせず、手動apply、rollback、再applyを通過した環境でoperatorが明示的に有効化します。
- `update.timer`は1分ごとにdue判定を起動します。実際の通知間隔は`UPDATE_INTERVAL_SECONDS`で制御します。
- インストーラーはunitを配置するだけで、enableやstartを行いません。

2026-08-26の検証実機では3 unitをenableし、再起動後のboot apply、active化、対象LAN通信復帰、短時間soak、timer初回tickを確認済みです。残る実機gateは[Validation](validation.md#現在の実機検証範囲)で管理します。

## 管理state

`/data/unifi-jpix-tunnel-repair/state`はroot所有、mode `0700`です。主なstateは次のとおりです。

- `original-tunnel.env`: 初回変更前のトンネル状態
- `managed-networks`: このプロジェクトが管理するLANとrule情報
- `last-apply.env`: 最後に収束したendpointとnetfilter情報
- `last-provider-update.state`: 最後に成功したprovider通知

stateはshellとしてsourceせず、許可されたkeyと値だけを厳格に解析します。

## 失敗時の原則

- preflightや診断はネットワークを変更しない
- config、権限、現在状態、予約範囲に異常があれば変更前に停止する
- apply途中の失敗やsignalでは、そのinvocationで行った変更をrollbackする
- 所有権を証明できない既存route、rule、netfilter ruleは削除しない
- `off`は保存済みoriginal stateと、このプロジェクトがtag付けした状態だけを対象にする

## UniFi OS 5で確認したPD表現

実機ではDHCPv6-PDが成功していてもaggregate `/48`〜`/63` routeが残らず、LAN bridge向け`/64`が`proto kernel`として展開されました。preflightはaggregate routeを`DHCPV6_PD_ROUTE`、bridge上のglobal `/64`を`DHCPV6_PD_LAN64_EVIDENCE`として別々に報告し、どちらかが`present`ならPD成立の証拠として扱います。WANやトンネルなどbridge以外の`/64`はfallback evidenceから除外します。

## Trust boundaries

- `/data/unifi-jpix-tunnel-repair/scripts`: root所有、非root書き込み不可、symlink不可
- `/data/unifi-jpix-tunnel-repair/config`: root所有、mode `0700`、各configはmode `0600`
- `/data/unifi-jpix-tunnel-repair/state`: root所有、mode `0700`
- `/run/unifi-jpix-tunnel-repair.lock`: 複数処理の同時変更を防止
- provider通知: HTTPSが既定。HTTPは明示opt-inと完全一致hostが必要

## 管理しないもの

- UniFiのWAN、LAN、VLAN、DHCPv6-PD設定
- ONU、ホームゲートウェイ、上流routerの設定
- DNS filteringや広告blocking
- ISP契約情報、BR、固定IPv4の自動検出
- MAP rule配信とport-set計算
- HB46PPのDNS discovery、HTTP(S) provisioning、JSON/TTL/token管理
- 複数固定IPv4、受信DNAT、port forwarding、公開server用firewall
- UniFi upgrade後の互換性保証
