# UDM Pro 導入・移行runbook

この文書は、初めてこのrepositoryを見る人が、管理PCからUDM Proへファイルを渡し、JPIX「v6プラス」固定IPサービスの1 IP品目を手動検証するための一本道の手順です。現在の方式は、UniFi管理トンネルを共有して補正するexperimental repairです。再起動、UniFi reprovision、prefix変更、project-owned独立トンネルとの比較が未完了なので、最後までautomationを有効化しないでください。

## 0. ここで止まる条件

次のどれかに当てはまる場合は変更を始めません。

- 契約が通常のMAP-E「v6プラス」、複数固定IPv4、HB46PP、他VNEである。
- UDM Pro以外、または`config/verified-platforms.conf`にないplatform tupleである。
- preflightが`RESULT=ready-for-config`ではない。
- UniFi user hookまたは親chainからの一意なjumpを確認できない。
- delegated LAN `/64`を持つLAN bridgeを`ENDPOINT_IF`として一つに決められない。
- 対象LANのRFC1918 CIDRとconnected routeが完全一致しない、または対象LAN同士がoverlapする。
- local consoleまたは別管理経路と、時間指定の自動復旧を準備できない。
- 旧実装との競合を解消できない。

完全address、prefix、interface名、config、state、credential、完全診断はUDM内だけで扱います。GitHub Issueへ共有できるのはshare-safe出力だけです。

## 1. 管理PCでcommitを固定する

UDMには`git`がない前提です。検証済み管理PCでcommitと作業treeを確認し、そのcommitだけをarchiveにします。

```sh
git status --short --branch
git log -1 --oneline
git diff --check
commit=$(git rev-parse HEAD)
git archive --format=tar.gz --output "unifi-jpix-tunnel-repair-${commit}.tar.gz" "$commit"
shasum -a 256 "unifi-jpix-tunnel-repair-${commit}.tar.gz" >"unifi-jpix-tunnel-repair-${commit}.tar.gz.sha256"
```

未commit差分は`git archive`へ入りません。実行予定の差分がある場合は、reviewとtestを終えたcommitを作ってからやり直します。

## 2. archiveをUDMへ転送する

管理PCからSCPで一時配置します。`<UDM管理IP>`は実値へ置換しますが、command logやIssueへ貼りません。

```sh
scp "unifi-jpix-tunnel-repair-${commit}.tar.gz" \
  "unifi-jpix-tunnel-repair-${commit}.tar.gz.sha256" \
  'root@<UDM管理IP>:/data/'
```

UDM側で管理PCの表示値と照合します。macOSの`shasum -a 256`とUDMの`sha256sum`は同じSHA-256値を返す必要があります。

```sh
cd /data
sha256sum "unifi-jpix-tunnel-repair-${commit}.tar.gz"
install -d -m 700 /data/unifi-jpix-staging
tar -xzf "unifi-jpix-tunnel-repair-${commit}.tar.gz" -C /data/unifi-jpix-staging
```

値が一致しなければ削除や実行をせず、転送からやり直します。

## 3. 変更前baselineと競合を確認する

まずread-only preflightを実行します。

```sh
/data/unifi-jpix-staging/scripts/unifi-jpix-tunnel-repair-preflight.sh
```

次がすべて必要です。

- `PLATFORM_COMPATIBILITY=verified`
- `XTABLES_BACKEND=legacy`
- `UNIFI_NAT_PARENT_JUMP=present`
- `UNIFI_IPV6_INPUT_PARENT_JUMP=present`
- `RESULT=ready-for-config`

次に旧実装を探します。表示には実configを含めません。

```sh
systemctl list-unit-files 'v6plus*' 'unifi-jpix-tunnel-repair*'
systemctl list-units --all 'v6plus*' 'unifi-jpix-tunnel-repair*'
```

旧実装がある場合は、旧apply/off command、unit名、config directory、state directoryを実機内のprivate worksheetへ記録します。新旧を同時に起動すると、同じtunnel、route、policy rule、SNAT、provider通知を競合管理するため禁止です。

変更前に、同じ端末とLANで次をprivateに保存します。

1. 対象LANのIPv4、IPv6、DNS、JPIX接続判定。
2. 対象外LANのIPv4出口、IPv6、DNS。
3. 旧実装の`status`とactive/enabled状態。

## 4. 旧実装をroot-only backupへ保存する

