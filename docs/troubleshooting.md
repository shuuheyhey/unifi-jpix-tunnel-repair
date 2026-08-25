# Troubleshooting

## `invalid ... configuration`

値だけでなく、directoryのcanonical path、symlink、所有者、mode `0600` を確認します。設定をshellでsourceして調査しないでください。

## `RESULT=not-ready`

共有用stdoutには状態だけが表示されます。ローカルでのみ完全診断を作成し、WAN、PD、BR route、tunnel、reserved table、policy ruleの順に確認します。完全診断を公開場所へ貼り付けないでください。

## Update notification fails

- HTTPS URL、IPv6到達性、source endpoint、認証情報を確認します。
- HTTP-only endpointでは明示opt-inとhost完全一致が必要です。
- provider response bodyや認証情報はlogへ出しません。
- 成功状態は検証済みHTTP success後だけatomicに更新されます。

## UniFi upgrade aftercare

upgrade後は自動化を止め、トンネル名、display mode、BR remote、WAN route source、netfilter chainを再確認します。互換性を推測して即時再適用しないでください。
