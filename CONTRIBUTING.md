# Contributing

Issue、文書修正、test追加、UniFi OS互換性報告を歓迎します。本projectはroot権限でrouteとfirewallを扱う実験的実装のため、安全性、再現性、rollback可能性を優先します。

## Issueを作成する前に

- credential、固定IPv4、完全IPv6、prefix、MAC、serial、device ID、interface名、port、時刻を削除する
- v2の`discover`、`check`、`plan`、`status --json`、`doctor`の出力を確認し、必要なreason codeと状態だけを共有する
- config、state、完全診断、provider response、journal全文を貼らない
- セキュリティ問題は公開Issueではなく[Private Vulnerability Reporting](SECURITY.md)を使用する

UniFi OS 5ではPDが成功していてもaggregate routeを残さず、LAN bridge向けglobal kernel `/64`だけを展開する場合があります。v2では対象LAN bridgeのglobal kernel `/64`が一意であることを検証します。PD問題では実prefixを伏せ、WANのPD設定とbridge上の候補件数を報告してください。

## 変更の原則

1. 既存の安全境界を弱めない最小変更にする
2. behavior変更やbugfixは失敗するtestを先に追加する
3. fixtureにはdocumentation addressとsynthetic credentialだけを使用する
4. configやstateをshellとしてsourceしない
5. 所有権を証明できないroute、rule、netfilter stateを変更しない

## ローカル検証

```sh
find scripts tests -type f -name '*.sh' -exec sh -n {} \;
sh tests/run.sh
git diff --check
```

ShellCheckとGitleaksが利用できる環境では、変更対象とrepository全体へ実行してください。利用できなかった場合はPRに明記します。

## Pull request

PR本文には次を記載します。

- 変更理由と対象component
- root boundaryへの影響
- route、firewall、provider通信への影響
- credentialとdiagnostic出力への影響
- rollback方法
- 実行したtestと未実施の検証

実機検証では、model、UniFi OS系列、Network系列、成功・失敗したvalidation項目だけを共有します。完全versionや機器固有値が不要なら一般化してください。
