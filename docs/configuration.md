# Configuration

設定は `/data/unifi-jpix-tunnel-repair/config-v2.json`、provider認証情報は別JSONです。[雛形](../config/config-v2.json.example)と[認証情報の雛形](../config/credentials-v2.json.example)を使用し、どちらもroot所有・mode `0600`の通常ファイルにします。symlinkやgroup/otherから読めるファイルは拒否されます。

以下は[Config.load](../src/unifi_jpix/core.py)のschema version 2に対応します。未知のキーはトップレベル・各objectとも拒否します。契約値・interface・URLを含むため、認証情報が別でもconfig全体をprivateに扱います。

## 必須設定

| フィールド | 値・制約 |
| --- | --- |
| `schema_version` | `2` |
| `service` | `jpix-v6plus-static-ipv4-one` |
| `static_ipv4` | 契約で割り当てられた固定IPv4 1個。CIDRではなくaddress |
| `br_ipv6` | 契約BRのglobal IPv6 address |
| `iid` | 契約で指定されたIPv6の下位64 bit。16進4桁を4組、colon区切りで指定。省略形は不可、prefixから推測しない |
| `endpoint_network.interface` | endpointを生成するLAN bridgeの明示selector。下のCIDRとは併用不可 |
| `endpoint_network.ipv4_cidr` | endpoint用LANのprivate IPv4 CIDR。上のinterfaceとは併用不可 |
| `routed_networks[].interface` | トンネル経由にするLAN interface。1件以上 |
| `routed_networks[].ipv4_cidr` | そのLANのprivate IPv4 CIDR。interfaceとCIDRはそれぞれ重複不可、CIDR同士の重なりも不可 |

`endpoint_network`にはselectorをちょうど1つ指定します。該当bridgeのglobal kernel `/64`が一意である必要があります。CIDRはhost bitを含まないnetwork addressで指定します。endpoint用LANと転送対象LANの一覧は別の役割です。`routed_networks`へ載せただけでbridgeやDHCP設定は作成されません。

物理WAN、tunnel underlay、IPv6 prefixをconfigへ固定しません。設定後はBR宛てのIPv6経路からWANを検出し、bridgeのprefixと契約IIDからendpointを生成します。config未作成の`discover`が示すIPv6 default候補は、BR経路の検証結果ではありません。

## 任意設定と既定値

| フィールド | 省略時 | 制約・用途 |
| --- | --- | --- |
| `tunnel.name` | `jpix0` | standaloneの専用interface名。LAN名との衝突不可。通常は変更しない。managed移行時は専用CLIが管理WAN名へ更新 |
| `tunnel.mtu` | `1460` | `1280`〜`1460`。underlayのcapability確認も必要 |
| `tunnel.tcp_mss` | `min(1420, mtu - 40)` | `536`〜`mtu - 40` |
| `resources` | `{}` | 空き資源を自動割当。通常は空objectのまま |
| `resources.route_table` | 自動 | 指定する場合は`1`〜`4294967295`。数値範囲内でも占有・所有権競合は拒否 |
| `resources.rule_priority_base` | 自動 | 指定する場合は`1`〜`32700`、LAN数を加えた上端は`32765`以下。追加adapterの予約域も競合検査対象 |
| `firewall.outer_ipip_allow` | `true` | 契約BR→local endpointのIPv4-in-IPv6許可ruleを管理。`false`なら別途適切な許可が必要 |
| `router_recovery.enabled` | `false` | 単一WAN向けUDM自身のIPv4経路・monitor補正へopt-in |
| `integration.mode` | `standalone` | `unifi-managed`はrouter recovery必須。JSONだけで切替禁止。[明示移行](guide.md#unifi管理wanへの統合preview)を使用 |
| `repair.interval_seconds` | `300` | 現schemaでは`300`だけを受理。configによる周期変更は不可 |
| `webhook` | `{}` | 未設定なら通知なし |
| `webhook.url` | なし | userinfoなしのHTTPS URL。URL自体に秘密が含まれ得るため公開しない |

自動割当はroute table `10000`〜`10999`、rule priority `20000`〜`20999`から空き範囲を探します。基本rule数は対象LAN数+1です。health成功後のruntimeへ保存して再利用し、他の資産を追い出して確保しません。router recoveryの追加予約は[運用ガイド](guide.md#udm本体のipv4と回線監視の補正単一wan-opt-in)を参照してください。

## Provider通知

| フィールド | 省略時 | 制約・用途 |
| --- | --- | --- |
| `provider.update_url` | 通知なし | 契約ISP指定の完全URL。HTTPS推奨。userinfo・query・fragmentは禁止 |
| `provider.credentials_file` | なし | credential JSONの絶対パス。通知を使う場合は設定する |
| `provider.allow_insecure_http` | `false` | HTTPのみのISPに対する明示opt-in |
| `provider.insecure_http_host` | なし | HTTP使用時にURLのhostnameと完全一致させる。wildcardや別hostへの許可ではない |

credential JSONは`provider_username`と`provider_password`だけを含めます。値は空でない文字列とし、改行やNULを含めません。URLやconfigの他のfieldへ認証情報を埋め込まないでください。

`check`はprovider URLの形式を検査しますが、credentialの読み込み・認証・通知先への接続は実際の通知時です。health成功後、endpoint変更またはpendingがある場合に通知し、transport失敗は`pending-provider.json`へ記録して後続のhealth成功したreconcileで再試行します。通知失敗だけでは正常なdata planeを戻しません。

通知はhealthより後なので、endpoint未登録などで先にdata planeのhealthが失敗すると通知処理まで進みません。初回登録・prefix変更のすべてを通知だけで自動復旧できる実装ではありません。通知待ちと疎通失敗を混同せず、契約ISPの手順と[未検証gate](validation.md#未検証の実機gate)を確認してください。

通知しない契約・検証構成ならproviderを省略するか`{}`にできますが、契約上必要な通知を省略してよいという意味ではありません。雛形の架空URLと認証情報を残したままactivateしないでください。HTTP opt-inは認証情報を暗号化せず送る許可です。

## 設定変更時の注意

稼働中のconfigを編集すると、次のeventやtimerで適用され得ます。`check → plan`で事前確認したい場合はprivateな別ファイルを使い、変更対象のコマンドだけに`--config PATH`を指定します。検査後の本番切替は管理経路と作業時間を確保して行います。`--config`の適用範囲は[CLIリファレンス](guide.md#公開cli)を参照してください。

router recoveryのenrollment記録がある状態では、`enabled`をfalseへ書き換えるだけの解除は拒否されます。managed modeの解除と同様、所有権記録を削除して回避しないでください。

`UNIFI_JPIX_ALLOW_DOCUMENTATION_ADDRESSES=1`は合成fixture用のテスト設定です。雛形を通すために実機運用で有効にしないでください。未知versionでも既知capabilityなら検査を続けますが、未知backendや曖昧な所有権は設定値で強制許可しません。
