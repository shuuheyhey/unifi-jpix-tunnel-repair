# Installation

新規導入と稼働中の更新は別の手順です。この文書のコマンドは、UDM上に転送・reviewしたsource directoryでrootとして実行します。作業用PCでは実行しません。

## 導入前の条件

1. [対応サービス](service-and-protocols.md)と契約値を確認し、UniFi側のIPv6 IPoE・DHCPv6-PDを先に成立させます。ツールは回線契約やPD設定を作成しません。
2. 対象LAN、endpoint用bridge、既存のroute・policy・filterを確認します。機種名やversionだけでは対応を判断しません。
3. インターネット断でも使えるローカル管理経路、作業時間、失敗時の復旧方法を確保します。初回導入には過去のverified releaseがありません。
4. Python 3、systemd、iproute2、iptables/ip6tablesのlegacy backend、ping、curl、UniFiの機器情報・UDAPIコマンドが使えることを確認します。署名付きreleaseにはopensslも必要です。

本番の配置先は `/data/unifi-jpix-tunnel-repair` です。配布systemd unitはこの絶対パスを使用します。CLIの`--root`やinstallerの環境変数だけで別パスの本番環境を構築できるわけではありません。

## 新規導入

以下は未導入環境専用です。既存の`current`、config、automationがある場合は[稼働中のsource更新](#稼働中のsource更新)へ進んでください。

### 1. 配置して候補を確認する

```sh
./scripts/install-v2.sh
/data/unifi-jpix-tunnel-repair/current/bin/unifi-jpix discover
```

`--activate`なしではbootstrapを起動・有効化しません。ただしrelease作成、`current`の選択、bootstrap unit配置、daemon-reloadは行います。インストール前から動いている監視は停止しないため、既存環境での無影響なstagingではありません。

configのない`discover`は候補とplaceholder付きJSONを表示するだけで、設定ファイルを生成しません。候補が0件・複数件なら契約とLAN設定を確認し、推測で選ばないでください。出力には実interface名やfirmware情報が含まれるため、そのまま公開しません。

### 2. private configを作る

次の例は既存configがあれば停止します。`editor`はUDMで利用できるエディターに置き換えてください。

```sh
(
  set -eu
  umask 077
  test ! -e /data/unifi-jpix-tunnel-repair/config-v2.json
  test ! -L /data/unifi-jpix-tunnel-repair/config-v2.json
  install -m 0600 config/config-v2.json.example /data/unifi-jpix-tunnel-repair/config-v2.json
  editor /data/unifi-jpix-tunnel-repair/config-v2.json
)
```

[設定リファレンス](configuration.md)に従って契約値とLAN selectorを編集します。雛形のaddressとprovider URLは実運用には使えません。通知を利用する場合だけ、次のように別credentialを作ります。認証情報をコマンドの引数へ直接書かないでください。

```sh
(
  set -eu
  umask 077
  test ! -e /data/unifi-jpix-tunnel-repair/credentials-v2.json
  test ! -L /data/unifi-jpix-tunnel-repair/credentials-v2.json
  install -m 0600 config/credentials-v2.json.example /data/unifi-jpix-tunnel-repair/credentials-v2.json
  editor /data/unifi-jpix-tunnel-repair/credentials-v2.json
)
```

credential参照先がconfigと一致し、編集後も両ファイルがroot所有・mode `0600`であることを確認します。

### 3. 検査してから有効化する

```sh
/data/unifi-jpix-tunnel-repair/current/bin/unifi-jpix check
/data/unifi-jpix-tunnel-repair/current/bin/unifi-jpix plan
```

両方の成功と変更理由を確認し、問題がある場合はここで止めます。`check`成功は疎通・provider認証・Content Filter DNSの成功ではありません。`plan`はactivation前なので変更予定がある状態が通常です。

準備ができた場合だけ、同じsource・同じrelease名で実行します。

```sh
./scripts/install-v2.sh --activate
```

bootstrapがmanifestを検証し、unitとCLI symlinkを配置してreconcileします。失敗した場合は繰り返し実行せず、[復旧手順](rollback.md)で現在のreleaseと状態を確認します。

### 4. 有効化後の確認

```sh
unifi-jpix status --json
unifi-jpix doctor
systemctl is-active unifi-jpix-bootstrap.service unifi-jpix-reconcile.timer unifi-jpix-event-monitor.service unifi-jpix-udapi.path
readlink /data/unifi-jpix-tunnel-repair/current
readlink /data/unifi-jpix-tunnel-repair/verified
```

CLI短縮パスはbootstrapが配置します。`status`・`doctor`だけで合格にせず、[UDM Pro runbook](udm-pro-setup.md)のIPv4・IPv6・DNS・実端末チェックを行います。ISP表示や管理画面の速度測定が必要でも、健全性確認前にmanaged modeへ切り替えないでください。

## 稼働中のsource更新

source installerは署名付き`upgrade`とは別経路です。確認済みのsourceと一意な新release名を使います。同名のrelease directoryが存在すると再コピーされません。不変releaseのファイルを直接編集しないでください。

1. `current/verified/previous`、mode、config、plan、起動中unitをprivateに記録し、[復旧先の互換性](rollback.md)と管理経路を確認します。
2. 作業時間を確保し、timer・event monitor・UDAPI pathの3監視を止め、実行中の通常・UDAPI reconcileが終了したことを確認します。installerとrelease切替にはreconcile共通lockによる排他はありません。手動CLIやUniFiの設定保存も並行実行しません。
3. 新release名を指定して配置・有効化します。例の名前は命名形式の例であり、公開releaseの存在を意味しません。

```sh
UNIFI_JPIX_INSTALL_VERSION=v2.0.0-dev.REVIEWED-ID ./scripts/install-v2.sh --activate
```

4. 選択されたrelease・verified・監視3unitの再開を確認し、runbookの疎通試験を行います。失敗した場合は自動で全状態が戻ったと判断せず、復旧先での再収束と監視再開を確認します。

installerは追加の`unifi-jpix*` automationを検査し、稼働中・起動予定・状態不明なら配置前に拒否します。自作の復旧timerも対象になり得るので、このnamespaceを流用しないでください。`conflicting-automation`を回避するために、用途未確認のunitを停止・削除しないでください。

## 署名付きreleaseへの更新

このcheckoutには配布用公開鍵を内包していません。確認済みの公開鍵はsource installerの`--release-public-key FILE`で登録できますが、同時に通常の配置処理も走ります。稼働中なら上記の更新手順を適用してください。既存keyの暗黙置換は拒否します。

公開済みの対象versionとtrust anchorを確認した場合だけ、`unifi-jpix upgrade --release VERSION`を実行します。必要な配布物は`VERSION.tar.gz`、`VERSION.sha256`、`VERSION.sha256.sig`です。無人自己更新はありません。署名・checksum・manifestの関係と失敗時の限界は[Architecture](architecture.md#releaseの検証)と[Rollback](rollback.md)を参照してください。
