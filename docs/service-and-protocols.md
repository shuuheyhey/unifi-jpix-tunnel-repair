# JPIX v6プラスとIPv4 over IPv6方式

## この文書の結論

このプロジェクトが対応するのは、**UDM Pro上のJPIX「v6プラス」固定IPサービス、固定IPv4 1個、DHCPv6-PD構成**だけです。通常の「v6プラス」はMAP-Eであり、このプロジェクトが扱う固定IP用IPIPとは別方式です。HB46PPはIPIPそのものではなく、IPIPやDS-Liteなどの接続パラメータを取得するためのプロビジョニング方式であり、このプロジェクトは実装していません。

## 1. まず分けるべき3つの層

「IPv4 over IPv6」は、IPv4通信をIPv6網で運ぶ技術の総称です。名称が似ていても、次の3層を混同すると設定を誤ります。

| 層 | 決めるもの | 例 |
| --- | --- | --- |
| IPv6アクセス | CPEがIPv6インターネットへ接続し、prefixやaddressを得る方法 | IPv6 IPoE、RA、DHCPv6-PD |
| IPv4 over IPv6転送 | IPv4 packetをIPv6網でどう運ぶか | MAP-E、IPIP、DS-Lite、Lightweight 4over6、MAP-T、464XLAT |
| プロビジョニング | CPEが転送方式と必要パラメータをどう知るか | JPIX固有のMAP rule配信、契約情報による固定設定、HB46PP |

RAとDHCPv6-PDはIPv6側のprefix/address取得方法です。MAP-EとIPIPはIPv4 packetの運び方です。HB46PPは必要情報の配り方です。これらは排他的な同一分類ではありません。たとえば、DHCPv6-PDでIPv6 prefixを得て、HB46PPでIPIPのendpointを得る構成も概念上成立します。

## 2. 用語

| 用語 | この文書での意味 |
| --- | --- |
| CE/CPE | 利用者宅のルーター。JPIX資料では主にCE、HB46PP仕様ではCPE |
| BR | IPv4 over IPv6の事業者側境界ルーター。JPIX固定IPでは固定IP用BR |
| MAP-BR | MAP-Eの事業者側BR |
| AFTR | DS-Liteの事業者側終端。共有NATも担当 |
| IID | IPv6 addressの下位64 bitを構成するInterface Identifier |
| RA | Router Advertisement。IPv6 routerやprefixの情報を広告 |
| DHCPv6-PD | Delegating RouterからCPEへIPv6 prefixを委任する仕組み |
| IPIP | IP packetを別のIP packetでカプセル化する方式。この文書ではIPv4 over IPv6 |
| アドレス解決サーバー | JPIX固定IPで、現在のCPE側IPv6 endpointを通知する相手。HB46PPのプロビジョニングサーバーとは別物 |

## 3. 通常のJPIX「v6プラス」

### 3.1 方式

通常の「v6プラス」は、IPv6をIPoEで直接通信し、IPv4をMAP-EでIPv6網上へ運びます。JPIXの公開開発ガイドは、JPIX側にMAP rule配信サーバーとMAP-BRがある構成を示しています。

MAP-Eでは、CEがMAP ruleを取得し、委任されたIPv6 prefixとruleから次を導出します。

- CEが共有するグローバルIPv4 address
- CEが使用できる送信元port set
- MAP-BRのIPv6 address
- IPv4/IPv6 prefix、EA bit length、PSID offsetなどの変換規則

IPv4 packetはCEでNAPTされ、許可されたport setを使い、IPv6へカプセル化されてMAP-BRへ送られます。固定IPv4サービスのように、契約した単一IPv4を任意のportで占有する方式ではありません。

```text
LAN端末
  -> CEでNAPT（共有IPv4 + 指定port set）
  -> MAP ruleに従ってIPv4をIPv6へカプセル化
  -> MAP-BR
  -> IPv4 Internet
```

### 3.2 固定IPとの決定的な違い

