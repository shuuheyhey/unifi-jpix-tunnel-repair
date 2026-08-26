# Validation

検証は次の順序で行います。失敗または説明できない差分があれば、自動化や次の段階へ進まないでください。

## 現在の実機検証範囲

UDM Pro・UniFi OS 5系で、native IPv6、IPIP6トンネル候補、UniFi user chain、DHCPv6-PDのIA_PD処理とLANへのglobal `/64`展開を確認済みです。config投入後のdry-run、手動apply、固定IPv4出口、再起動復帰、rollbackは未完了です。[Issue #1](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/1)で結果を追跡します。

## 1. 導入前preflight

```sh
sudo ./scripts/unifi-jpix-tunnel-repair-preflight.sh
```

確認項目：

- `PREFLIGHT_MODE=share-safe`
- root、必須command、UniFi OS、Network packageが利用可能
- native IPv6 default routeとglobal addressが存在
- aggregate PD routeまたはLAN bridge上のglobal `/64` evidenceが存在
- readyなIPIP6 tunnel候補が1つ以上
- UniFiのIPv4 NAT user chainとIPv6 input user chainが存在

`DHCPV6_PD_ROUTE=absent`でも、UniFi OS 5がLAN bridge向けglobal `/64`だけを展開している場合は`DHCPV6_PD_LAN64_EVIDENCE=present`になります。両方が`absent`なら中止し、[Troubleshooting](troubleshooting.md)の追加確認でPD成功を証明できるまで進まないでください。

## 2. Configと権限

```sh
sudo stat -c '%U:%G %a %n' /data/unifi-jpix-tunnel-repair/config /data/unifi-jpix-tunnel-repair/config/*
```

- config directoryはroot所有、mode `0700`
- 3つの実configはroot所有、mode `0600`
- symlinkではない
- example value、未知key、重複keyが残っていない

## 3. 診断

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh --full-output /data/unifi-jpix-tunnel-repair/state/diagnostic.txt
```

- stdoutが`DIAGNOSTIC_MODE=share-safe`を返し、完全addressやCIDRを含まない
- 完全診断が新規mode `0600` fileとして作成される
- BR route、WAN、route source、トンネルremote、local endpoint、MTUが契約と一致
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

## 7. 自動化・再起動・rollback

- trigger、watch、update timerがactiveになる
- drift修復時以外に変更を繰り返さない
- UDM再起動後にWAN、native IPv6、固定IPv4、自動化が復帰する
- `off`で元のUniFiトンネルと通常経路へ復帰する
- `off`後も対象外LANとnative IPv6が維持される

## 結果の共有

Issueへ共有できるのは`PREFLIGHT_MODE=share-safe`または`DIAGNOSTIC_MODE=share-safe`の出力です。完全address、prefix、interface名、port、MAC、serial、device ID、時刻、config、state、完全診断は一般化または削除してください。
