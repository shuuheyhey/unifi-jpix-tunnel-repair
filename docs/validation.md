# Validation

v2の確認済み範囲を先に記載し、v1の過去実績と検証手順を後半に保存します。失敗または説明できない差分があれば次の段階へ進みません。

## v2の実機検証範囲

2026-09-07のこの作業で取得した証跡です。リアルタイムの稼働状況ではありません。UDM Pro、UniFi OS 5系、Network 10.6系、開発版`v2.0.0-dev.13`を対象としました。完全なversion文字列や導入固有のaddressは公開資料に含めません。

| 検証項目 | 状態 | 確認した範囲 |
| --- | --- | --- |
| 非アクティブ配置 | 完了 | discover/check/plan、専用tunnel未作成、bootstrap無効を確認 |
| v1からv2移行 | 完了 | 最終試行は17件の変更を適用、CLIがmigrated/healthyを返した |
| 通信とprovider通知 | 完了・限定範囲 | UDM自身のtunnel-bound IPv4とWAN-bound IPv6 ping、provider更新成功を確認。LAN端末・DNS検証の代用ではない |
| 永続化の起動処理 | 完了・再起動未実施 | current/verifiedが同じrelease、bootstrap・timer・event monitorがactive。v1停止と確認marker、復旧timer解除を確認 |
| netlink自動修復 | 完了・単一ケース | 専用tableの接続routeを1本削除し、30秒の観測枠内で復元。観測処理全体6.7秒、status healthy、transaction verified |
| 移行失敗時のv1復帰 | 複数試行で確認 | health失敗やbootstrap中止後のv1再apply・疎通復帰を確認。完全な資産cleanup保証ではない |
| 24時間shadow/長時間soak | 未実施 | ユーザー指定により24時間待機を省略 |
| v2でのUDM再起動 | 未実施 | 次の実機gate。v1再起動実績を転用しない |
| WAN切替・断復帰、Network restart/reprovision、prefix更新 | 未実施 | 各phaseを個別に確認する必要がある |
| LAN端末、DNS、対象外LAN、PMTUD・UDP・VPN、firewall全消失 | 未実施 | UDM自身のpingとroute復元だけでは合格にしない |
| UDM SE・Pro Max | 未実施 | previewを維持 |