実機で確認した正確なpathだけをbackup対象にします。credentialを画面表示する`cat`や`set -x`を使いません。

```sh
install -d -m 700 /data/unifi-jpix-migration-backup
install -m 600 /dev/null /data/unifi-jpix-migration-backup/legacy-backup-files.list
vi /data/unifi-jpix-migration-backup/legacy-backup-files.list
tar -czf /data/unifi-jpix-migration-backup/legacy-private.tar.gz \
  --files-from /data/unifi-jpix-migration-backup/legacy-backup-files.list
chmod 600 /data/unifi-jpix-migration-backup/legacy-private.tar.gz
```

listには確認済みの旧directoryと旧unit fileの絶対pathだけを書きます。`/etc/systemd/system`全体のような広い対象を指定しません。backupはcredentialを含む可能性があるためUDM外へ無暗にコピーしません。

## 5. timed recoveryを予約する

local consoleまたは別管理経路を確保し、復旧scriptをmode `0700`で用意します。scriptは次の順で処理します。

1. 新automationを停止する。
2. 新実装の`off`を試みる。
3. 実機で確認した旧apply commandを実行する。
4. 元からactiveだった旧unitだけをstartする。

旧pathとunit名は実機のinventoryから転記し、credentialそのものはscriptへ書きません。手動でscriptを構文確認した後、5分後の一回限りの復旧を予約します。

```sh
chmod 700 /data/unifi-jpix-migration-backup/migration-recovery.sh
systemd-run --unit=unifi-jpix-migration-recovery \
  --on-active=5m \
  /data/unifi-jpix-migration-backup/migration-recovery.sh
systemctl status unifi-jpix-migration-recovery.timer --no-pager
```

timerがactiveでない場合は変更を始めません。5分で不足する場合は、作業時間を推測して延ばすのではなく、各段階を分けて毎回予約し直します。

## 6. 新実装をinert installする

```sh
/data/unifi-jpix-staging/scripts/install.sh
systemctl daemon-reload
```

installerはscript、static platform matrix、example、unitを配置しますが、実config作成、service enable/start、network変更は行いません。

## 7. `ENDPOINT_IF`とトンネル候補をread-only discoveryする

`ENDPOINT_IF`は、契約IIDを載せるdelegated LAN `/64`のkernel routeを持つLAN bridgeです。WANや非bridge interfaceは指定できません。WANのIA_NA sourceやBR route sourceと同じprefixである必要はありません。bridgeにglobal `/64` addressが直接付いていなくても、`proto kernel`のglobal `/64` routeが一意なら候補になります。

実機内でUniFi LAN設定とkernel routeを照合し、対象interfaceにglobal `/64`が一つだけあることを確認します。完全prefixは共有しません。

最初の`gateway.conf`には`BR_V6`、`IID`、`ENDPOINT_IF`の3 keyだけを実値で用意します。exampleには未確定の`TUN_IF`などが入るため、discovery前はexampleをそのままコピーしません。fileはroot所有mode `0600`にします。

```sh
install -m 600 /dev/null /data/unifi-jpix-tunnel-repair/config/gateway.conf
vi /data/unifi-jpix-tunnel-repair/config/gateway.conf
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh \
  --config /data/unifi-jpix-tunnel-repair/config \
  --discover \
  --full-output /data/unifi-jpix-tunnel-repair/state/discovery.txt
```

share-safe stdoutが`RESULT=ready`で、root-only full outputに次が一意に現れることを確認します。

- BR routeから得たWAN候補。
- BR remoteと一致する既存UniFi IPIP6 tunnel候補。
- `ENDPOINT_PREFIX_STATUS=unique`。
- 契約IIDから合成されたlocal endpoint。

0件または複数件なら推測で選ばず停止します。`--discover`は既存トンネルを変更しません。

## 8. 完全configを作る

[Configuration](configuration.md)のworksheetに沿って、3 configを完成させます。特に次を確認します。

- `WAN_IF`: BR routeのunderlay device。
- `TUN_IF`: discoveryで一意だったUniFi管理トンネル。
- `ENDPOINT_IF`: delegated `/64`の一意なkernel routeを持つLAN bridge。
- `TUN_MTU + 40 <= underlay MTU`。
- `TCP_MSS <= TUN_MTU - 40`。
- routed networkはRFC1918のcanonical CIDRで、interfaceのconnected routeと完全一致し、相互にoverlapしない。
- policy rule用tableとpriority範囲が空いている。
- provider URLと再設定credentialは契約通知の値で、UniFi API keyやSSH credentialではない。

