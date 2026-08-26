# Validation

検証は次の順序で行います。失敗または説明できない差分があれば、自動化や次の段階へ進まないでください。

## 現在の実機検証範囲

UDM Pro・UniFi OS 5系で、native IPv6、IPIP6トンネル候補、UniFi user chain、DHCPv6-PDのIA_PD処理とLANへのglobal `/64`展開を確認済みです。2026-08-26の外部接続試験ではJPIX判定`5999`（v6プラス固定IP）、IPv4、IPv6、フレッツ西日本到達性、v6プラス用試験が成功しました。

この接続試験は変更前baselineです。Issue #2のP0/P1を反映した新schemaでは、旧実装停止後のdry-run、手動apply、`status`、対象LAN実端末からの固定IPv4出口・native IPv6・DNS、provider通知、timed recovery、`off`、旧実装への復帰、再applyを同じ実機で確認済みです。新旧automationはdisabled/inactiveのままです。

手動apply後のHTTPによる単純取得では、interactiveなJPIX判定`5999`を再現できませんでした。したがって変更前の手動browser結果をbaselineとして残し、変更後のJPIX判定を成功扱いにはしていません。対象外LANはrule scopeとmanaged stateでは確認しましたが、対象外LAN実端末からの外部到達性は未測定です。prefix変更追従、再起動復帰、reprovision、独立トンネル比較、PMTUD、UDP、VPNも未完了です。[Issue #2](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/2)で結果を追跡します。

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
- provider通知が必要な場合は、HTTPS成功後だけstateが更新される
- provider responseやcredentialがjournalへ出ない

## 7. rollback・再apply・未完了gate

- `off`で元のUniFiトンネルと通常経路へ復帰する
- `off`後も対象外LANとnative IPv6が維持される
- 旧実装を再applyしてbaselineへ戻せる
- 旧実装を再びoffにし、新実装の手動apply、status、provider `--force`、通信確認を再現できる
- trigger、watch、update timerはdisabled/inactiveのままである

実機移行では、service状態変更後にtag付きSNAT ruleが1回欠落しました。手動再applyで復旧し、時間を置いた`status`でもhealthyを再確認しましたが、UniFi管理状態との共有所有権が解消した証拠にはなりません。単発のhealthyをautomation有効化の根拠にしないでください。

UDM再起動、UniFi reprovision、prefix変更、独立トンネル比較、PMTUD、UDP、VPN、対象外LAN実端末の外部到達性は別の承認と検証が必要です。それらが完了するまで新旧automationを有効化しません。

## 結果の共有

Issueへ共有できるのは`PREFLIGHT_MODE=share-safe`または`DIAGNOSTIC_MODE=share-safe`の出力です。接続判定ページのcopyやscreenshotは共有安全ではありません。完全address、prefix、interface名、port、MAC、serial、device ID、時刻、config、state、完全診断は一般化または削除してください。