| 観点 | 通常v6プラス（MAP-E） | v6プラス固定IP（IPIP） |
| --- | --- | --- |
| IPv4 | 他利用者と共有 | 契約者が専有 |
| 利用可能port | MAP ruleで割り当てられた範囲 | 1 IP品目では原理上全port。ただしCPE firewall/NAT設定は別途必要 |
| 接続情報 | MAP rule配信サーバーから取得 | 固定IPv4、BR、IID、通知先などを契約情報として設定 |
| 事業者側終端 | MAP-BR | 固定IP用BR |
| inbound公開 | 任意portの公開は困難 | サービス上は可能だが、CPE側DNAT/firewall設計が必要 |
| このproject | 非対応 | 1 IP品目だけ対応対象 |

このプロジェクトには、MAP ruleの取得・検証、EA bit/PSID計算、port-set制約付きNAPT、MAP-BR選択がありません。そのため、トンネルがIPv4 over IPv6に見えても通常v6プラスへ転用できません。

## 4. JPIX「v6プラス」固定IPサービス

### 4.1 サービス全体

JPIXは固定IPサービスを、IPv6 IPoEとIPv6網上のIPv4接続を組み合わせたdual-stack serviceとして説明しています。公開情報上のIPv4品目は1/8/16/32/64 IP、IPv6は半固定のprefixです。JPIXの公開開発ガイドでは、IPv4側の転送方式をIPinIP、事業者側設備を固定IP用BRとして示しています。

このプロジェクトが扱うのは1 IP品目だけです。複数IP品目では、グローバルIPv4 subnetのroute、LANへの直接割り当て、静的NATなど、1個の`/32`をSNATに使う構成とは異なる設計が必要です。

### 4.2 契約・設定パラメータ

1 IP構成の公開設定例と現在の実装では、少なくとも次の値を区別して扱います。

| 値 | 役割 | project設定 |
| --- | --- | --- |
| 固定IPv4 | 利用者が外部通信に使う専有IPv4 | `STATIC_V4` |
| BR IPv6 | IPIPの事業者側remote endpoint | `BR_V6` |
| IID | CPE側local endpointの下位64 bit | `IID` |
| IPv6 prefix | RAまたはDHCPv6-PDで回線側から取得 | configへ固定せず、BRへのroute sourceから観測 |
| 更新URL | 現在のCPE側IPv6 endpointの通知先 | `UPDATE_URL` |
| 更新認証情報 | 通知要求の認証 | `UPDATE_USERNAME`、`UPDATE_PASSWORD` |

固定IPv4とIPv6 endpointは別の値です。固定されるのは外側から見えるIPv4であり、CPE側IPv6 prefixは変更され得ます。そのため、現在のIPv6 prefixと契約IIDを結合してlocal endpointを構成し、prefix変更時にはBR側が新endpointへ到達できるよう通知します。

### 4.3 RAとDHCPv6-PD

JPIXの公開ガイドは一般シーケンスとしてRA/DHCPv6-PDを示し、メーカー設定例は回線品目、ひかり電話、HGWの有無に応じてRA proxyまたはDHCPv6-PDを選びます。これはIPv4 over IPv6方式の違いではなく、CPEがIPv6 prefixを得てLANへ配る方法の違いです。

- RA構成では、WAN側RAから得たprefixをproxyまたは参照し、契約IIDを使ったaddressを構成します。
- DHCPv6-PD構成では、委任prefixの一部をLANへ割り当て、同様に契約IIDを使ったaddressを構成します。
- HGW配下かONU直下か、フレッツ光ネクストかクロスかによって、適切な取得方法は変わります。

現在のprojectは、UDM ProのDHCPv6-PD成立をpreflight条件にしています。RAだけの構成は公開例として存在しますが、本projectでは未実装・未検証です。また、UniFi OS 5はaggregate PD routeを残さず、LAN bridge上のglobal `/64`だけを展開することがあるため、preflightは両方の表現を別々に検査します。

### 4.4 local endpointの作り方

概念上のlocal endpointは次の組み合わせです。

