# Troubleshooting

最初に「実端末の通信障害」「UDM自身の通信・DNS」「管理画面の表示」「自己修復の異常」を分けます。ISP名の欠落や速度測定失敗だけで、全インターネット通信が停止しているとは判断しません。一方、通常HTTPSが成功してもfilter専用DNSが正常とは限りません。

## 最初のread-only確認

UDM上で次を実行します。未activateで短縮CLIがない場合は`/data/unifi-jpix-tunnel-repair/current/bin/unifi-jpix`を使います。

```sh
unifi-jpix status --json
unifi-jpix doctor
unifi-jpix check
unifi-jpix plan
```

続いて`current/verified/previous`のlinkと、bootstrap・timer・event monitor・UDAPI pathの`is-enabled`と`is-active`を確認します。`doctor=ready`はactive確認の代わりになりません。通常・UDAPI reconcileのoneshotは平常時inactiveでも正常です。

必要なら該当unitに絞って直近journalをprivateに確認します。例えば以下は通常reconcileの直近50行です。raw logは共有せず、reason codeと結果だけを抜粋してください。

```sh
journalctl -u unifi-jpix-reconcile.service -n 50 --no-pager
```

`reconcile`は診断だけのコマンドではなく、修復と外部通知を行います。読み取りだけで原因を確認したい段階では実行しません。

## 状態とreason code

| 出力 | 意味 | 次の確認 |
| --- | --- | --- |
| `healthy` | 現在のplanに差分なし | `last_health`の新しさと実端末通信を別に確認 |
| `drifted` | 修復予定が残っている | `plan`の理由、監視unit、直近reconcile結果 |
| `quarantined` | 過去の隔離記録があり、現在のplanは生成できた | 理由と実状態を照合。次回成功で解除されるが、記録を手動削除しない |
| `unavailable` / `prerequisite-unavailable` | 前提を確認できない。後者はlock競合でも出る | WAN link、BR宛て経路、bridge prefix候補、必要なhook、同時実行 |
| `foreign-conflict` | 所有権・予約領域・既知の構成と不一致 | 競合資産の作成元とprivateなruntime記録 |
| `invalid-config` | schema、値、ファイル権限などの問題 | [設定仕様](configuration.md)、root所有・mode `0600`、symlinkでないこと |
| `rollback-failed` | 少なくとも一つの逆操作が失敗 | 追加自動起動を止め、[適用中の失敗](rollback.md#適用中の失敗)へ |
| `provider_notification=pending` | endpoint通知の再試行が必要 | credential、URL、transport、通知先へのIPv6到達性。data planeとは別に判断 |
| `boot_persistence=needs-reinstall` | unit・enablement・current linkの不足 | 対象の欠落を確認し、review済みsourceで[再配置](installation.md#稼働中のsource更新) |

`check=ready`は「適用済み」でも「provider認証成功」でもありません。`doctor`の終了codeが0でも各checksと内側のstatusを読む必要があります。詳しくは[Healthの読み方](guide.md#healthの読み方)を参照してください。

## WAN・prefix・所有権

WANは物理port番号から推測せず、現在のBR宛てIPv6経路とlinkで確認します。UniFi画面のport番号とLinux interface名を同一視しません。UniFi OS 5ではaggregate PD routeがなくてもLAN bridgeのglobal kernel `/64`が存在する場合があり、aggregate route不在だけではPD失敗と断定できません。

UniFi管理の`ip6tnl1`はmanaged modeで正常なWANを担う場合があります。「名前が古そう」という理由で削除しないでください。standaloneでも管理トンネルはツールの削除対象ではありません。route/rule/firewallの一括flush、他projectのrule削除、`state-v2`削除で競合を回避しないでください。

## Content Filter・YouTube・ゲーム

通常DNSとWAN専用DNS、Content Filterの転送経路を分けて確認します。Ad Block・Safe Searchによる意図した応答と、resolver不足による`REFUSED`/timeoutは別の問題です。過去のUDMでは、WAN側のAuto DNS設定で上流が生成されない一方、通常DNSは動作していました。

1. 症状のある端末・LANと、通常DNSかfilter経由かを特定します。
2. それぞれの経路でA/AAAA、UDP/TCP DNSを確認します。filter用portは現在の設定から調べ、過去の番号を決め打ちしません。
3. 通常IPv4/IPv6 HTTPSと、Safe Search・広告blockの期待した応答を分けて確認します。
4. upstreamが欠落している場合は、[WAN DNSの手順](guide.md#content-filterを併用する場合のwan-dns)に従いUniFiの設定として修正します。生成された`/run`ファイルだけを書き換えません。
5. 実端末で再生・接続を試します。フィルターを全削除して正常になっても、どの経路が原因だったかは別に特定します。

## 切断event・ISP表示・速度測定

`Multiple Internet Disconnections`は、設定保存に伴う再provisionと同時に発生した実機記録があります。現在のeventが同じ原因とは限らないため、設定保存、WAN link、endpoint変化、reconcile、回線監視の時系列をprivateに照合します。event通知時刻だけでPCの停止時間を測定したことにはなりません。

standaloneでは実通信とUniFiの論理WANが異なり、UDMの通常通信が成功しても管理画面の測定が失敗することがあります。[管理WAN統合](guide.md#unifi管理wanへの統合preview)は明示的な構成変更であり、表示だけを直す軽微な設定ではありません。まず現在のmodeと実通信を確認してください。

managed modeでもISP名・速度測定・監視は個別に確認します。表示やmonitor結果を手動書換えして成功に見せず、vendor scriptやcontroller DBへ推測の修正を加えません。設定保存時の短い断を完全に防ぐ保証はなく、過去の改善結果と未検証範囲は[Validation](validation.md)を参照してください。
