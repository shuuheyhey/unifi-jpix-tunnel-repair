# 運用ガイド

本ツールは既定の`standalone`と明示移行の`unifi-managed`を分離します。前者はUniFi管理トンネルを変更せず、project-owned tunnelである`jpix0`をdesired stateへ収束させます。後者はUniFi管理WANの限定fieldとkernel endpointを補正し、管理画面の速度測定・監視と実通信を同じ論理WANへ統合します。どちらも物理WAN名を入力させず、BR宛てのIPv6 route、link状態、LAN bridgeのdelegated prefixを実行ごとに検出します。

## 対応境界

- JPIX「v6プラス」固定IPサービスの固定IPv4 1個だけを対象にします。
- UDM Proはverified、UDM SEとUDM Pro Maxは実機gate完了までpreviewです。
- UniFi OSとNetworkのversion文字列は診断情報です。必要なroute、tunnel、policy rule、legacy user hookを一意に確認できる場合だけ変更します。
- 他のroute table、他のpolicy rule、tagのないfirewall ruleは読み取り専用です。管理トンネルもstandaloneでは読み取り専用ですが、明示移行した統合方式では下記の限定補正対象です。
- 明示opt-inの`router_recovery`を有効にした場合だけ、単一WAN adapterがUDAPIの監視bind flagを補正します。standaloneではfalse、統合方式ではtrueへ収束させます。
- capabilityが不足する場合と所有権が曖昧な場合は隔離し、推測でfallbackしません。

## 検証状況

UDM Proで通信・限定drift・standalone再起動・管理WAN統合を確認しています。各試験のreleaseとmode、確認済みの範囲は[Validation](validation.md)を参照してください。managed modeでの再起動、WAN物理切替・断復帰、Network全体のrestart、prefix更新、対象外LANの実端末通信は未検証です。

`model_status=verified` やreleaseの `verified` は、全障害からの復旧・将来互換・stable公開を保証しません。設定保存時には短い通信断が観測されています。

## 初期導入

[Installation](installation.md)を手順の正本とし、`discover → config編集 → check → plan → 明示activate → 実端末確認`の順に進めます。[Configuration](configuration.md)に全fieldの既定値と制約、[Architecture](architecture.md)に永続レイアウトと起動unitを記載しています。稼働中の更新は初期導入のコマンドを再実行するだけでは完結しません。

## 公開CLI

以下はrootで実行するCLIです。read-onlyの検査コマンドはnetwork設定を変更しません。一般的な`apply`、`off`、`uninstall`、単独の`activate`サブコマンドはありません。

| コマンド | 追加引数 | 内容・変更範囲 |
| --- | --- | --- |
| `unifi-jpix discover` | なし | read-only。configなしは候補と雛形、ありは選択構成のcapabilityを表示 |
| `unifi-jpix check` | なし | read-only。config・capability・plan生成の可否を検査。未適用のactionがあってもreadyになり得る |
| `unifi-jpix plan` | なし | read-only。割当資源と変更理由を表示。networkへ適用しない |
| `unifi-jpix reconcile` | `--retry`（任意） | network・runtimeをdesired stateへ収束しhealth確認。必要ならprovider/webhookへ通信 |
| `unifi-jpix status` | `--json`（任意） | read-only。現在のdrift・隔離状態と直近health。新しい疎通probeではない |
| `unifi-jpix doctor` | なし | read-only。statusに加えunit配置・enablement・link・provider pending等を確認 |
| `unifi-jpix rollback` | なし | 互換性確認後にreleaseを選択しbootstrapを実行。[復旧の限界](rollback.md)を先に確認 |
| `unifi-jpix upgrade` | `--release VERSION`（必須） | 署名付きreleaseを取得・検証・切替しbootstrapを実行 |
| `unifi-jpix integrate-wan` | `--activate`、`--confirm`、`--recover`のいずれか1つ | 健全なstandaloneから管理WANへ明示移行、試行確定、未確定試行の復旧 |