```text
CPE側local IPv6 endpoint = 現在有効なIPv6 /64 prefix + 契約IID
```

このprojectは、設定ファイルにprefixを保存しません。BRへのIPv6 routeを問い合わせ、そのrouteが選ぶsource addressの上位64 bitを現在のprefixとして使い、契約IIDと合成します。その後、合成結果をWANへ`/128`で設定し、UniFi管理トンネルのlocal endpointに使用します。

この方式では、BRへのrouteが意図したWANを選ぶこと、source addressが一意かつglobalであること、IIDが契約値と一致することが重要です。どれかを推測すると、native IPv6は動いていても固定IPv4の戻り通信が失敗します。

### 4.5 packetの往復

送信方向は次の順序です。

```text
対象LANのprivate IPv4 packet
  -> policy ruleでproject専用IPv4 route tableへ
  -> 固定IPv4へSNAT
  -> IPIP tunnelへ投入
  -> IPv6 outer headerを付与（local endpoint -> BR）
  -> JPIX固定IP用BRでdecapsulation
  -> IPv4 Internet
```

受信方向は逆です。

```text
IPv4 Internet
  -> 契約固定IPv4
  -> JPIX固定IP用BR
  -> 現在登録されたCPE側IPv6 endpointへIPv4-in-IPv6で送信
  -> UDM Proでdecapsulation
  -> conntrack/NAT/firewall
  -> LAN端末
```

IPv6 outer packetのNext HeaderはIPv4を示すProtocol 4です。UDPやTCPの特定portでトンネルを張る方式ではないため、outer IPv6 firewallはBRからlocal endpointへのProtocol 4を扱う必要があります。このprojectの`OUTER_IPIP_ALLOW`は、その許可ruleを自動管理するか、既存ruleに任せるかを制御します。

### 4.6 MTUとTCP MSS

IPv4 packetへIPv6 outer headerが加わるため、物理interfaceと同じMTUのままではfragmentationやPath MTU Discovery依存の障害が起きます。JPIXが掲載するYamahaの例はIPIP tunnel MTUを1460にしています。このprojectも既定値を1460とし、IPv4/TCP headerを考慮したTCP MSS 1420を往復方向とrouter-originated trafficへ設定します。

これらはprojectの既定値であり、すべての回線・機器で無条件に正しいと保証する値ではありません。実機ではICMP Packet Too Big、PMTU、VPNなどの追加encapsulationを含めて確認します。

### 4.7 アドレス解決サーバーへの通知

IPv6 prefixが変わると、契約IIDが同じでもlocal endpoint全体は変わります。JPIX掲載のメーカー例では、起動時にprefixを得た場合とprefix変更時に、更新URL、username、passwordを使ってCPE側IPv6 addressをアドレス解決サーバーへ通知し、トンネル通信の再開を早めます。

この通知はHB46PPではありません。

- JPIX固定IPの通知は、既に設定済みの固定IPv4、BR、IIDを前提に、現在のIPv6 endpointを事業者側へ知らせます。
- HB46PPは、CPEが接続方式そのものとBR/AFTR、local endpoint、固定IPv4などを取得します。

このprojectの`update`は、合成したlocal endpointがWANに存在することを確認し、そのaddressを通信sourceとして更新URLへGETを送ります。transport error時は10秒間隔で最大3回試行し、HTTP 200かつ明示的な失敗bodyでない場合だけ成功stateを保存します。HTTPSを既定とし、HTTPはhostを固定した明示opt-inが必要です。

`update.timer`は1分ごとにdue判定を起動しますが、実際の再通知間隔は`UPDATE_INTERVAL_SECONDS`で制御します。これはprefix変化を待つevent-driven通知を補うproject上の設計であり、HB46PPのTTL処理ではありません。

### 4.8 1 IPと複数IP

