[中文](/README.md) | [English](/README_en_US.md) | [日本語](/README_ja_JP.md) | [Русский](/README_ru_RU.md)

# Caesar 蜜汁 Mihomo 一键安装与管理工具箱 (Install-Mihomo-Inbounds)

使用 Mihomo (Meta Kernel) 作为代理服务端核心，避免 Xray 的 TCP 连接数泄露问题，资源占用低、高并发稳定。支持在一台服务器上共存部署全部 17 种主流 Mihomo 入站协议（VLESS-Reality、VLESS Encryption 抗量子、Shadowsocks 2022、AnyTLS、TUIC v5、Hysteria2、Trojan、VMess、ShadowQUIC、Mieru、Sudoku、TrustTunnel 等），并提供分流管理、备份还原及独立转发/Snell 服务工具。

## ✨ 核心特性

* **单脚本全协议合一 (`install_mihomo.sh`)**：交互菜单自选任意协议安装，也支持命令行参数一键部署，跨协议统一查看、修改、删除已装节点。
* **多协议智能共存**：向同一份 `/usr/local/etc/mihomo/config.yaml` 原子追加 `listeners`，校验或监听失败自动回滚，绝不覆盖已有配置。
* **老旧 CPU 与精简系统友好**：`x86_64` 默认选用 `amd64-compatible` 兼容老 CPU；完整适配 **Debian / Ubuntu (systemd)** 与 **Alpine Linux (OpenRC)**。
* **NAT / DDNS 友好**：内置外部连接地址设置 (`/root/inbound_address.txt`)，所有脚本共享并在卸载时保留。

---

## 🚀 快速开始

### 方式 1：全局工具箱菜单 (`mihomo_manager.sh`)

统一下载并唤起 Mihomo 入站、分流、还原、卸载以及 Realm / DNAT / Snell 等全部模块：

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_manager.sh -o mihomo_manager.sh && chmod +x mihomo_manager.sh && sudo ./mihomo_manager.sh
```

安装后随时输入 `mihomo-manager` 即可唤起主菜单。

### 方式 2：Mihomo 全协议入站脚本 (`install_mihomo.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_mihomo.sh -o install_mihomo.sh && chmod +x install_mihomo.sh && sudo ./install_mihomo.sh
```

运行后自动注册快捷命令 `mihomo-inbounds`。支持以下三种用法：

```bash
# 1) 交互式管理面板（自选 1-17 任意协议安装，跨协议查看/修改/删除节点）
sudo ./install_mihomo.sh

# 2) 指定协议名（无额外参数）：直接进入该协议的互动安装向导
sudo ./install_mihomo.sh reality
sudo ./install_mihomo.sh anytls

