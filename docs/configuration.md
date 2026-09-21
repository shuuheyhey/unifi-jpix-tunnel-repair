# Configuration

正本は[運用ガイド](guide.md#初期導入)と[JSON雛形](../config/config-v2.json.example)です。

1. `schema_version=2`、service、固定IPv4、BR IPv6、契約IIDを設定します。
2. `endpoint_network` はIPv4 CIDRまたはinterface selectorの一方だけを指定し、対象LANを `routed_networks` に列挙します。WANやunderlay interfaceは固定しません。
3. provider credentialは[別JSON](../config/credentials-v2.json.example)へ保存し、root所有・mode `0600` を維持します。
4. `check` と `plan` を確認してからactivateします。候補不明・複数・所有権不明は手動で解消します。

`integration.mode` の既定はstandaloneです。管理WAN統合は健全なstandaloneから専用CLIで行い、JSONだけを先に変更しません。Content Filter経由DNSは通常DNSとは別に確認してください。
