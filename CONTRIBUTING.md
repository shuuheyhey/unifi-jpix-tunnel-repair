# Contributing

Issue、文書修正、test追加、UniFi OS互換性報告を歓迎します。本projectはroot権限でrouteとfirewallを扱う実験的実装のため、安全性、再現性、rollback可能性を優先します。

## Issueを作成する前に

- credential、固定IPv4、完全IPv6、prefix、MAC、serial、device ID、interface名、port、時刻を削除する
- `discover`、`check`、`plan`、`status --json`、`doctor`の出力を確認し、必要なreason codeと状態だけを共有する。configなしの`discover`は実interface名とfirmwareを表示するため、出力全体を貼らない
- config、state、完全診断、provider response、journal全文を貼らない
- セキュリティ問題は公開Issueではなく[Private Vulnerability Reporting](SECURITY.md)を使用する

UniFi OS 5ではPDが成功していてもaggregate routeを残さず、LAN bridge向けglobal kernel `/64`だけを展開する場合があります。対象LAN bridgeのglobal kernel `/64`が一意であることを検証します。PD問題では実prefixを伏せ、WANのPD設定とbridge上の候補件数を報告してください。

## 変更の原則

1. 既存の安全境界を弱めない最小変更にする
2. behavior変更やbugfixは失敗するtestを先に追加する
3. fixtureにはdocumentation addressとsynthetic credentialだけを使用する
4. configやstateをshellとしてsourceしない
5. 所有権を証明できないroute、rule、netfilter stateを変更しない

## ローカル検証

Python 3とPOSIX shellを使用します。通常のテストはmock/fixtureで実行し、実機へのSSHや本番configを必要としません。最初に変更対象のテスト、次に全suiteを実行します。

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest discover -s tests_v2 -p test_repository.py -v
find scripts tests -type f -name '*.sh' -exec sh -n {} \;
find scripts tests -type f -name '*.sh' -exec shellcheck -S error -s sh {} +
PYTHONDONTWRITEBYTECODE=1 sh tests/run.sh
git diff --check
```

先頭の例は文書変更用です。behavior変更なら該当moduleのテストから始めます。ShellCheckとGitleaksが利用できなかった場合は、その検証が未実施であることをPRに明記します。上のコマンドはGitleaksを含みません。CIではGitleaksも実行し、発火条件はpull requestと`main`へのpushです。

## 文書の更新規則

導入手順は[Installation](docs/installation.md)、設定fieldは[Configuration](docs/configuration.md)、CLIとmodeは[運用ガイド](docs/guide.md)、componentとunitは[Architecture](docs/architecture.md)を正本にします。同じコマンド手順を複数文書へコピーせず、リンクで参照します。

`test_repository.py`はlocal link/anchor、公開CLIの一覧、配布unit一覧、設定雛形のfieldの記載漏れを確認します。文章の意味やコマンドの安全性までは自動証明しないため、実装との照合も必要です。

[Validation](docs/validation.md)は日付・release・modeごとの記録です。テストを追加しただけで過去の件数を書き換えたり、新releaseが実機未試験なのに同じgateを合格にしたりしません。参照サイトの再調査とrepository内の整合性確認も区別します。

## Release作成

maintainer用の`scripts/build-v2-release.sh VERSION PRIVATE_KEY OUTPUT_DIR`はmanifest付きarchive、SHA-256、detached signatureを生成します。private keyをrepository・archiveへ含めず、公開鍵の配布経路を別途確認します。archive作成・local test・署名検証・公開・実機healthは別の検証段階です。作成しただけでは配布済みreleaseではありません。

## Pull request

PR本文には次を記載します。

- 変更理由と対象component
- root boundaryへの影響
- route、firewall、provider通信への影響
- credentialとdiagnostic出力への影響
- rollback方法
- 実行したtestと未実施の検証

実機検証では、model、UniFi OS系列、Network系列、成功・失敗したvalidation項目だけを共有します。完全versionや機器固有値が不要なら一般化してください。
