[中文](/README.md) | [English](/README_en_US.md) | [日本語](/README_ja_JP.md) | [Русский](/README_ru_RU.md)

# Caesar 特製 Mihomo ワンクリックインストール＆管理ツールボックス (Install-Mihomo-Inbounds)

Xray の TCP コネクションリーク問題を解消するため Mihomo (Meta Kernel) を採用したサーバー構築・管理ツール群です。単一スクリプト `install_mihomo.sh` で **全 17 種類の Mihomo インバウンドプロトコル**（VLESS-Reality、VLESS Encryption 耐量子、Shadowsocks 2022、AnyTLS、TUIC v5、Hysteria2、Trojan、VMess、ShadowQUIC、Mieru、Sudoku、TrustTunnel、HTTP/SOCKS/Mixed、Tunnel、Hy2-Realm）の対話型導入・CLI ワンクリック構築・一括管理に対応しています。

## 🚀 クイックスタート

### 1. 統合管理メニュー (`mihomo_manager.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_manager.sh -o mihomo_manager.sh && chmod +x mihomo_manager.sh && sudo ./mihomo_manager.sh
```

導入後は `mihomo-manager` でいつでも起動できます。

### 2. Mihomo 全プロトコル統合スクリプト (`install_mihomo.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_mihomo.sh -o install_mihomo.sh && chmod +x install_mihomo.sh && sudo ./install_mihomo.sh
```

```bash
# 対話型メインメニュー（全17プロトコル選択・確認・変更・削除）
sudo ./install_mihomo.sh

# プロトコル名のみ指定：そのプロトコルの対話ウィザードを直接起動
sudo ./install_mihomo.sh reality

# オプション付き（または -y）：非対話で即座に構築（-q でリンク/設定のみ stdout 出力）
sudo ./install_mihomo.sh reality -y -q
sudo ./install_mihomo.sh reality --port 443 --sni hk.art.museum --address my.ddns.net
sudo ./install_mihomo.sh ss --port 2022 --method 2022-blake3-aes-256-gcm -q
sudo ./install_mihomo.sh anytls --port 8443 --dest www.bing.com:443 -q
sudo ./install_mihomo.sh hysteria2 --port 443 --obfs salamander
sudo ./install_mihomo.sh <プロトコル> --help
```

## 📦 付属・独立サービススクリプト

* `mihomo_routing.sh` (`mihomo-routing`)：アウトバウンド追加・ルーティング設定
* `mihomo_restore.sh` (`mihomo-restore`)：設定のバックアップ復元・テスト
* `update_geo.sh` / `uninstall_mihomo.sh`：Geo 更新 / バックアップ付き完全削除
* `install_realm.sh` / `install_dnat.sh`：独立 Realm 転送 / カーネル DNAT 転送
* `install_snell.sh` / `install_snell_legacy.sh`：公式 Snell v6 / Snell v4・v5 共存スクリプト