共通optionはサブコマンドの**前**に指定します。例: `unifi-jpix --config /path/to/private-candidate.json plan`。

- `--root PATH`: state・release等のroot。既定は`/data/unifi-jpix-tunnel-repair`。配布unitの絶対パスを変更するoptionではありません。
- `--config PATH`: `discover/check/plan/reconcile/status/doctor`の入力configを変更します。`upgrade/rollback/integrate-wan`はroot直下の`config-v2.json`を使うため、別configの試験に流用しません。
- `--version`: package内のversion文字列。開発版では`2.0.0-dev`のままなので、配置した`dev.N`の確認には`current/verified`のlinkとmanifestを使用します。

正常終了は原則`0`、処理エラーは`1`、引数エラーは`2`です。`status`はhealthy以外で`1`を返します。`doctor`は診断結果に問題があっても表示できれば`0`なので、終了codeだけで判定しません。

configなしの`discover`には実interface名とfirmwareが含まれます。ほかの結果も時刻・versionなどを確認し、公開時は必要な状態とreason codeだけを抜粋してください。config/state/raw journalは共有用出力ではありません。

## Healthの読み方

`status=healthy`は現在のplanに変更予定がないことを示します。新しいpingを実行せず、過去の失敗記録が`last_health`に残る場合もあります。`check=ready`も到達性の証明ではありません。

reconcileのhealthは専用tableのdefault route、tunnelにbindしたIPv4 ping、WANにbindしたIPv6 pingを確認します。router recovery有効時はUDM自身の通常/mark付きroute、ping、monitor flagも確認します。managed modeでは限定WAN fieldとkernel endpointに加え、論理WANにbindしたYouTubeのHTTPS 204応答を確認します。