| 項目 | 1 IP | 8/16/32/64 IP |
| --- | --- | --- |
| tunnel上のIPv4 | 単一host addressとして扱える | routed prefixとして扱う設計が必要 |
| private LANの出口 | 固定IPv4へのmasquerade/SNAT | SNAT、静的NAT、またはglobal IPv4のLAN割当など複数方式 |
| inbound | DNAT/firewallを別途設計 | route、host割当、静的NAT、firewallを個別設計 |
| このproject | 単一`/32`と対象LAN SNATのみ | 非対応 |

JPIXのサービス仕様が複数IPを提供していても、対応routerごとに対応数が異なります。JPIXのサービス対応と、本projectまたは特定メーカー機器の実装対応を同一視しないでください。

## 5. HB46PP

### 5.1 何を標準化するか

HB46PPは`HTTP-Based IPv4 over IPv6 Provisioning Protocol`の略称です。VNEごとに異なっていた接続方式の判定とパラメータ配布を共通化し、CPE実装の複雑さを減らすための国内標準プロビジョニング方式です。

HB46PPはトンネル形式そのものではありません。HB46PP version 1の仕様は、返却可能な方式としてMAP-E、DS-Lite、Lightweight 4over6、MAP-T、464XLAT、IPIPを定義しています。実際のrouter製品がその全方式を実装するとは限りません。たとえばYamahaのHB46PP機能の公開資料は、同機能でDS-LiteとIPIPをサポートし、MAP-Eは対象外と説明しています。

### 5.2 発見から適用まで

HB46PPの基本フローは次のとおりです。

1. CPEが専用名`4over6.info`のDNS TXT recordを問い合わせます。
2. TXTからHB46PP version、provisioning server URL、certificate検証条件を取得します。
3. CPEが対応方式などの情報をHTTPまたはHTTPSでserverへ送ります。必要なserviceではusername/passwordも使用します。
4. serverがJSONでVNE/ISP/service情報、TTL、token、利用優先順、方式別parameterを返します。
5. CPEが`order`の優先順と自身の対応能力に従って方式を選び、networkを設定します。
6. TTL経過時または自身のIPv6 address変更時に再取得します。失敗時は仕様で定める待ち時間後に再試行します。

IPIPが選ばれた場合、JSONはCPE側IPv6 local endpoint、provider側IPv6 remote endpoint、固定IPv4 address/prefixを提供できます。つまり、このprojectで手動設定する`BR_V6`、`STATIC_V4`、合成local endpointに相当する値を、HB46PPではserver responseから得る設計です。

### 5.3 security上の重要点

HB46PP仕様はHTTP、certificate検証なしHTTPS、自己署名certificate、public CA certificateなど複数のtransportを扱います。username/passwordを送る場合は、server名とcertificate検証条件を満たすかを確認する必要があります。token、cached provisioning data、TTL、redirect、unknown JSON key、失敗応答もstate machineの一部です。

単に更新URLへcredential付きGETを送れるだけではHB46PP対応になりません。DNS TXT発見、versionとtransport policyの検証、request生成、JSON schema検証、方式選択、parameter適用、token/cache/TTL、retry state machineまで必要です。

### 5.4 このprojectがHB46PP非対応である根拠

このprojectには次がありません。

- `4over6.info`のDNS TXT discovery
- HB46PP request capabilityの生成とHTTP(S) provisioning request
- JSON response、`order`、方式別objectのparser
- `token`、provisioning TTL、redirect、cacheの管理
- MAP-E、DS-Lite等の方式選択と切替

現在の`provider-update.conf`はJPIX固定IPのendpoint通知用です。HB46PP credentialやprovisioning server設定として使用してはいけません。

## 6. 他方式との比較

