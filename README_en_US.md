[中文](/README.md) | [English](/README_en_US.md) | [日本語](/README_ja_JP.md) | [Русский](/README_ru_RU.md)

# Caesar's Mihomo Installation & Management Toolkit (Install-Mihomo-Inbounds)

Uses Mihomo (Meta Kernel) as the proxy server core to eliminate Xray's TCP connection leak issue with low overhead and high concurrency stability. Deploys and manages all **17 Mihomo inbound protocols** on a single server from one self-contained script (`install_mihomo.sh`), alongside routing, backup/restore, and standalone Realm / DNAT / Snell tools.

## 🚀 Quick Start

### Option 1: Global Toolbox Menu (`mihomo_manager.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_manager.sh -o mihomo_manager.sh && chmod +x mihomo_manager.sh && sudo ./mihomo_manager.sh
```

Once installed, run `mihomo-manager` anytime.

### Option 2: Unified Mihomo Inbound Script (`install_mihomo.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_mihomo.sh -o install_mihomo.sh && chmod +x install_mihomo.sh && sudo ./install_mihomo.sh
```

Registers `mihomo-inbounds` for interactive use and supports three execution modes:

```bash
# 1) Interactive management menu (pick any of the 17 protocols, view/modify/delete across all protocols)
sudo ./install_mihomo.sh

# 2) Protocol name only: jump straight into that protocol's interactive setup wizard
sudo ./install_mihomo.sh reality
sudo ./install_mihomo.sh anytls

# 3) Protocol + flags (or -y): unattended direct install (-q outputs only link/client config to stdout)
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

Management subcommands:

```bash
sudo ./install_mihomo.sh <proto> --help      # Protocol-specific CLI options
sudo ./install_mihomo.sh list                # List all installed Mihomo inbound nodes
sudo ./install_mihomo.sh info [port] [-q]    # Show share link / client YAML
sudo ./install_mihomo.sh delete <port> [-y]  # Delete a node by port
sudo ./install_mihomo.sh address my.ddns.net # Set NAT/DDNS connection address ('auto' resets)
sudo ./install_mihomo.sh update              # Update Mihomo binary & Geo databases
sudo ./install_mihomo.sh uninstall [-y]      # Backup config/state and uninstall Mihomo
```

## 📦 Companion & Standalone Scripts

| Script | Command | Purpose |
|---|---|---|
| `mihomo_routing.sh` | `mihomo-routing` | Outbound proxy & routing rule management (`IN-NAME`, GeoIP, GeoSite) |
| `mihomo_restore.sh` | `mihomo-restore` | Restore & validate config from URL, editor, or `.tar.gz` backup archive |
| `update_geo.sh` | —— | Atomic GeoIP/GeoSite updater |
| `uninstall_mihomo.sh` | —— | Full Mihomo uninstaller with automatic archive backup |
| `install_realm.sh` | —— | Standalone `realm` TCP/UDP port forwarder |
| `install_dnat.sh` | `mihomo-dnat` | Kernel `iptables`/`nftables` dual-stack DNAT port forwarder |
| `install_snell.sh` | —— | Standalone official Surge `snell-server` v6 |
| `install_snell_legacy.sh` | —— | Standalone official `snell-server` v4.1.1 / v5.0.1 (coexists with v6) |
