# Validation

日付・release・動作modeごとに確認済みの範囲を記録します。これは過去の試験結果であり、現在の実機状態を保証しません。失敗または説明できない差分があれば次の段階へ進みません。

## 証拠の読み方

| 記録・表示 | 確認できること | それだけでは確認できないこと |
| --- | --- | --- |
| local unit/shell test | 合成fixture・mockでの期待動作 | 実機のkernel・ISP・UniFi API・通信 |
| manifest一致 | 配置fileとmanifestの整合性 | sourceの真正性、署名済み公開releaseであること |
| `status=healthy` | 現在のdesired stateとの一致 | freshな疎通、全DNS経路、実端末のアプリ |
| `verified` link | 当該releaseのbootstrap health成功 | すべての障害・機種での復旧、provider通知成功 |
| `model_status=verified` | UDM Proに割り当てた検証区分 | 現在のrelease・mode・個体での全gate合格 |
| 実機試験・利用者確認 | 記録したrelease・mode・条件での観測 | 他mode・新版への再起動結果の転用、将来の無停止保証 |

新しいsourceや文書のテスト件数は、過去の実機phaseの件数へ上書きしません。文書のlocal link/anchor、公開CLI・配布unit・config雛形の記載漏れはrepository testで検査しますが、文章の正確性は実装とも照合します。再現コマンドは[Contributing](../CONTRIBUTING.md#ローカル検証)、実機の受入手順は[UDM Pro runbook](udm-pro-setup.md)に記載しています。

## 実機検証範囲

### 2026-09-14: release配置と疎通確認（dev.23）

UDM Proへsource installerでdev.23を配置しました。この試験時点のcurrent/verifiedはdev.23、previousはdev.22で、modeはunifi-managedです。署名済み公開releaseではありません。

ローカルとUDMでPython 80テストとv2 shell suiteが成功しました。IPv4/IPv6 HTTPS 204、DNSのport 53/20201/1053それぞれでA/AAAA・UDP/TCPのNOERRORを確認しました。project config、credential、UDAPI設定、対象外firewall、残存診断ファイルの内容一致を確認しました。最終statusはhealthy・pending repairs 0、起動用4 unitはenabled/activeです。

復旧先manifestとmanaged capabilityを検証し、試行用v2復旧timerを解除しました。実rollback、再起動、設定保存、Windows実端末の再試験はこのphaseでは実施していません。

### 2026-09-14: 設定再適用時の修復待機短縮（dev.22）

`dev.21`では、利用者の設定保存と同じ時刻にUniFiの設定再適用、kernel tunnelの送信元未設定、WAN監視down、9件の自動補正、WAN監視upを確認しました。設定再適用開始から補正完了まで約24秒でした。修正済みのWAN DNSは保持されており、DNS設定不足の再発とは区別します。この時間はPCで測定した通信停止時間ではありません。

`dev.22`ではnetlink debounceを5秒から1秒、UDAPI path起動前待機を10秒から1秒へ短縮しました。managed modeはAPI応答後、10秒待ってからkernel endpointを直すのではなく、まず再planして補正します。その後も同じlockとtransaction内で1秒間隔の待機を挟み10回再確認し、遅れて消えるproject firewallなどに追従します。実際の間隔にはplan/command実行時間が加わります。新たなAPI callbackが必要な競合は上書きを繰り返さず停止します。変更なしのreconcileには追加待機を入れません。

| 検証 | 結果・制約 |
| --- | --- |
| Pythonテスト | ローカル・UDMで79件成功。修正前に失敗する3ケースを確認後に実装。即時endpoint補正、遅延firewall再生成、runtime-only drift、rollback、同時設定変更の拒否を含む |
| 配置 | source installerでcurrent/verifiedをdev.22へ更新。起動前の3監視unitを停止し、配置後に起動。署名済み公開releaseではない |
| 配置時の非対象設定 | UDAPI設定全体、project config、非project IPv4/IPv6 firewallの正規化digestが前後一致 |
| 通信 | 配置後reconcileは修復0件。IPv4/IPv6 HTTPS 204、WAN専用DNSとContent Filter経由DNSでYouTube・MicrosoftがNOERROR |
| 実際の設定保存 | 利用者の保存1回を観測。設定再適用開始から約7秒後にIPv4 probe復帰。WANはunknownからupへ復帰し、down判定・failover group downは観測なし |
| 瞬断と追従確認 | 55回の逐次probe中、IPv4失敗3回・フィルターDNS失敗1回。9件補正後の次回reconcileは修復0件。無停止・長時間の再発防止を確認したわけではない |
| Windows実端末 | dev.22配置と設定保存テスト後、YouTube再生・ゲーム接続の両方が使えると利用者が確認 |

保存時の時系列は、01時02分03秒に設定再適用開始、01時02分05秒にUniFi側apply完了、01時02分10秒にIPv4 probe復帰、01時02分13秒にWAN up、01時02分24秒に追従・health確認完了、01時02分27秒に追加修復0件でした。最後のhealth完了時刻とデータプレーンの復帰時刻は異なります。kernel endpointエラーは01時02分03秒から01時02分10秒に記録されました。probeはUDM上の逐次測定であり、Windows PCの停止時間を厳密測定したものではありません。

WAN監視の閾値・bind設定、Content Filter、契約endpoint、provider通知条件は変更していません。UDM再起動、Network restart、物理WAN/prefix変更、長時間観測は今回実施していません。

### 2026-09-14: Content Filter併用時のWAN DNS修正（dev.21、UniFi設定変更）

追加されたContent FilterはAd Block・Basic・Google/Bing/YouTube Safe Searchが有効でした。利用者から実端末の症状は報告されていませんでしたが、診断でフィルター経由のDNSが`REFUSED`となる状態を確認しました。WAN専用dnsmasqが参照するresolverファイルは存在せず、上流server設定もありませんでした。通常DNSとIPv4/IPv6 HTTPSは成功していたため、従来のhealthyだけでは検出できない経路です。

UniFi管理画面でWAN1のIPv4 `Auto DNS Server`を解除し、通常DNSで既に使用中・到達確認済みのresolverをPrimary Serverへ指定しました。ページ再読込後も保存値が維持され、WAN専用resolverファイルの生成を確認しました。プログラムreleaseは`dev.21`のままです。

| 検証 | 結果 |
| --- | --- |
| WAN専用DNS | MicrosoftのA・GoogleのAAAA問い合わせがNOERROR |
| フィルター経由DNS | YouTube・Google・Xbox・MicrosoftがNOERROR。YouTubeはIPv4/IPv6 transportのUDP/TCPで確認 |
| 保護機能の維持 | YouTube・GoogleのSafe Search CNAMEを確認。広告ドメインはlocal block応答。filter rule、redirector、対象LAN設定のdigestが変更前と一致 |
| 通常通信と監視 | IPv4/IPv6 HTTPS 204、WAN good、7 monitorのavailability 100%、healthy・pending repairs 0 |
| 保存時の収束 | 一時的なdriftを観測後、自動修復によりhealthyへ復帰。停止時間の厳密測定や無停止保証ではない |

この修正前、Content Filter保存に近い時刻のログでは、00時19分42秒にUniFi設定再適用とkernel endpoint未設定、00時20分03秒にWAN down、00時20分05秒に9件の自動補正完了、00時20分08秒にWAN upを確認しました。利用者提示の00時20分10秒の通知と時刻が対応しますが、PCの通信停止時間そのものを測定したわけではありません。DNS修正はこの設定再適用時の短い切断を完全に解消する変更ではありません。

今回の確認はUDM上の合成DNS問い合わせと実通信probeです。Windows PC自身のDNSパケット観測、全カテゴリ・全広告ドメイン・全動画・ゲーム通信の再試験、再起動後の永続性試験はしていません。

### 2026-09-14: UniFi管理WAN統合（dev.20 / dev.21）

standalone所有権方針の見直しを明示承認したうえで、`dev.20`で`integration.mode=unifi-managed`へ移行し、`dev.21`で旧adapterへのrollback拒否を追加しました。この検証時点の`current`と`verified`は`v2.0.0-dev.21`でした。source installerによる開発版で、署名済み公開releaseではありません。

| 項目 | 結果 | 範囲・制約 |
| --- | --- | --- |
| 初回移行と復旧 | 失敗・standalone復旧を確認 | `dev.19`のstatic AddressSelector指定はUDAPIが未実装エラーで拒否。即時復旧処理により旧configと`jpix0`へ復帰。10分timerの実発火試験ではない |
| 修正版の明示移行 | 成功・確定済み | `dev.20`で対応済みinterface selectorとkernel endpoint補正を併用。10分timerを予約し、管理画面・疎通確認後にconfirm、timer解除を確認 |
| 管理画面の速度測定 | 成功 | 実際の「ISP Speed Test」ボタンから実行。source interfaceはUniFiの論理WAN、vendor結果はSuccess、画面に下り4.46 Gbps・上り2.49 Gbps。単発測定で性能保証ではない |
| ISP・IPv4表示 | 復帰 | 管理画面でISP名が表示され、placeholderから契約固定IPv4へ一致。表示結果や速度結果の手動書換えはしていない |
| 通常通信と監視 | 成功 | native WANにbindしたYouTube IPv4 HTTPS 204、Google IPv6 HTTPS 204、IPv4 ping 3/3、UDP/TCP DNS NOERROR、WAN good、7 monitorのavailability 100% |
| Windows実端末 | ユーザー確認済み | 統合後のYouTube再生・ゲーム接続の両方が使えると回答。対象外LAN実端末の検証ではない |
| 旧standalone資産 | 稼働中参照なし | `jpix0` interface、IPv4/IPv6全tableのroute/rule、firewall参照が0。project ruleはIPv4 6本・IPv6 1本、duplicate 0。UniFi native tunnelは削除せず正常WANとして使用 |
| 安定性・永続配置 | 正常・限定範囲 | confirmのreconcileは修復0件、bootstrap・timer・event monitor・UDAPI path active。`dev.21`配置後の3回のreconcileも修復0件、IPv4/IPv6 HTTPS 204、doctorのboot persistence ready。新方式での実再起動はしていない |
| rollback互換性 | unit test成功 | module存在だけでは旧static-selector実装を拒否できないため、`dev.21`でcapability marker検証を追加。非対応版はcurrent切替前に拒否 |

Pythonテスト73件はローカル・UDMの両方で成功しました。テストにはUDAPI対象外field保持・直前競合・HTTP error応答・kernel補正と逆操作・未知mode拒否・確定後timerのno-opを含みます。端から端までの全障害migration fixtureではありません。今回のlive移行はUniFi自身のnative route/firewall再生成を伴うため、非project資産の完全な前後不変性を実証したとはしません。

ローカルでは`python3 -m unittest discover -s tests_v2`（`PYTHONPATH=src`）、`tests/repository_contract_test.sh`、`tests/install_v2_test.sh`、`tests/event_monitor_v2_test.sh`、変更shell/launcherのShellCheck、`git diff --check`が成功しました。

未実施: 新方式でのUDM再起動、Network restart/reprovision、WAN切替・断復帰、prefix変更、10分timer実発火後の復旧、長時間soak、対象外LAN・PMTUD・大きなUDP・VPN。確定後の方式解除CLIも未実装です。過去のstandalone再起動実績をこの方式の合格証跡に転用しません。

### 2026-09-13: WAN policy適用と管理画面の切り分け（dev.18）

この時点の`current`と`verified`は`v2.0.0-dev.18`でした。review済みsource installerによる配置であり、署名済み公開releaseではありません。

| 項目 | 結果 | 範囲・制約 |
| --- | --- | --- |
| WAN policy接続 | 実機適用成功 | `dev.16`でproject IPv4 dispatchを3本追加。既存WAN IN/OUT/LOCALへ接続し、実トラフィックcounter増加を確認。`dev.18`で内部DNS分岐の先頭RETURNも追加し、4本は各1本。未知chain・foreign ruleはunit testで拒否 |
| 対象外資産 | 前後一致 | 管理トンネル、IPv4 route/rule、IPv4/IPv6の非project firewall rule、UDAPI設定のdigestが一致 |
| 通常通信 | 成功 | UDMのIPv4/IPv6 ping各3回、loss 0%。最終版でIPv4/IPv6のYouTube HTTPS 204、UDP/TCP DNS成功、WAN good、7 monitorのavailability 100%。今回の変更後のWindows実端末再試験は未実施 |
| 速度測定 | 明示bindのみ成功 | UniFi同梱測定機能を`jpix0`へbindし、下り4579 Mbps・上り2393 Mbps。単発測定であり性能保証ではない |
| 管理画面からの測定・ISP表示 | 当時は未解決 | 実際の測定ボタンで管理トンネルへの再指定とErrorを確認。ISPは未表示。後続の明示統合方式で解決 |
| CLI・自己修復 | 正常 | `dev.17`でsymlink起動を修正。通常のstatusはhealthy・pending 0、後続reconcileはrepair 0。今回の追加rule消失注入・実再起動は未実施 |

Pythonテスト58件はローカルとUDMで成功。新launcherのShellCheck、`git diff --check`も成功しました。この試験に合わせてvendor scriptやcontroller DBを書き換えてはいません。後続の統合は別途の明示承認を経て実施しています。

### 2026-09-13: router recovery（dev.15）

UDM Pro・UniFi OS 5系・Network 10.6系で`router_recovery.enabled=true`を有効化し、`current`と`verified`を`v2.0.0-dev.15`へ更新しました。source installer経由の開発版であり、署名済み公開releaseではありません。

| 検証 | 結果 | 範囲・制約 |
| --- | --- | --- |
| UDM本体の通常通信 | 成功 | 非bind IPv4 ping、native IPv6 ping、DNS解決を伴うYouTube HTTP 204・Microsoft HTTP 200 |
| 回線監視 | 正常 | WAN health good、7 monitorすべてavailability 100% |
| local-origin rule欠落 | 自動復元 | dev.14で約6秒。補助経路を一時配置し、PC通信への影響を抑えて試験 |
| monitor bindとuser-hook再生成 | 自動復元 | dev.15で36.2秒、12秒の安定確認を含む。monitorのbind flag 1個だけを変更。対象外services設定とforeign firewall ruleは試験前後で一致 |
| boot処理 | 再実行成功 | manifest検証・unit再配置・health確認を実行。実際のUDM再起動ではない |
| UDM実再起動 | 自動復旧成功 | 同日の後続試験でBoot ID変更をprivateに確認。手動reconcile/applyなしで19件の状態補正を実行し、その後3回は修復0件。今回bootのCLI失敗記録なし |
| 再起動後の永続資産 | 正常 | current/verifiedはdev.15、manifest一致、起動用4 unit active、provider pendingなし。local-origin ruleは各1本、IPv4/IPv6 project firewall ruleは6本/1本 |
| 再起動後の端末通信 | ユーザー確認済み | Windows PCでYouTube再生とゲーム接続に成功。PC向け転送経路と管理LAN経路も確認。対象外LAN実端末の試験ではない |

dev.14の最初のmonitor試験ではflagは復元したものの、UDAPI応答後のuser-hook再生成でSNAT/outer ruleが欠落しました。dev.15では監視更新後の10秒待機・再planと、path経由の遅延reconcileを追加しました。最初の試験結果だけをfirewall復元成功とは扱いません。

Pythonテスト50件はローカルとUDM上の両方で成功。v2 installer/release/bootstrap・event monitorテスト、変更shellのShellCheck、diff checkも成功しました。この時点の結果は当該componentの検証であり、現在の全テストの合格を示すものではありません。

再起動後はUDM自身の非bind IPv4/native IPv6 ping、DNSを伴うYouTube HTTP 204・Microsoft HTTP 200、WAN health good、7 monitorのavailability 100%を再確認しました。Windows PCでのアプリ復帰も確認できたため、当時のdev.15・standalone構成の通常再起動試験を合格とします。厳密なインターネット停止時間は測定していません。WAN物理切替、Network全体のrestart/reprovision、対象外LAN、長時間soak、VPN共存は未実施です。`deactivate()`の既存複数LAN修正は今回配置しましたが、実機deactivateは未実施です。

## 未検証の実機gate

1. managed modeでの再起動、Network全体のrestart/reprovision、WAN物理切替・断復帰。
2. DHCPv6-PD prefix変更後のendpoint・firewall・provider通知の追従。
3. 対象外LAN実端末、PMTUD・ICMPv6 Packet Too Big・大きなUDP・VPNとの共存。
4. managed統合の10分復旧timer実発火、release rollback、署名済み公開release upgrade。
5. UDM SE・UDM Pro Max、長時間soakと繰り返し障害。

設定保存1回の成功をNetwork全体のrestartや全障害の検証へ拡張しません。各phaseでは通信、drift収束、duplicate、対象外資産の保持を別々に記録します。未確認のgateは自動的に合格扱いにしません。

## 結果の共有

CLI出力を確認し、必要な状態・reason codeだけを共有してください。接続判定ページのcopyやscreenshotは共有安全ではありません。完全address、prefix、interface名、port、MAC、serial、device ID、時刻、config、state、raw journalは共有前に一般化または削除してください。
