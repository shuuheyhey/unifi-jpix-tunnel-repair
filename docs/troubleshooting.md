# Troubleshooting

まず `unifi-jpix status --json`、`doctor`、`check`、`plan` を確認します。公開前に機器固有値を確認・除去し、config/state/raw journalを貼らないでください。

1. `healthy` はdesired stateとの差分なしを意味します。新しい通信probeではないので、直近healthと実端末のIPv4・IPv6・DNSを別に確認します。
2. 前提不成立ならWAN link、BR経路、対象bridgeの一意なglobal kernel `/64` を確認します。aggregate PD route不在だけでPD失敗と断定しません。
3. foreign conflictなら対象資産の所有者を確認します。route/rule/firewallの一括flushで解消しないでください。
4. Content Filter併用時はWAN専用DNSとfilter転送経路も確認します。[WAN DNSの注意](guide.md#content-filterを併用する場合のwan-dns)を参照してください。
5. bootstrap欠落なら既知の同release installerで再配置します。release変更なら[Rollback](rollback.md)の互換性と別管理経路を先に確認します。

UniFi管理 `ip6tnl1` は稼働中のWANを担う場合があります。現在のintegrationを確認せず削除しないでください。設定保存時の短い通信断を完全に防ぐ保証はありません。
