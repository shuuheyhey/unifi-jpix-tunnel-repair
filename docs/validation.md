# Validation

次を順番に確認します。途中で失敗したら自動化へ進まないでください。

1. 導入前preflightが `PREFLIGHT_MODE=share-safe` と `RESULT=ready-for-config` を返す。
2. 設定directoryと3ファイルがroot所有で安全なmodeになっている。
3. 共有診断が `DIAGNOSTIC_MODE=share-safe` を返し、完全なaddressをstdoutへ出さない。
4. 完全診断fileがmode `0600` で作られ、BR route、WAN、tunnel候補が意図したものと一致する。
5. dry-runが固定IP、BR、完全IPv6を表示せず、対象LANだけを計画する。
6. manual apply後の `status` が成功する。
7. 対象LANから固定IPv4出口とnative IPv6の両方が利用できる。
8. 対象外LANの既存経路、DNS、WANが変化していない。
9. DHCPv6-PD更新または同等の試験後にendpointが追従する。
10. UDM再起動後にWAN、IPv6、固定IPv4、自動化が復帰する。
11. `off` で元のUniFiトンネルと通常経路へ復帰できる。

実機結果を公開する場合は、具体的なaddress、prefix、interface名、port番号、device ID、時刻を一般化してください。
