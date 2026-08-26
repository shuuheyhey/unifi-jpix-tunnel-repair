# Troubleshooting

調査中に完全address、config、state、provider responseをterminal共有やIssueへ貼り付けないでください。共有する場合はpreflightまたは通常診断のshare-safe出力だけを使用します。

## Preflightが`RESULT=needs-attention`

`missing`または`absent`の項目を上から確認します。root、依存command、exact platform tuple、legacy backend、native IPv6、DHCPv6-PD、IPIP6 tunnel、UniFi user chain、親jumpの順に切り分けます。

### `PLATFORM_COMPATIBILITY=unknown`

UniFi OS、`/usr/lib/unifi/webapps/ROOT/app-unifi/.version`のNetwork version、kernel、iproute2、iptables/ip6tables backendのどれかが`config/verified-platforms.conf`と完全一致していません。古いdpkg recordの有無や「UniFi OS 5系だから」という推測で通過させません。upgrade後は新tupleをread-only調査し、reviewと実機検証を経てmatrixを更新します。

### PD evidenceが両方`absent`

`DHCPV6_PD_ROUTE=absent`かつ`DHCPV6_PD_LAN64_EVIDENCE=absent`なら、PD未成立の可能性があります。UniFi OS 5の実機で確認した、aggregate `/48`〜`/63` routeを残さずLAN bridge向けglobal `/64`を`proto kernel`として展開する状態は、後者を`present`として検出します。bridge以外のglobal `/64`はPD evidenceとして受理しません。

この組み合わせを見てWAN設定を変更せず、実機上で次を追加確認します。

- UniFi WAN IPv6がDHCPv6で、契約に合うprefix delegation sizeを要求している
- DHCPv6 client processが稼働している
- log上でIA_PDを受信し、no-prefixエラーが継続していない
- LAN bridgeへglobal `/64`が配布されている
- clientがnative IPv6を利用できる

確認結果には実prefixやinterface名を含めず、件数とpresent/absentだけを共有してください。現行検出ロジックの追跡は[Issue #1](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/1)で行います。

### `IPIP6_TUNNEL_READY_COUNT=0`

- UniFi WAN設定が想定するIPv4 over IPv6接続を生成しているか確認する
- `ip -d -6 tunnel show`は実機内だけで確認する
- mode、remote、localが存在する候補を確認する
- 独自トンネルを追加して回避しない

### UniFi user chainまたはparent jumpが`absent`

UniFi OS updateでchain名、親chain接続、netfilter backendが変わった可能性があります。applyへ進まず、exact version、backend、chain inventoryを実機内で確認してください。既存chainを手動作成せず、global `POSTROUTING`や`INPUT`へfallbackしません。

### `ENDPOINT_PREFIX_STATUS=missing-or-ambiguous`

設定した`ENDPOINT_IF`にglobal kernel `/64`が0件または複数あります。WAN/BR route sourceの上位64bitで代用しません。UniFi LAN設定、delegated prefix、exact interfaceのkernel routeを照合し、一意にならない場合は停止します。

## `invalid ... configuration`

- directoryのcanonical path、owner、mode、symlinkを確認する
- 3つの実configが同じ安全なdirectoryにあることを確認する
- 未知key、重複key、空の必須値、example valueを確認する
- configをshellでsourceして調査しない

## 診断が`RESULT=not-ready`

通常stdoutには状態だけが表示されます。完全診断を実機上のprivate fileへ作成し、WAN、PD、BR route、route source、tunnel、reserved table、policy rule、netfilterの順に確認します。完全診断をIssueへ貼らないでください。

## Applyまたはstatusが失敗する

```sh
sudo /data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
sudo journalctl -u unifi-jpix-tunnel-repair-apply.service -n 100 --no-pager
```

journalは共有せず実機内で確認します。`phase=`、`drift=`、rollback結果を確認し、同じ状態でapplyを繰り返さないでください。rollback work directoryが保存された場合は削除せず、復旧資料として保全します。

## Provider更新が失敗する

- HTTPS URL、IPv6 source endpoint、credential、provider availabilityを確認する
- `UPDATE_INTERVAL_SECONDS=0`では定期通知が無効になる
- HTTP-only endpointでは明示opt-inとhost完全一致が必要
- provider response bodyやcredentialをlogへ出さない
- 検証済みHTTP success前にstateが更新されていないことを確認する

## systemd serviceが起動しない

```sh
sudo systemctl status unifi-jpix-tunnel-repair-apply.service unifi-jpix-tunnel-repair-trigger.service unifi-jpix-tunnel-repair-watch.service unifi-jpix-tunnel-repair-update.timer
sudo systemctl list-dependencies unifi-jpix-tunnel-repair-trigger.service
```

config存在条件、WAN readiness timeout、apply.serviceの失敗を先に確認します。triggerとwatchはapply成功前には起動しません。

## UniFi OS upgrade後

自動化を停止し、preflight、トンネルmode、BR remote、WAN route source、netfilter chain、dry-runを再確認します。互換性を推測して即時再適用しないでください。
