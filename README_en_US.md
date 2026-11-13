[中文](/README.md) | [English](/README_en_US.md) | [日本語](/README_ja_JP.md) | [Русский](/README_ru_RU.md) 

# Caesar's Mihomo Installation & Management Toolkit (Install-Mihomo-Inbounds)

This is a powerful, highly modular, and extremely compatible collection of Mihomo node installation and management scripts. It uses Mihomo (Meta Kernel) instead of Xray as the proxy server core to solve the TCP connection leak issue present in Xray. It supports the perfect co-deployment of multiple mainstream protocols (VLESS-Reality, VLESS Encryption, Shadowsocks 2022, etc.) on a single server, and provides convenient configuration backup, routing management, and Geo data update features.

## ✨ Core Features

  * **Mihomo Core**: Utilizes Mihomo (Clash Meta) as the proxy server, resolving Xray's TCP connection leak bug. It features lower resource consumption and stronger stability. It also supports automated fallback to the `amd64-compatible` instruction set architecture for older CPUs.
  * **Post-Quantum Encryption Support**: Seamlessly supports the VLESS Encryption (ML-KEM-768, Post-Quantum) feature pioneered by Xray, providing highly compatible automatic key conversion and generation.
  * **Smart Multi-Protocol Coexistence**: Appends listeners to an existing YAML configuration, so multiple protocols or ports can be used on one server.
  * **Extreme System Compatibility**: Not only does it perfectly support mainstream Systemd-based distributions like Debian/Ubuntu, but it is also **deeply compatible with Alpine Linux (OpenRC)**, making it exceptionally friendly to ultra-minimalist lightweight systems.
  * **NAT / DDNS Friendly**: Built-in feature to customize independent connection addresses. Whether you are using a NAT machine with dynamic ports or resolving via a DDNS domain name, you can generate the correct sharing links with one click.
  * **All-in-One Management**: Provides a unified global management menu (`mihomo-manager`), a routing configuration tool (`mihomo-routing`), and a configuration backup/restore tool (`mihomo-restore`).
  * **Secure Precision Deletion**: Supports precise identification and deletion of specific node configurations by port and protocol, ensuring innocent configurations are never accidentally damaged.

-----

## 🚀 Quick Start (Recommended)

If you want to experience the complete set of management features, it is recommended to directly install the **Unified Management Center (Mihomo Manager)**.

Execute the following command to download and launch the global management menu:

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_manager.sh -o mihomo_manager.sh && chmod +x mihomo_manager.sh && sudo ./mihomo_manager.sh
```

**💡 Pro Tip:**
After the unified management tool is installed, it will automatically register a global command. You can quickly wake up the main menu at any time by typing the following command in your terminal:

```bash
mihomo-manager
```

Within the `mihomo-manager` menu, you can invoke the main features without downloading each script individually. Snell and DNAT forwarding can also be run separately. If a datacenter firewall blocks Snell v6, use the v4/v5 script; the two installs can run side by side.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_snell.sh -o install_snell.sh && chmod +x install_snell.sh && sudo ./install_snell.sh
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_snell_legacy.sh -o install_snell_legacy.sh && chmod +x install_snell_legacy.sh && sudo ./install_snell_legacy.sh
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_dnat.sh -o install_dnat.sh && chmod +x install_dnat.sh && sudo ./install_dnat.sh
```

-----

## 📦 Independent Module Installation Guide

If you only want to use a specific feature of this project, you can use the following independent installation commands directly.

### 1\. VLESS Encryption (Post-Quantum) Node Management

Supports the latest generation ML-KEM-768 post-quantum encryption technology. Discards cumbersome configurations; secure connections can be established with just the handshake keys.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_vless_encryption.sh -o install_vless_encryption.sh && chmod +x install_vless_encryption.sh && sudo ./install_vless_encryption.sh
```

### 2\. VLESS-Reality (Vision) Node Management

Supports automatic generation of X25519 key pairs, uses `xtls-rprx-vision` flow control by default, and connects via Mihomo's listeners.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_vless_reality.sh -o install_vless_reality.sh && chmod +x install_vless_reality.sh && sudo ./install_vless_reality.sh
```

### 3\. Shadowsocks 2022 & Traditional SS Node Management

Supports blazing-fast next-generation encryption protocols like 2022-blake3-aes, maintains backward compatibility with traditional aes-gcm encryption, and automatically generates strong random passwords.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_ss2022.sh -o install_ss2022.sh && chmod +x install_ss2022.sh && sudo ./install_ss2022.sh
```

### 4\. AnyTLS (JLS Handshake Camouflage) Node Management

Uses Mihomo's `anytls` listener to serve AnyTLS, defaulting to JLS: connections that fail JLS authentication are relayed verbatim to a fallback destination (default `www.bing.com:443`), and the handshake is carried by a throwaway certificate the core generates itself — **no certificate of your own is needed**. A native TLS mode with your own certificate is also available.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_anytls.sh -o install_anytls.sh && chmod +x install_anytls.sh && sudo ./install_anytls.sh
```

