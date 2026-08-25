# Contributing

Issue、文書修正、テスト追加、互換性報告を歓迎します。本プロジェクトは実験的なルーター制御コードのため、安全性と再現性を優先します。

## Before opening an issue

- 実在する認証情報、固定IP、IPv6プレフィックス、MACアドレス、シリアル番号、デバイスIDを削除してください。
- 通常診断の `DIAGNOSTIC_MODE=share-safe` 出力だけを共有してください。
- セキュリティ問題は公開Issueではなく [Private Vulnerability Reporting](SECURITY.md) を使用してください。

## Pull requests

1. 変更に対応する shell test を追加します。
2. `sh -n`、ShellCheck、`tests/run.sh` を実行します。
3. `git diff --check` と Gitleaks を通します。
4. 実機依存値をコード、文書、fixture、コミットメッセージへ含めません。
5. root権限、ファイル権限、ルート・firewall変更、ロールバックへの影響をPR本文に記載します。

実機検証を行った場合も、機器固有値は伏せ、モデル、UniFi OSの系列、成功・失敗した検証項目だけを記載してください。