旧configから移行する場合も、credentialをstdoutへ出さず、root-only editorで新schemaへ転記します。旧schemaのroute sourceを`ENDPOINT_IF`の代わりに流用しません。

## 9. 診断とdry-runを合格させる

```sh
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-diag.sh \
  --full-output /data/unifi-jpix-tunnel-repair/state/pre-apply-diagnostic.txt
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh --dry-run apply
```

次へ進めるのは、share-safe診断が`RESULT=ready`、dry-runがexit `0`、完全診断のplatform、hook、endpoint、tunnel、MTU、reserved table/ruleに説明不能な差分がない場合だけです。

## 10. 旧automationを止め、新実装を手動applyする

timed recoveryがactiveであることを再確認します。次に、実機で確認した旧unitをstopし、旧実装のoffでUniFi管理状態へ戻します。unit名を推測しません。

```sh
OLD_TRIGGER='replace-with-confirmed-old-trigger-unit'
OLD_WATCH='replace-with-confirmed-old-watch-unit'
OLD_UPDATE_TIMER='replace-with-confirmed-old-update-timer-unit'
OLD_APPLY='replace-with-confirmed-absolute-old-apply-path'
systemctl stop "$OLD_TRIGGER" "$OLD_WATCH" "$OLD_UPDATE_TIMER"
"$OLD_APPLY" off
```

続けて新実装を手動適用します。

```sh
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh apply
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh status
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-update.sh --force
```

`apply`後のprovider通知を省略しません。通知は現在のCPE側IPv6 endpointをproviderへ登録する別段階であり、`status`成功だけでは代替できません。

## 11. 通信を同じ順序で検証する

1. 管理SSHまたはconsoleが維持されている。
2. 対象LANのDNS、IPv4、native IPv6が成功する。
3. 対象LANの外向きIPv4が契約固定IPv4と一致する。
4. 対象外LANのIPv4出口、IPv6、DNS、既存policyがbaselineと同じである。
5. JPIX接続判定で契約方式と地域に合う試験が成功する。
6. `status`を再実行してdriftがない。
7. provider通知stateが成功時だけ更新され、credentialやresponse bodyがjournalへ出ていない。

一つでも失敗したらtimerを待つか、別管理経路から復旧scriptを手動実行します。同じ状態でapplyを繰り返しません。

## 12. rollbackを実測してから再applyする

新実装の復旧可能性を確認します。

```sh
/data/unifi-jpix-tunnel-repair/scripts/unifi-jpix-tunnel-repair-apply.sh off
```

保存したoriginal tunnel、旧IPv4経路、native IPv6、対象外LANが戻ったことを確認します。その後、旧実装を再applyしてbaselineを確認し、再び旧実装をoffにしてから新実装を手動apply、`status`、provider `--force`、通信検証まで繰り返します。

成功後だけtimed recoveryを解除します。

```sh
systemctl stop unifi-jpix-migration-recovery.timer
systemctl reset-failed unifi-jpix-migration-recovery.service
```

## 13. 現在はautomationを有効化しない

手動apply、手動rollback、再applyが成功しても、次は別の承認・検証境界です。

- UDM再起動後の順序と復帰。
- UniFi Network reprovision後の共有トンネル所有権。
- DHCPv6-PD prefix変更時のendpoint追従とprovider再通知。
- UniFi管理トンネル方式とproject-owned独立トンネル方式の比較。

これらが未完了の間は、trigger、watch、update timerをdisabled/inactiveのままにします。

```sh
systemctl disable unifi-jpix-tunnel-repair-trigger.service \
  unifi-jpix-tunnel-repair-watch.service \
  unifi-jpix-tunnel-repair-update.timer
systemctl stop unifi-jpix-tunnel-repair-trigger.service \
  unifi-jpix-tunnel-repair-watch.service \
  unifi-jpix-tunnel-repair-update.timer \
  unifi-jpix-tunnel-repair-update.service
```

share-safeな合否、未実施gate、正確なcommitだけを[Issue #2](https://github.com/shuuheyhey/unifi-jpix-tunnel-repair/issues/2)へ記録します。