いずれも実端末の動画・ゲーム、Content Filter専用DNS、全resolver、全LAN、MTU/UDPの完全な試験ではありません。`doctor`の`boot_persistence=ready`も4 unitの存在・enablementとcurrent symlinkの存在を示すだけで、unitのactive状態やmanifestの再検証結果ではありません。[受入チェック](udm-pro-setup.md#有効化後の受入チェック)を別に行います。

provider pendingはdata planeのhealthとは別です。`doctor`で`provider_notification=pending`なら通知経路を確認します。reconcileの`provider_update=not-configured`は通知不要で処理をskipした場合にも返るため、その値だけでprovider設定の有無を判定しません。

## 自己修復

netlink monitorはlink、address、route、ruleの変更を受けて1秒の集約窓の後にoneshot reconcileを起動します。firewall driftや失われたeventは5分timerが回収します。reconcile同士は同じnon-blocking flockで排他しますが、installerやrelease切替はこの保証に含めません。

欠落・driftした管理対象資産とWAN/prefix変更を修復します。前提未成立とforeign conflictはnetworkを変更せず隔離します。serviceの`--retry`は初回に加え5秒、15秒、60秒の待機を挟む最大3回の再試行です。service timeoutで打ち切られる場合もあり、その後もeventやtimerによる再実行は続きます。手動の`reconcile`は`--retry`なしなら1回だけです。

mutation中はshare-safeなtransaction journalを更新し、health失敗時は記録した逆操作を逆順に実行します。provider通知はendpoint変更時またはpending時だけ実行し、transport失敗ではdata planeをrollbackしません。webhook payloadにはproject、major version、model family、状態、reason codeだけを含めます。

所有するpolicy priorityは対象LAN数に1を加えた連続範囲です。LAN通信はsource CIDRとingress interfaceで限定し、追加の1本は固定IPv4送信元の通信を専用tableへ送ります。これはルーター自身のIPv4 health checkにも必要です。provider更新はIPv6 endpointにbindした別通信です。

iptables/ip6tablesの照会・変更は`-w 5`でlockを待ちます。save系は実機が`-w`非対応のため、通常呼び出しを1秒・2秒・5秒の待機を挟んで再試行します。health checkはトンネルを維持したまま、失敗後2秒・5秒でpingを再試行します。eventの30秒以内・timerの5分以内は目標であり、lock、再試行、provider通信、timer精度による遅延を含めた上限保証ではありません。

timerは`OnUnitInactiveSec=5min`、`AccuracySec=10s`で、reconcile終了からの相対周期です。厳密な5分以内の復旧保証ではありません。schema version 2では`repair.interval_seconds`は300だけを受け付けます。

### UDM本体のIPv4と回線監視の補正（単一WAN opt-in）

以下は`router_recovery.enabled=true`のstandalone adapterです。`UBIOS_DNS_PBR_JUMP`の先頭へproject tunnel（既定`jpix0`）限定のRETURNを置きます。INPUTから先に呼ばれる内部DNS用ACCEPT/DROPへ進まず、続くWAN LOCAL policyで判定するためです。他interfaceのDNS分岐は維持します。先頭位置、rollback時の再挿入位置、旧releaseへのdowngrade制約も検証対象に含みます。

このadapterはIPv4の`UBIOS_FORWARD_IN_USER`、`UBIOS_FORWARD_OUT_USER`、`UBIOS_INPUT_USER_HOOK`に`jpix0`限定のdispatchを維持し、それぞれ既存の`UBIOS_WAN_IN_USER`、`UBIOS_WAN_OUT_USER`、`UBIOS_WAN_LOCAL_USER`へ渡します。WAN policy本体や他interfaceのruleは変更しません。既知のchain到達順・interface dispatch形式・単一の管理WAN参照を確認し、未知のjumpや先行ACCEPT/RETURN、foreignな`jpix0` ruleは隔離します。deactivate時はトンネル削除成功後にdispatchを削除します。新CLIは有効なdispatchを管理できない旧releaseへのrollbackを拒否します。

`jpix0`にbindしたpingが成功していても、UDM自身の通常通信・DNS・回線監視がUniFi管理トンネルを使い続ける場合があります。この場合は単一WANのcapabilityと変更範囲を確認し、設定JSONの`"router_recovery": {"enabled": true}`で明示opt-inします。既定は無効です。稼働中configは監視から即時反映され得るため、[設定変更時の注意](configuration.md#設定変更時の注意)に従います。

1. 単一WAN・単一failover group・`algorithm=single`・既知のmonitor flag型を確認します。WAN名とmarkは現在のUDAPIとpolicy ruleから検出し、物理port名は入力しません。
2. `32000: from all lookup main`とmainのdefault route不在を確認し、その後の`32001`に`iif lo`限定の専用table参照を維持します。通常のLAN内通信はmainを優先します。異なるlayout・priority競合・複数WANでは変更しません。
3. 既存LAN priorityの直前1本を予約し、UDM自身のWAN-mark付き通信を専用tableへ送ります。古い送信元を保持するDNS socket用SNATはlocal-origin・当該mark・UDP/53・project tunnel限定です。このmark補正は意図的にmainより先に評価されます。
4. 全monitorの`bindAddress`、`bindDomainResolution`、`bindInterface`、`bindRoutingTable`だけをfalseへ補正します。監視先・間隔・health thresholdは保持し、実際の疎通で回線状態を判定します。UDAPIの全services JSONは標準入力のみで渡し、argvやjournalへ出しません。変更直前に設定の一致を再確認しますが、UDAPIにCASはなく同時provisionとの完全な原子性は保証しません。
5. boot、netlink、5分timerに加え、`unifi-jpix-udapi.path`でUDAPI設定の再生成を検出します。pathは1秒遅延のoneshotを起動し、同じreconcile/flockを通します。UDAPIが応答後にuser hookを再生成するため、standalone modeのmonitor補正はtransaction内で10秒待機後に再planし、project rule/SNATを再補正してからhealthを記録します。managed modeでは補正を待たせず、直後の再planと1秒待機を挟む10回の追従確認を行います。各plan/commandの実行時間は別途必要です。通常/mark付きIPv4経路・ping・live monitor設定も検証します。追従期間を超える変更や失われたeventは5分timerでも回収します。

`state-v2/router-recovery.json`はmode `0600`で、予約情報と導入時のmonitor bind flagだけを保存します。services全体やcredentialは保存しません。既存の緊急復旧ruleは専用table・優先度・selectorが完全一致した場合だけ取り込みます。markや論理WANの識別が変わった場合は隔離します。

有効化後、設定だけfalseへ変更しても資産は削除しません。内部の`deactivate()`は元のmonitor flagとproject rule/SNATを処理しますが、CLIの`rollback`はdeactivateではありません。旧版へのdowngradeには、通信経路の復旧手段を準備したうえでadapter資産と設定を整合させる別作業が必要です。新CLIは`router_recovery`非対応releaseへのrollbackを切替前に拒否します。

このadapterはUDAPI既知layout向けのpreviewです。UDM Proのstandalone構成で実再起動を1回検証済みですが、Network全体のrestart/reprovision、複数WAN、VPN経路との共存は別のgateが必要で、無条件の将来互換を保証しません。

## UniFi管理WANへの統合（preview）

この方式ではUniFi管理トンネルのenrollment済みfieldを限定補正します。`integration.mode`の既定は`standalone`で、既存利用者を自動移行しません。まず健全なstandaloneと`router_recovery.enabled=true`を用意し、以下のCLIで明示移行します。JSONのmodeだけを先に書き換えないでください。

| 所有範囲 | 統合方式での扱い |
| --- | --- |
| 論理WANのidentity・native route/rule・WAN policy | UniFiが所有。名称は現在の単一WAN設定から検出し、作成・削除しない |
| enrolled tunnelのIPv4、WAN selector、BR、MTU、MSS | UDAPIの永続設定から更新案を作り、他のinterface/fieldを保持。直前比較後にstdinでPUTし、応答と永続結果を確認 |
| kernel tunnelのmode・local/remote endpoint | UDAPI反映後に契約値へ補正。static AddressSelectorは実機で未実装だったため使用しない |
| project table・policy rule・tag付きSNAT/MSS/outer allow | projectが所有。論理WANへ向け、不要なstandalone用WAN dispatchは撤去 |
| monitor bind flag | すべてtrueへ復帰。監視先、間隔、thresholdなどは維持 |

単一WAN、既知の`ip6tnl`形式、設定と一致するBR、単一静的IPv4、fallback mappingなし、既知のroute/monitor layoutに限定します。未知形式、別BR、enrollment identity変更、想定外IPv4では変更せず停止します。`/interfaces`は配列全体をPUTするAPIですが、enrolled field以外をcopy-preserveし、同時変更を検出したら拒否します。APIにCASがないためprovisionとの完全な原子性は保証できません。

IPv6 outer allowは契約BR・local endpoint・Protocol 4に限定し、UniFi WAN LOCAL判定より前に配置します。IPv4はUniFi native WAN policyをそのまま通します。vendor script、binary、controller DBは変更しません。

1. 別管理経路を確保し、`unifi-jpix status --json`でhealthy・pending repairs 0を確認します。
2. `unifi-jpix integrate-wan --activate`を実行します。固有名の10分復旧timerを先に予約し、通常automationを停止、private移行記録を保存してから、project資産を撤去・native WANを補正します。
3. UDMと実端末のIPv4/IPv6/DNS、管理画面の速度測定・ISP表示を確認します。失敗例外では即時、未確定ならtimerでstandaloneへの復旧を試みます。所有権不明や同時変更で復旧自体が停止する場合もあるため、別管理経路は維持します。
4. 合格した場合のみ`unifi-jpix integrate-wan --confirm`を実行します。新しいhealth確認とlock内の確定marker更新後に復旧timerを停止します。
5. 未確定の試行を中止する場合は`unifi-jpix integrate-wan --recover`を実行します。確定済み記録には何もしないため、遅れたtimerが正常WANを戻すことはありません。

`state-v2/managed-wan.json`と`managed-migration.json`はmode `0600`です。移行記録には元の設定・runtime・限定WAN field・monitor flag・project firewallが含まれるため、公開ログへ貼らないでください。復旧は記録済みまたは移行後の既知project ruleだけを除去し、他のWAN field変更や未知tagを見つけた場合は停止します。統合確定後にstandaloneへ戻す一般向けCLIは未実装です。通常の`rollback`はrelease切替であり方式の解除ではありません。

release rollbackは、統合adapterファイルの存在だけでなく対応capability markerも検証します。非対応releaseへの切替を拒否し、停止を伴うdowngradeを勝手に実行しません。新方式の再起動、Network全体のrestart/reprovision、WAN/prefix変更、10分timer実発火後の復旧は未検証です。初回API拒否後の即時復旧と通常reconcileの安定動作を、これらのgate合格へ拡張しません。

### Content Filterを併用する場合のWAN DNS

統合方式では、通常のDNSだけでなくUniFiの論理WAN専用DNSも確認してください。実機ではContent Filterの問い合わせがWAN専用dnsmasq（port `20201`）へ転送されましたが、WANのIPv4設定が`Auto DNS Server`のままで上流設定が生成されず、`REFUSED`を返していました。通常のport `53`とreconcilerがhealthyでも、この経路の正常性は保証されません。

UniFi管理画面のInternet → 対象WAN → IPv4 Configurationで、DNSの自動取得が成立しない場合は`Auto DNS Server`を解除し、利用者が選択した到達可能なDNSをPrimary Serverへ指定します。IPv6のAAAAレコードも解決できることを確認してください。実機修正では既に通常DNSで使っているresolverを再利用し、Content Filterの対象・Ad Block・Basic・Safe Searchは変更していません。生成済みの`/run`ファイルだけを書き換えず、UniFi設定として保存します。

適用後はフィルター経由のIPv4/IPv6・UDP/TCP DNS、Safe SearchのCNAME、広告ブロック応答、通常HTTPS、WAN監視を別々に確認します。2026-09-14の実機ではこの検証が成功しました。設定保存によるWAN再構成時には一時的な通信不成立と自動修復を観測しており、DNS修正によって無停止の設定変更が保証されるわけではありません。

## 現実装の制約と次の検証

- transaction journalには変更理由と進捗だけを永続化し、逆操作は実行中のメモリに保持します。通常例外とSIGTERM/SIGINTでは逆操作を実行しますが、電源断やSIGKILL後のjournal replay、完全なverified runtime snapshot復元は未実装です。
- release rollbackは`previous`を優先します。source installerで選択しただけの未検証releaseも`previous`になり得るため、常に既知の健全版へ戻る保証はありません。
- 汎用uninstall、確定済みmanaged modeの解除CLIはありません。内部の`deactivate()`は公開操作として提供していません。
- 起動時unit復元とmanifest検証を実装し、UDM Pro・`dev.15`で通常の実再起動後の自動復旧を確認しました。bootstrap unitやenablement自体がOS更新で消えた場合は自動復元できません。unit配置は現状ファイルごとの`install`であり、unit一式の原子的切替ではありません。
- UDM Proでの限定drift試験と1回の再起動成功を、WAN/prefix変更、firewall全消失、対象外資産不変、障害全般からの自己修復の証明へ拡張しません。Network全体のrestart/reprovisionとWAN物理断復帰は別の実機gateです。

隔離は自動処理の永続停止ではなく、次回reconcileで再検査されます。逆操作失敗後の停止方法、release選択と自動切戻しの限界は[Rollback](rollback.md)、異常時の確認順は[Troubleshooting](troubleshooting.md)を参照してください。