> **Core requirement**: JLS support landed in mihomo **v1.19.29** (`feat: support jls for anytls outbound and listener`). The script checks the version and refuses to install on older cores rather than writing a config that silently fails.
>
> **Note**: The AnyTLS URI scheme defines only `sni` and `insecure`, so it cannot carry JLS credentials. The script therefore prints a **`proxies:` snippet** instead of a share link; import it manually on a client that runs mihomo >= 1.19.29 (Clash Party and FlClash already expose `jls-opts` in their forms).

### TUIC v5 Node Management

Adds a Mihomo `tuic` listener to the same `config.yaml` used by VLESS, Shadowsocks, and AnyTLS, so routing, backup/restore, and uninstall keep working. The default certificate is self-signed; an existing PEM pair or an acme.sh HTTP-01 certificate can be used instead. Traffic is QUIC, so the firewall must allow **UDP**.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_tuic.sh -o install_tuic.sh && chmod +x install_tuic.sh && sudo ./install_tuic.sh
```

Non-interactive install (port 443, BBR, ALPN h3, self-signed certificate):

```bash
sudo ./install_tuic.sh install --port 443 --congestion bbr
```

> **Clients**: The script prints a Surge `tuic-v5` line, a `tuic://` share link, and a Mihomo YAML snippet. Self-signed certificates include `skip-cert-verify` / `allow_insecure=1`. `udp-relay-mode` is a client setting and defaults to `native`.
>
> **Certificates**: `selfsign` is generated by the script. `file` copies an existing PEM into `/usr/local/etc/mihomo/certs/` because the core only reads certificates inside its home directory. `acme` runs acme.sh HTTP-01 and needs the domain pointed at this host with TCP/80 free.
>
> **Ports**: Conflict detection looks at UDP listeners and existing listeners, not only TCP.

### Snell v4/v5 Server (coexists with v6)

`install_snell.sh` installs Snell **v6**. Some datacenter firewalls block that traffic shape. `install_snell_legacy.sh` installs the official **v4.1.1 / v5.0.1** builds instead (v5 is the default). The binary, config directory, and service name are all separate, so both stacks can run on one machine, and uninstalling one does not touch the other.

| | v6 `install_snell.sh` | v4/v5 `install_snell_legacy.sh` |
|---|---|---|
| Binary | `/usr/local/bin/snell-server` | `/usr/local/bin/snell-server-legacy` |
| Config | `/usr/local/etc/snell/` | `/usr/local/etc/snell-legacy/` |
| systemd | `snell@<port>` | `snell-legacy@<port>` |
| OpenRC | `/etc/init.d/snell.<port>` | `/etc/init.d/snell-legacy.<port>` |

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_snell_legacy.sh -o install_snell_legacy.sh && chmod +x install_snell_legacy.sh && sudo ./install_snell_legacy.sh
```

Non-interactive install (protocol defaults to v5, port defaults to 6160; the script refuses the port when v6 already owns it):

```bash
sudo ./install_snell_legacy.sh install --protocol 5 --port 6161
```

> **Versions**: There is no `latest` shortcut. The script pins the newest builds listed in the [Snell release notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell): `v4.1.1` and `v5.0.1`. Archives look like `https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip`.
>
> **Config**: v4/v5 accept a single `listen` address. `obfs` is written only when set to `http` (that is the only value v4.1.1 and v5.0.1 actually enable). `dns` has been supported since v4.1.0 and must be a list of IPs. `egress-interface` is written only for v5. v6-only keys (`mode`, `dns-ip-preference`) are never written. The log level defaults to `warning`.
>
> **Clients**: After install the script prints a Surge proxy line (`snell, ..., version=4` or `version=5`) and a Mihomo YAML snippet. v5 also binds UDP on the same port for QUIC Proxy, so the firewall has to allow UDP. A client can stay on `version=4`; a v5 server still accepts v4 clients.
>
> **Uninstall**: Menu item 4 removes only this stack. It does not touch v6, and it does not remove the shared `/root/inbound_address.txt`. `uninstall_mihomo.sh` leaves both Snell stacks alone.

### 5\. Realm Port Forwarding (standalone service)

Installs [realm](https://github.com/zhboner/realm) for pure TCP/UDP port forwarding, running **alongside** Mihomo: its own binary (`/usr/local/bin/realm`), config dir (`/usr/local/etc/realm/`) and systemd/OpenRC unit, so the two never interfere. The usual case is forwarding a relay machine's port to a Mihomo node port on the landing machine.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_realm.sh -o install_realm.sh && chmod +x install_realm.sh && sudo ./install_realm.sh
```