# 3) 带启动参数（或加 -y）：全自动非交互一键安装（加 -q 仅在 stdout 输出链接/配置）
sudo ./install_mihomo.sh reality -y -q
sudo ./install_mihomo.sh reality --port 443 --sni hk.art.museum --address my.ddns.net
sudo ./install_mihomo.sh ss --port 2022 --method 2022-blake3-aes-256-gcm -q
sudo ./install_mihomo.sh vless-enc --port 40000 -y
sudo ./install_mihomo.sh anytls --port 8443 --dest www.bing.com:443 -q
sudo ./install_mihomo.sh tuic --port 443 --congestion bbr
sudo ./install_mihomo.sh hysteria2 --port 443 --obfs salamander
sudo ./install_mihomo.sh trojan --port 443 --ws-path /ws
sudo ./install_mihomo.sh vmess --port 16823 --security tls
sudo ./install_mihomo.sh shadowquic --port 443 --dest www.bing.com:443
sudo ./install_mihomo.sh mieru --port 2999 --transport TCP
sudo ./install_mihomo.sh sudoku --port 443 -y
sudo ./install_mihomo.sh trusttunnel --port 443 --congestion bbr
sudo ./install_mihomo.sh http --port 8080 -y
sudo ./install_mihomo.sh socks --port 1080 -y
sudo ./install_mihomo.sh mixed --port 10810 -y
sudo ./install_mihomo.sh tunnel --port 10816 --target 10.0.0.2:443
sudo ./install_mihomo.sh hy2-realm --port 2080 -y
```

常用管理子命令：

```bash
sudo ./install_mihomo.sh <协议> --help       # 查看该协议专属参数说明
sudo ./install_mihomo.sh list                # 列出全部已装 Mihomo 入站节点
sudo ./install_mihomo.sh info [端口] [-q]    # 查看节点分享链接与客户端配置
sudo ./install_mihomo.sh delete <端口> [-y]  # 按端口精准删除节点
sudo ./install_mihomo.sh address my.ddns.net # 设置 NAT/DDNS 连接地址（auto 恢复自动获取）
sudo ./install_mihomo.sh update              # 更新 Mihomo 核心与 Geo 数据
sudo ./install_mihomo.sh uninstall [-y]      # 打包备份并卸载 Mihomo
```

---

## 📋 支持的 17 种 Mihomo 入站协议

| 启动标识 | Mihomo Listener | 默认端口 | 说明 |
|---|---|---|---|
| `reality` | `vless` | 443/TCP | Vision 流控 + Reality X25519 伪装，免自备证书 |
| `ss` | `shadowsocks` | 2022/TCP+UDP | 支持 `2022-blake3-*` 与传统 AEAD |
| `vless-enc` | `vless` | 40000/TCP | ML-KEM-768 抗量子加密，自动生成密钥串 |
| `anytls` | `anytls` | 8443/TCP | 默认 JLS 握手伪装免证书，也支持 TLS（需 mihomo >= 1.19.29） |
| `tuic` | `tuic` | 443/UDP | TUIC v5，支持自签/文件/ACME，输出 Surge + URI + Mihomo |
| `hysteria2` (`hy2`) | `hysteria2` | 443/UDP | 默认 BBR，可选 `salamander` 混淆 |
| `trojan` | `trojan` | 443/TCP | 支持 TCP / WebSocket over TLS（需 mihomo >= 1.19.3） |
| `vmess` | `vmess` | 16823/TCP | `alterId=0`，可选明文或 TLS、TCP 或 WebSocket |
| `shadowquic` | `shadowquic` | 443/UDP | QUIC + JLS 伪装（需 mihomo >= 1.19.29） |
| `mieru` | `mieru` | 2999/TCP\|UDP | 可选 TCP 或 UDP 传输（需 mihomo >= 1.19.17） |
| `sudoku` | `sudoku` | 443/TCP | 共享 UUID 密钥与字节表混淆（需 mihomo >= 1.19.17） |
| `trusttunnel` | `trusttunnel` | 443/TCP+UDP | 同时提供 HTTP/2 与 HTTP/3（需 mihomo >= 1.19.25） |
| `http` | `http` | 8080/TCP | 强制账密认证，避免写成开放代理 |
| `socks` | `socks` | 1080/TCP+UDP | 带认证 SOCKS5（开启 UDP） |
| `mixed` | `mixed` | 10810/TCP+UDP | 同端口同时接受 HTTP 与 SOCKS5 |
| `tunnel` | `tunnel` | 10816/TCP+UDP | Mihomo 内部端口转发（非代理节点，需 `--target`） |
| `hy2-realm` | `hysteria2-realm` | 2080/TCP | Hysteria2 `realm-opts` 汇合服务（需 mihomo >= 1.19.25） |

---

## 📦 其他配套与独立服务脚本

| 脚本 | 快捷命令 | 说明 |
|---|---|---|
| `mihomo_routing.sh` | `mihomo-routing` | 服务端出站代理添加（Socks5/SS/VLESS）与 `IN-NAME`/Geo 分流配置 |
| `mihomo_restore.sh` | `mihomo-restore` | 从 URL、手动粘贴或 `.tar.gz` 备份归档恢复配置并校验 |
| `update_geo.sh` | —— | 原子更新 `geoip.metadb` 与 `geosite.dat`，按需重启运行中的 Mihomo |
| `uninstall_mihomo.sh` | —— | 备份配置与客户端状态后彻底卸载 Mihomo（支持 `--yes`、`--purge`） |
| `install_realm.sh` | —— | 独立 `realm` TCP/UDP 端口转发服务（卸载 Mihomo 时不受影响） |
| `install_dnat.sh` | `mihomo-dnat` | 基于 `iptables` / `nftables` 的内核级双栈 DNAT 转发（开机自动恢复） |
| `install_snell.sh` | —— | Surge 官方 `snell-server` **v6** 独立服务（每端口独立实例） |
| `install_snell_legacy.sh` | —— | Surge 官方 `snell-server` **v4.1.1 / v5.0.1** 独立服务（与 v6 共存） |
