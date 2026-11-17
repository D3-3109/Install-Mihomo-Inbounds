[中文](/README.md) | [English](/README_en_US.md) | [日本語](/README_ja_JP.md) | [Русский](/README_ru_RU.md)

# Универсальный набор инструментов Mihomo (Install-Mihomo-Inbounds)

Серверный инструментарий на базе ядра Mihomo (Meta Kernel) без утечек TCP-соединений, характерных для Xray. Единый автономный скрипт `install_mihomo.sh` объединяет установку и управление **всеми 17 входящими протоколами Mihomo** (VLESS-Reality, VLESS Encryption ML-KEM-768, Shadowsocks 2022, AnyTLS, TUIC v5, Hysteria2, Trojan, VMess, ShadowQUIC, Mieru, Sudoku, TrustTunnel, HTTP/SOCKS/Mixed, Tunnel, Hy2-Realm) как через интерактивное меню, так и через аргументы командной строки.

## 🚀 Быстрый старт

### 1. Глобальное меню (`mihomo_manager.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/mihomo_manager.sh -o mihomo_manager.sh && chmod +x mihomo_manager.sh && sudo ./mihomo_manager.sh
```

После установки меню доступно по команде `mihomo-manager`.

### 2. Единый скрипт входящих протоколов (`install_mihomo.sh`)

```bash
curl -fsSL https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main/install_mihomo.sh -o install_mihomo.sh && chmod +x install_mihomo.sh && sudo ./install_mihomo.sh
```

```bash
# Интерактивное меню (выбор любого из 17 протоколов, просмотр/изменение/удаление узлов)
sudo ./install_mihomo.sh

# Только имя протокола: переход сразу к интерактивному мастеру этого протокола
sudo ./install_mihomo.sh reality

# Протокол + параметры (или -y): автоматическая установка (-q выводит только ссылку/YAML)
sudo ./install_mihomo.sh reality -y -q
sudo ./install_mihomo.sh reality --port 443 --sni hk.art.museum --address my.ddns.net
sudo ./install_mihomo.sh ss --port 2022 --method 2022-blake3-aes-256-gcm -q
sudo ./install_mihomo.sh anytls --port 8443 --dest www.bing.com:443 -q
sudo ./install_mihomo.sh hysteria2 --port 443 --obfs salamander
sudo ./install_mihomo.sh <протокол> --help
```

## 📦 Дополнительные и автономные скрипты

* `mihomo_routing.sh` (`mihomo-routing`) — настройка исходящих прокси и правил маршрутизации
* `mihomo_restore.sh` (`mihomo-restore`) — восстановление и проверка конфигурации из URL или архива `.tar.gz`
* `update_geo.sh` / `uninstall_mihomo.sh` — обновление баз Geo / полное удаление с резервной копией
* `install_realm.sh` / `install_dnat.sh` — автономный проброс портов Realm / ядерный DNAT (`iptables`/`nftables`)
* `install_snell.sh` / `install_snell_legacy.sh` — официальный Snell v6 / Snell v4.1.1 и v5.0.1