> **Note**: realm is pure port forwarding and produces no importable node link. Clients keep the original protocol and credentials; only the server address becomes the relay's `IP:port`.
>
> **Why it is not folded into the uninstaller**: `install_realm.sh` has its own uninstall entry (menu 4), and `uninstall_mihomo.sh` never touches realm's files, so uninstalling Mihomo cannot silently take the forwarding with it.

### 6\. Server Routing Tool (Mihomo Routing)

A control panel for server outbound routing. It supports SS links and common TCP, WebSocket, and gRPC VLESS links, and allows visual configuration of routing rules.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_routing.sh -o mihomo_routing.sh && chmod +x mihomo_routing.sh && sudo ./mihomo_routing.sh
```

*Can be launched at any time after installation using the `mihomo-routing` command.*

### 7\. Backup and Restore Tool (Mihomo Restore)

Import a `config.yaml` from a direct URL or by pasting it into the console, or restore a local uninstall backup archive. New archives include client information alongside the configuration; older archives can still restore the files they contain.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_restore.sh -o mihomo_restore.sh && chmod +x mihomo_restore.sh && sudo ./mihomo_restore.sh
```

*Can be launched at any time after installation using the `mihomo-restore` command.*

### 8\. Complete Uninstallation Tool

If you encounter unresolvable critical issues or simply want to clean your server completely, you can use this script. It cleanly wipes system services (Systemd/OpenRC), binaries, logs, and residual configurations.

```bash
curl -L https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/uninstall_mihomo.sh -o uninstall_mihomo.sh && chmod +x uninstall_mihomo.sh && sudo ./uninstall_mihomo.sh
```

-----

## 🔄 Mapping to Xray Versions

| Xray Script | Mihomo Script | Function |
|---|---|---|
| `install_vless_encryption.sh` | `install_vless_encryption.sh` | VLESS Encryption (PQ) Node Mgmt |
| `install_vless_reality.sh` | `install_vless_reality.sh` | VLESS-Reality Node Mgmt |
| `install_ss2022.sh` | `install_ss2022.sh` | Shadowsocks 2022 Node Mgmt |
| `——` | `install_anytls.sh` | AnyTLS (JLS) Node Mgmt |
| `——` | `install_tuic.sh` | TUIC v5 Node Mgmt (Mihomo inbound) |
| `——` | `install_snell.sh` | Snell v6 Server |
| `——` | `install_snell_legacy.sh` | Snell v4/v5 Server (coexists with v6) |
| `——` | `install_realm.sh` | Realm Port Forwarding |
| `xray_manager.sh` | `mihomo_manager.sh` | Unified Management Menu |
| `xray_routing.sh` | `mihomo_routing.sh` | Server Routing Config |
| `xray_restore.sh` | `mihomo_restore.sh` | Config Backup & Restore |
| `uninstall_xray.sh` | `uninstall_mihomo.sh` | Complete Uninstallation |
| `update_geo.sh` | `update_geo.sh` | Geo Data Update |

> **Note**: Mihomo now fully supports the new features of VLESS, including Reality and the ML-KEM-768 based Encryption protocol. All components in this toolkit can function normally under this framework.

-----

## 🛠️ Frequently Asked Questions (FAQ)

**Q: Why migrate from Xray to Mihomo?**

**A:** The Xray proxy server suffers from a severe TCP connection leak bug. Mihomo (Meta Kernel) does not have this issue and performs better in terms of resource consumption and stability, making it especially suitable for high-concurrency commercial environments or shared instances.

**Q: My server is a NAT VPS, or my ingress IP is different from my egress IP. What should I do if the generated nodes don't connect?**

**A:** Please select the **"Set Connection Address (NAT/DDNS)"** option in any of the installation menus. Enter the IP address or DDNS domain name you actually use for external connections.

**Q: My older E5 processor cannot install the new version and reports that the v3 architecture is not supported. What should I do?**

**A:** The installation scripts in this repository have been smartly optimized for CPU architecture recognition. For older hardware lacking AVX2 instruction set support (like some E5 v2 and Atom processors), the script will automatically pull the `amd64-compatible` kernel to prevent installation failures.

**Q: How do I view Mihomo's running logs?**

**A:** There is a **"View Logs"** option in the menus of all installation and management scripts. Selecting it allows you to view real-time operation logs. Press `Ctrl + C` to stop.

**Q: How do I update the GeoIP and GeoSite routing rule files?**

**A:** Use the one-click automated cron job setup feature within `mihomo-routing` (Server Routing Tool), which will update them automatically every morning. You can also manually trigger an immediate update from the main management tool (`mihomo-manager`).

**Q: Where is the Mihomo configuration file located?**

**A:** The configuration file is located at `/usr/local/etc/mihomo/config.yaml`. Mihomo uses the YAML format rather than Xray's JSON format.
