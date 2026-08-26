# Architecture

## Purpose

UniFi OS が管理する IPv6 接続を維持しながら、JPIX v6プラス固定IPに必要な IPv4 over IPv6 の状態を補正します。UniFiの設定DBは直接編集せず、Linuxのトンネル、ルート、policy rule、netfilterへ限定した変更を行います。

## Data flow

1. WANのIPv6経路からBR到達時のsource addressを取得します。
2. 契約で指定されたinterface identifierと組み合わせ、ローカルトンネルendpointを導出します。
3. UniFiが作成したBR一致トンネルを固定IPv4用に補正します。
4. 設定されたLANだけを専用route tableへ送り、固定IPv4でSNATします。
5. endpoint変更時は状態を再適用し、必要な場合だけ更新サーバーへ通知します。

## Trust boundaries

- `/data/unifi-jpix-tunnel-repair/scripts`: root所有、非root書き込み不可、symlink不可
- `/data/unifi-jpix-tunnel-repair/config`: root所有、directoryは非root書き込み不可、各設定はmode `0600`
- `/data/unifi-jpix-tunnel-repair/state`: root所有、mode `0700`
- 更新通信: HTTPSが既定。HTTPは明示的な例外設定と完全一致hostが必要
- 診断: stdoutは共有用。完全出力は新規mode `0600` fileだけ

## What this project does not manage

- UniFiのWAN、LAN、VLAN、DHCPv6-PD設定
- ONUやホームゲートウェイの設定
- DNSフィルタリングや広告ブロック
- ISP契約情報、BR、固定IPの自動検出