今回追加した互換修正は、xtables lock待機、save系再試行、固定IPv4 source rule、ping再試行、host rule表示正規化、systemd起動依存循環の解消です。これらは[v2ガイド](v2.md#自己修復)に反映しています。

ローカル検証ではPython v2テスト31件、repository contract、event monitor、installer/release/bootstrapテスト、py_compile、diff checkが成功しました。legacy全体テストはmacOSの`stat -c`非対応で一部失敗し、全suite成功とはしていません。署名検証はローカルテストであり、実機への署名済み公開release upgradeは未検証です。

次の再起動gateでは、再起動前後のBoot ID変更をprivateに確認し、current/verified、3 unit、statusとlast_health、IPv4・IPv6、provider pending、対象LAN/対象外LAN、duplicateと残存routeを確認します。今回のroute欠落試験では対象外資産の前後完全比較は行っていないため、不変性を実証済みとはしません。

後続のローカル修正では`deactivate()`の接続route削除を対象LANごとのloopへ戻しました。複数LANの削除、別table/対象外LANのroute保持、削除失敗時のownership state保持を含むPython v2テスト33件が成功しています。この修正は実機未配置で、実機cleanupと再起動検証は未完了です。

## 現在の実機検証範囲

以下はv1の2026-08-26時点のUDM Pro・UniFi OS 5系実機結果です。以下の「現在」「新automation」「現方式」は当時のv1を指します。v2へ移行した実機でv1が現在稼働している意味ではありません。完全address、prefix、interface名、config、state、credential、raw logは含めていません。

| 検証項目 | 状態 | Share-safeな結果 |
| --- | --- | --- |
| platformと導入前提 | 完了 | exact platform tuple、legacy backend、native IPv6、DHCPv6-PD LAN `/64` evidence、UniFi管理IPIP6 tunnel候補、検証済みuser hookを確認 |
| 手動移行 | 完了 | 旧実装停止後のdry-run、apply、`status`、provider通知、対象LANの固定IPv4出口・native IPv6・DNSを確認 |
| rollbackと再apply | 完了 | timed recovery、新実装`off`、元トンネル復元、旧baseline復帰、新実装の再applyを確認 |
| 再起動とboot apply | 完了 | shutdown/startによるBoot ID変更、WAN readiness後のapply成功、対象LAN通信復帰を確認 |
| 新automation | 有効・稼働中 | `trigger.service`、`watch.service`、`update.timer`がenabled/active。旧実装はdisabled/inactive |
| 短時間soak | 完了 | 再起動後2分間・9回の定期`status`でエラー0、provider update timerの初回tick成功、failed unit 0 |
| provider transport | HTTPを継続 | 公開資料に正式なHTTPS URLは見つからず、実機と対象LANからのHTTPS接続も成立しなかったため、推測したHTTPS URLへ変更していない |

変更前browser baselineでは、JPIX判定`5999`（v6プラス固定IP）、IPv4、IPv6、フレッツ西日本到達性、v6プラス用試験が成功しました。手動apply後の単純HTTP取得ではinteractiveな判定を再現できないため、変更後の同一browser/LAN比較は完了扱いにしていません。

残作業は[親Issue #2](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/2)から次へ分割しています。

- [Issue #3](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/3): UniFi Network reprovisionとNetwork application restart後の自動収束
- [Issue #4](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/4): DHCPv6-PD prefix変更後のendpoint、outer rule、provider通知追従
- [Issue #5](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/5): project-owned standalone tunnelとの実機比較
- [Issue #6](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/6): PMTUD、ICMPv6 Packet Too Big、大きなUDP、VPN
- [Issue #7](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/7): 対象外LAN実端末と変更後JPIX接続判定

新automationの再起動復帰が成功していても、Issue #3〜#7の完了やproduction readinessを意味しません。現方式は引き続きUniFi管理トンネルを共有するexperimental repairです。

## 外部接続判定をbaselineとして使う

[JPNE/JPIX IPv4/IPv6接続判定ページの説明](service-and-protocols.md#9-jpnejpix-ipv4ipv6接続判定ページ)に沿って、変更前と手動apply後に同じLAN端末から判定します。VPN、proxy、privacy relayなどInternet出口を変える機能は停止するか、使用中であることを記録します。

1. 変更前に対象LANと対象外LANから各1回実行し、判定文と試験1〜10をprivateに保存します。
2. 手動apply後に同じ端末、browser、URL、LANで再実行します。
3. 対象LANの表示IPv4が契約固定IPv4と一致し、IPv4試験、IPv6試験、接続地域の試験、試験10が成功することを確認します。
4. 対象外LANは変更前と同じ出口・試験結果を維持していることを確認します。
5. prefix変更試験と再起動試験の後にも繰り返し、自動復旧後の外向き通信を確認します。

表示されるIPv6はbrowser端末のnative IPv6 sourceであり、IPIP tunnelのlocal endpointとは限りません。表示`Port`もtest connectionのsource portで、IPIP tunnel portではありません。判定`5999`と試験10の成功だけでは、内部設定、endpoint通知、再起動復帰、rollbackを証明できません。

## 1. 導入前preflight

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
```

確認項目：

- `PREFLIGHT_MODE=share-safe`
- rootと必須commandが利用可能
- `PLATFORM_COMPATIBILITY=verified`かつ`XTABLES_BACKEND=legacy`
- native IPv6 default routeとglobal addressが存在
- aggregate PD routeまたはLAN bridge上のglobal `/64` evidenceが存在
- readyなIPIP6 tunnel候補が1つ以上
- UniFiのIPv4 NAT user chainとIPv6 input user chainが存在
- 各user chainへ検証済み親chainから一意なjumpが存在

`DHCPV6_PD_ROUTE=absent`でも、UniFi OS 5がLAN bridge向けglobal `/64`だけを展開している場合は`DHCPV6_PD_LAN64_EVIDENCE=present`になります。両方が`absent`なら中止し、[Troubleshooting](troubleshooting.md)の追加確認でPD成功を証明できるまで進まないでください。

## 2. Configと権限

```sh
sudo stat -c '%U:%G %a %n' /data/unifi-jpix-tunnel-repair/config /data/unifi-jpix-tunnel-repair/config/*
```

- config directoryはroot所有、mode `0700`
- 3つの実configはroot所有、mode `0600`
- symlinkではない
- example value、未知key、重複keyが残っていない
- `ENDPOINT_IF`にglobal kernel `/64`候補がexactに1つだけある
- routed networkがRFC1918 canonical、connected route完全一致、non-overlapである

## 3. 診断

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh --full-output /data/unifi-jpix-tunnel-repair/state/diagnostic.txt
```

- stdoutが`DIAGNOSTIC_MODE=share-safe`を返し、完全addressやCIDRを含まない
- 完全診断が新規mode `0600` fileとして作成される
- BR route、WAN、route source、delegated `/64`由来のlocal endpoint、トンネルremote、MTUが契約と一致
- `ENDPOINT_PREFIX_STATUS=unique`
- user hook parentが一意で、global `POSTROUTING`や`INPUT`へfallbackしていない
- 専用tableとrule priorityが既存用途と衝突しない

完全診断は実機内だけで確認し、Issueへ貼らないでください。

## 4. Dry-run

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh --dry-run apply
```

- exit statusが成功
- 固定IPv4、BR、完全IPv6をstdoutやlogへ表示しない
- 設定したLANだけが計画に含まれる
- 対象外LAN、既存route、既存rule、無関係なnetfilter ruleを削除しない
- networkとstateが実行前後で変化しない

## 5. 手動apply

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-update.sh --force
```

- `status`が成功
- 対象LANから契約固定IPv4でIPv4通信できる
- 対象LANからnative IPv6通信を継続できる
- 対象外LANのIPv4出口、IPv6、DNS、既存policyが変わらない
- inbound要件がある場合は、必要なportとfirewallを別途確認する

## 6. Endpoint変更とprovider通知

- DHCPv6-PD更新または同等の安全な試験後にlocal endpointが追従する
- 古いendpoint、route、rule、outer accept ruleが残らない
- provider通知は設定されたURL scheme、HTTP status、response判定が成功した場合だけstateを更新する
- HTTPを使用する場合は明示opt-inとexact host一致があり、providerが明示していないHTTPS URLへ推測で変更していない
- provider responseやcredentialがjournalへ出ない

## 7. rollback・再apply・automation gate

- `off`で元のUniFiトンネルと通常経路へ復帰する
- `off`後も対象外LANとnative IPv6が維持される
- 旧実装を再applyしてbaselineへ戻せる
- 旧実装を再びoffにし、新実装の手動apply、status、provider `--force`、通信確認を再現できる
- automationを有効化する前に、手動apply、通信確認、`off`、rollback、再applyが再現できる
- enabled状態で実際に再起動し、WAN readiness後のapply、unit稼働、通信復帰、duplicate不在、timer tickを確認する

実機移行では、service状態変更後にtag付きSNAT ruleが1回欠落しました。手動再applyで復旧後、新automationを有効化して再起動し、2分間・9回の`status`でエラー0を確認しました。ただし、UniFi管理状態との共有所有権が解消した証拠にはなりません。

現在の実機では、新しいtrigger、watch、update timerがenabled/activeで、旧実装はdisabled/inactiveです。UniFi reprovision、Network application restart、prefix変更、独立トンネル比較、PMTUD、UDP、VPN、対象外LAN実端末の外部到達性はIssue #3〜#7として別の承認と検証が必要です。

## 結果の共有

Issueへ共有できるのは`PREFLIGHT_MODE=share-safe`または`DIAGNOSTIC_MODE=share-safe`の出力です。接続判定ページのcopyやscreenshotは共有安全ではありません。完全address、prefix、interface名、port、MAC、serial、device ID、時刻、config、state、完全診断は一般化または削除してください。
