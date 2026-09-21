# Architecture

実装・所有境界の詳細は[運用ガイド](guide.md)を正本とします。

1. `bin/unifi-jpix` がPython CLIを起動し、schema付き設定と別credentialを読みます。
2. `core.py` はcapabilityと所有権を検査し、standaloneのproject-owned tunnelを収束させます。`managed.py` は明示enrollment済みのUniFi管理WANを限定補正します。
3. boot・event・timer・UDAPI pathが同じflockへ集約し、前提不成立とforeign conflictでは変更しません。
4. `release.py` とbootstrapがmanifest、release切替、health、互換性を検査します。復旧先のcapabilityも検査します。

正本は `/data/unifi-jpix-tunnel-repair`。不変releaseと `config-v2.json`、`credentials-v2.json`、`state-v2/` を分離します。通常例外の逆操作と、電源断後のjournal replayは同じ保証ではありません。後者は未実装です。