| 方式 | IPv4の利用形態 | CPEからの転送 | 事業者側の主な役割 | このproject |
| --- | --- | --- | --- | --- |
| JPIX通常v6プラス / MAP-E | 共有IPv4 + port set | ruleに従うIPv4-in-IPv6 | MAP-BR | 非対応 |
| JPIX固定IP / IPIP | 専有IPv4またはprefix | IPv4-in-IPv6 | 固定IP用BR、endpoint解決 | 1 IPのみ対象 |
| DS-Lite | CPE側にpublic IPv4を持たず共有 | B4からAFTRへIPv4-in-IPv6 | AFTRでCGN/NAT44 | 非対応 |
| Lightweight 4over6 | 共有IPv4 + port set | IPv4-in-IPv6 | lwAFTR、binding管理 | 非対応 |
| MAP-T / 464XLAT | address family変換 | IPv4/IPv6 translation | translator/NAT64等 | 非対応 |
| HB46PP | 転送方式ではない | control planeでparameter取得 | DNS + provisioning server | 非対応 |

「IPIPを使う他VNEサービス」はデータ転送だけを見ると似ています。しかし、endpointの得方、認証、更新、prefix/address品目、BR/AFTR、failure recoveryが異なります。個別serviceの仕様を実装・検証するまで、このprojectの対応対象には含めません。

## 7. project実装との対応

| JPIX固定IPで必要な処理 | projectの処理 | 境界・注意 |
| --- | --- | --- |
| IPv6 IPoEとprefix取得 | UniFi設定を変更せず観測 | UniFi側で事前に成立している必要がある |
| local endpoint生成 | BR route sourceの上位64 bit + `IID` | DHCPv6-PD構成だけを対象 |
| IPIP tunnel | UniFi管理tunnelを`ipip6`、local、remoteへ収束 | tunnelを新規作成しない |
| fixed IPv4 | tunnelへ`STATIC_V4/32` | 1 IPだけ |
| IPv4 route | 対象LANを専用tableのdefault routeへpolicy routing | 対象外LANは管理しない |
| NAT | 対象LANを固定IPv4へSNAT | inbound DNATは管理しない |
| MTU/MSS | tunnel MTUと3方向のTCP MSS rule | 実機PMTU確認が必要 |
| outer IPv6 firewall | BRからlocalへのProtocol 4を検査・任意管理 | `auto`は未確認でもruleを追加しない |
| endpoint通知 | prefix変化後とtimerで更新URLへ通知 | HB46PPではない |
| drift/reboot recovery | trigger、watch、systemdで再適用 | 実機検証未完了 |

## 8. 実機で確認済みのことと未確認のこと

2026-08-26時点のUDM Pro・UniFi OS 5系実機では、次を確認しています。

- native IPv6 default routeとglobal address
- DHCPv6-PD処理、およびLAN bridgeへのglobal `/64`展開
- UniFi管理IPIP6 tunnel候補とUniFi user chain
- 外部接続判定`5999`、固定IPv4/IPv6、フレッツ西日本、v6プラス用試験の成功

この結果は、現在の回線と既存構成がJPIX固定IPとして通信できている証拠です。次はまだ別々に検証する必要があります。

- project実configでのdry-runと手動apply
- apply前後での対象LAN・対象外LANの通信差分
- IPv6 prefix変更時のendpoint再構成と通知
- UDM再起動後の順序、watch/triggerの収束、二重ruleがないこと
- `off`とrollbackによる元状態への復帰

## 9. JPNE/JPIX IPv4/IPv6接続判定ページ

### 9.1 何のためのページか

[`http://wa.kiriwake.jpne.co.jp/`](http://wa.kiriwake.jpne.co.jp/)は、利用中のbrowserから複数のIPv4/IPv6 test endpointへ実際に接続し、どの経路が利用できるかを切り分けるページです。画面タイトルは「IPv4/IPv6接続判定ページ」で、IPv4、IPv6、DNS利用有無、フレッツ東西の地域限定到達性、v6プラス専用到達性をまとめて確認できます。

現在は[`https://kiriwake.jpne.co.jp/`](https://kiriwake.jpne.co.jp/)にも判定ページがあります。画面や試験項目は運営側で変更され得るため、障害対応でISPまたはsupportからURLを指定された場合は、そのURLを使ってください。変更前後を比較するときは、同じURL、同じLAN、同じ端末、同じbrowser条件にそろえます。

これはspeed testではなく、経路とservice種別を切り分ける疎通試験です。帯域、latency、packet loss、長時間安定性、IPIP tunnel内部の設定内容を測定するものではありません。

### 9.2 正しい使い方

1. 判定対象のLANへ接続したPCまたはsmartphoneを用意します。UDM ProのSSH shellからではなく、そのLANを実際に利用するbrowserで開きます。
2. VPN、HTTP/SOCKS proxy、corporate secure gateway、browserのprivacy relayなど、Internet出口を変更する機能を停止します。停止できない場合は、その経路を含んだ結果として記録します。
3. 判定ページを開き、`測定準備完了`と各試験の`Ready`が表示されるまで待ちます。JavaScriptを無効にしていると試験できません。
4. `判定開始`を1回だけ押し、全項目が終了するまで待ちます。ページは短時間の大量accessを一時制限すると案内しているため、連打や自動loopを行いません。
5. 判定文、試験1〜10、IPv4/IPv6の有無を確認します。projectの変更前後で比較する場合は、同じ条件でもう一度実行します。

対象LANと対象外LANを分けている場合は、両方で実行します。対象LANでは表示IPv4が契約固定IPv4と一致することを期待します。対象外LANは既存policyどおりの出口であることを確認し、必ずしも固定IPv4との一致を期待しません。

### 9.3 試験1〜10の意味

2026-08-26に旧URLで確認した試験項目は次のとおりです。

| 試験 | 表示項目 | 確認していること | 読み方 |
| --- | --- | --- | --- |
| 1 | IPv4インターネットアクセス（DNS利用無） | DNS名前解決に依存しないIPv4到達性 | NGならIPv4 route、NAT、IPIP、firewallを優先確認 |
| 2 | IPv4インターネットアクセス | DNSを含む通常のIPv4到達性 | 1がOKで2がNGならDNS周辺を疑う |
| 3 | IPv6インターネットアクセス（DNS利用無） | DNS名前解決に依存しないnative IPv6到達性 | NGならIPv6 default route、address、firewallを確認 |
| 4 | IPv6インターネットアクセス | DNSを含む通常のIPv6到達性 | 3がOKで4がNGならDNS周辺を疑う |
| 5・6 | フレッツ東日本 | 東日本側からだけ到達できる地域限定先への2回の試験 | 西日本回線では対象外表示が正常 |
| 7・8 | フレッツ西日本 | 西日本側からだけ到達できる地域限定先への2回の試験 | 東日本回線では対象外表示が正常 |
| 9 | 未実施 | 現在の旧ページでは試験しない予約項目 | `---`はfailureではない |
| 10 | v6プラスのインターネットアクセス（v6プラス用） | v6プラス専用test endpointへの到達性 | v6プラス利用確認で重要。通常のIPv4/IPv6成功とは別に見る |

東日本回線なら5・6、西日本回線なら7・8が意味を持ちます。反対地域の項目が`---`または対象外でも、回線障害を意味しません。同じ地域向け試験が2回ある正確な設計意図は公開画面に説明されていないため、推測で意味付けしません。いずれにしても、1回の画面だけで長時間安定性を保証するものではありません。

### 9.4 判定文、address、Portの読み方

画面上部の判定文は、個別試験をまとめたservice判定です。今回の実機では`結果：OK : v6プラスを利用しています(5999)`と表示され、同じ画面に「v6プラス 固定IP」と表示されました。`5999`は今回観測した表示codeとして記録し、公開protocol仕様として常に固定IPを意味するcodeとは断定しません。codeだけでなく、必ず判定文と各試験結果を一緒に読みます。

- `IPv4 アドレス`は、test serverから見えたbrowser通信のsource IPv4です。対象LANで契約固定IPv4と一致すれば、少なくともその通信が意図したIPv4出口とSNATを通った強い証拠になります。
- `IPv6 アドレス`は、browser端末のnative IPv6通信でtest serverから見えたsource addressです。IPIP tunnelのCPE側local endpointとは限らず、`LOCAL_V6`との一致を期待してはいけません。
- `Port`は、そのtest connectionで観測されたsource portです。IPIPはUDP/TCP portで張るtunnelではないため、表示portは「IPIP tunnel port」ではありません。公開serverのlisten port、port forwarding設定、MAP-Eの全割当port範囲を直接表す値でもありません。

IPv4が契約値と異なる場合は、別WAN、PPPoE、VPN/proxy、対象外LAN policy、SNAT未適用などを確認します。IPv4/IPv6の両方が表示されても、試験10がNGなら「dual stackで通信できる」ことと「v6プラス経路を使っている」ことを分けて診断します。

### 9.5 この判定で証明できること・できないこと

判定ページで確認できるのは、実行した端末・時刻における外向き通信です。

確認できること：

- browser端末からのIPv4/IPv6到達性
- test serverから見えるIPv4/IPv6 source address
- 東西どちらの地域限定到達性が成立するか
- v6プラス専用test endpointへの到達性と画面上のservice判定

このページだけでは確認できないこと：

- UDM Pro内部のtunnel mode、BR、IID、policy rule、netfilter ruleが正しいこと
- providerへのendpoint通知が成功し、次のprefix変更にも追従すること
- 対象外LAN、inbound通信、公開server、VPNが意図どおりであること
- reboot、UniFi OS update、drift、障害後に自動復旧すること
- `off`とrollbackで元状態へ戻せること

したがって、接続判定は[Validation](validation.md)の一項目です。preflight、診断、status、route/firewall確認、prefix変更、再起動、rollbackの代わりにはなりません。

### 9.6 privacyと共有

判定ページは、判定開始前から利用者の完全なpublic IPv6 addressを画面へ表示する場合があります。結果には完全IPv4、完全IPv6、source port、試験日時が含まれます。旧URLはHTTPなので、通信経路上で結果の秘匿性と完全性を保証できません。

- username、password、API key、configをページへ入力しません。この試験にcredentialは不要です。
- 旧HTTP URLは判定用途だけに使い、ISP/supportが許すならHTTPSの現行ページを優先します。
- 結果のcopyやscreenshotはprivateなsupport窓口だけへ送り、公開Issue、chat、SNSでは完全address、port、時刻を削除します。
- repositoryへ残す場合は、今回のように判定code、service名、各試験のOK/NG/対象外だけを記録します。

## 10. 一次資料

- [JPIX「v6プラス」対応製品開発ガイド 第1.3版](https://www.jpix.ad.jp/files/developer_guide_v6plus_v1.3.pdf)
- [JPIX「v6プラス」固定IPサービス対応製品開発ガイド 第1.2版](https://www.jpix.ad.jp/files/developer_guide_v6plus-static_v1.2.pdf)
- [JPIX「v6プラス」固定IPサービス](https://www.jpix.ad.jp/service/?p=3447)
- [JPIX「v6プラス」固定IPサービス 機器設定例](https://www.jpix.ad.jp/service/?p=3458)
- [Yamaha v6プラス対応機能](https://www.rtpro.yamaha.co.jp/RT/docs/v6plus/)
- [Yamaha IPv6マイグレーション技術の国内標準プロビジョニング方式対応機能](https://www.rtpro.yamaha.co.jp/RT/docs/hb46pp/)
- [JAIPA IPv6マイグレーション技術の国内標準プロビジョニング方式 第1.2版](https://github.com/v6pc/v6mig-prov/blob/master/spec.md)
- [JPNE/JPIX IPv4/IPv6接続判定ページ（旧URL）](http://wa.kiriwake.jpne.co.jp/)
- [IPv4/IPv6接続判定ページ（HTTPS）](https://kiriwake.jpne.co.jp/)

資料のサービス説明とメーカー設定例は、UDM Proまたはこのprojectへの公式対応を意味しません。公開資料は改訂されるため、導入時には契約ISPから渡された最新parameterとJPIX・メーカーの最新版を優先してください。
