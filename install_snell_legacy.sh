#!/bin/bash

# ==============================================================================
# Snell v4/v5 服务端 一键安装管理脚本
# 版本: V-Snell-Legacy-1.0
#
# 为什么单独做一个脚本:
#   install_snell.sh 只安装 Snell v6。部分机房防火墙会按 v6 的流量特征拦截,
#   这时需要官方 v4/v5 二进制。两套脚本必须能同时装在一台机器上, 所以这里
#   使用完全独立的路径和服务名, 卸载也只删自己的文件。
#
# 文件名用 install_snell_legacy.sh, 而不是 install_snell_v4v5.sh:
#   一个脚本同时管 v4 和 v5, 运行时的身份是 "v6 之外的旧协议栈"。
#   二进制、配置目录、systemd/OpenRC 名字都带 legacy, 和文件名对得上,
#   运维时不容易跟 /usr/local/bin/snell-server、snell@<port> 搞混。
#
# 官方版本 (2026-11-13 核对, 没有 latest 短链, 版本号需显式跟进):
#   说明: https://kb.nssurge.com/surge-knowledge-base/release-notes/snell
#   v4 最新 v4.1.1, v5 最新 v5.0.1
#   (v4.1.2 / v5.0.2 / v5.1.0 的下载地址返回 404)
#   下载: https://dl.nssurge.com/snell/snell-server-v<ver>-linux-<arch>.zip
#
# 在对应二进制上核对过的配置项 (--loglevel notify 启动日志):
#   - listen 只能是单个 host:port。逗号多地址会报 Invalid listen address,
#     多地址 listen 是 v6 才有的。
#   - 值必须裸写。listen = "127.0.0.1:1" 这种带引号的写法无法解析。
#   - ipv6 = true/false。向导默认 false。非法值会被静默忽略, 所以这里自己校验。
#   - dns 从 v4.1.0 起支持, v5 同样支持, 多个地址用逗号分隔, 且必须是 IP。
#     写主机名会让进程直接 abort。
#   - obfs = http 才会出现 "Obfs enabled (HTTP)"。obfs = tls 不报错也不启用,
#     因此脚本不写 tls。不需要混淆时整行省略。v5.0.1 同样认 http。
#   - egress-interface 只有 v5 会打印 "Egress interface"。v4 会忽略该键,
#     脚本只在 v5 写入。需要 CAP_NET_ADMIN / CAP_NET_RAW。
#   - 不写 mode、dns-ip-preference (这是 v6 的选项)。
#   - --loglevel 接受 error / warning / notify / info / verbose / trace,
#     默认 warning。日志等级是命令行参数, 不写进 snell 的 INI。
#
# 路径 (与 v6 对照):
#   二进制   /usr/local/bin/snell-server-legacy     v6: /usr/local/bin/snell-server
#   配置目录 /usr/local/etc/snell-legacy             v6: /usr/local/etc/snell
#   systemd  snell-legacy@<port>                     v6: snell@<port>
#   OpenRC   /etc/init.d/snell-legacy.<port>         v6: /etc/init.d/snell.<port>
#   连接地址 /root/inbound_address.txt 与本仓库其他脚本共用, 卸载不删除。
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-Snell-Legacy-1.0"
readonly snell_config_dir="/usr/local/etc/snell-legacy"
readonly snell_binary_path="/usr/local/bin/snell-server-legacy"
readonly snell_v6_config_dir="/usr/local/etc/snell"
readonly address_file="/root/inbound_address.txt"
readonly snell_download_base="https://dl.nssurge.com/snell"
readonly snell_v4_tag="v4.1.1"
readonly snell_v5_tag="v5.0.1"
readonly snell_service_prefix="snell-legacy"
readonly snell_psk_min_len=12
readonly snell_psk_max_len=255
readonly snell_default_obfs_host="www.bing.com"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
snell_status_info=""
is_quiet=false
OS_ID=""
INIT_SYSTEM=""

# --- 辅助函数 ---
error() { echo -e "\n${red}[✖] $1${none}\n" >&2; }
warn()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${magenta}[⚠] $1${none}\n" >&2; fi; return 0; }
info()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${yellow}[!] $1${none}\n"; fi; return 0; }
success(){ if [[ "$is_quiet" = false ]]; then echo -e "\n${green}[✔] $1${none}\n"; fi; return 0; }

usage() {
    cat <<EOF
Snell v4/v5 服务端安装脚本 ${SCRIPT_VERSION}

交互菜单:
  sudo $0

非交互安装 (默认协议 v5, 默认端口 6160, 省略 --psk 时生成 32 位随机密钥):
  sudo $0 install [--protocol 4|5] [--port N] [--psk TEXT]
                   [--listen-host 0.0.0.0] [--ipv6 true|false]
                   [--obfs off|http] [--obfs-host www.bing.com]
                   [--dns 1.1.1.1,8.8.8.8]
                   [--egress-interface IFACE] [--loglevel warning]
                   [--quiet]

说明:
  --protocol           4 或 5, 默认 5。核心已安装时必须与现有主版本一致。
  --obfs               只有 http 会被 v4.1.1 / v5.0.1 真正启用, 默认 off。
  --egress-interface   仅 v5。网卡需已存在, 服务以 root 运行并授予 CAP_NET_ADMIN/CAP_NET_RAW。
  --loglevel           error|warning|notify|info|verbose|trace, 默认 warning。
  -q, --quiet          标准输出只保留 Surge 行和 Mihomo YAML。
EOF
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

normalize_connection_address() {
    python3 - "$1" <<'PY'
import ipaddress, re, sys
value = sys.argv[1].strip()
if value.startswith('[') and value.endswith(']'):
    value = value[1:-1]
try:
    print(ipaddress.ip_address(value).compressed)
except ValueError:
    if len(value) > 253 or not re.fullmatch(r'(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value):
        raise SystemExit(1)
    print(value.rstrip('.'))
PY
}

# --- 地址/参数校验 ---
is_valid_port() { local port=$1; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; }

is_valid_protocol() {
    case "$1" in
        4|5) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_loglevel() {
    case "$1" in
        error|warning|notify|info|verbose|trace) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_ipv6_flag() {
    case "$1" in
        true|false) return 0 ;;
        *) return 1 ;;
    esac
}

# 官方 v4/v5 二进制只在 obfs = http 时启用混淆。tls 会被接受但不生效, 这里直接拒绝。
normalize_obfs() {
    case "$1" in
        ""|off|none) printf 'off\n' ;;
        http) printf 'http\n' ;;
        *) return 1 ;;
    esac
}

# PSK: 官方知识库建议至少 12 位, 向导生成约 32 位字母数字。
# v4/v5 二进制本身只拒绝空 PSK, 过短的密钥仍能启动; 这里按知识库和 v6 脚本
# 把长度卡在 12-255, 并把字符集限制成 INI/Surge 都安全的 Base64 风格。
is_valid_psk() {
    local psk=$1
    python3 -c '
import sys, re
psk = sys.argv[1].encode("utf-8")
if not 12 <= len(psk) <= 255:
    sys.exit(1)
sys.exit(0 if re.fullmatch(r"[A-Za-z0-9+/=_-]+", sys.argv[1]) else 1)' "$psk" 2>/dev/null
}

generate_psk() {
    python3 - <<'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(32)))
PY
}

# 空字符串表示不写 dns。非空时每一项都必须是 IP, 主机名会让 snell-server abort。
is_valid_dns_list() {
    local dns=$1
    [[ -z "$dns" ]] && return 0
    python3 -c '
import ipaddress, sys
parts = [p.strip() for p in sys.argv[1].split(",")]
if not parts or any(not p for p in parts):
    raise SystemExit(1)
for p in parts:
    ipaddress.ip_address(p)' "$dns" 2>/dev/null
}

normalize_dns_list() {
    python3 -c '
import sys
parts = [p.strip() for p in sys.argv[1].split(",") if p.strip()]
print(",".join(parts))' "$1"
}

# 空字符串表示不写 egress-interface。非空时要求网卡已经存在。
is_valid_iface() {
    local name=$1
    [[ -z "$name" ]] && return 0
    python3 -c '
import re, sys
raise SystemExit(0 if re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", sys.argv[1]) else 1)' "$name" 2>/dev/null || return 1
    if [[ -d /sys/class/net && ! -e "/sys/class/net/$name" ]]; then
        return 1
    fi
    return 0
}

# listen 列表校验: 单个 host:port / [v6]:port, host 必须是 IP。
# v4/v5 不接受逗号多地址。
is_valid_listen() {
    python3 -c '
import ipaddress, re, sys
addr = sys.argv[1].strip()
if not addr or "," in addr or ":" not in addr:
    raise SystemExit(1)
host, _, port = addr.rpartition(":")
if not host or not port.isdigit() or not 1 <= int(port) <= 65535:
    raise SystemExit(1)
m = re.fullmatch(r"\[(.+)\]", host)
inner = m.group(1) if m else host
ipaddress.ip_address(inner)' "$1" 2>/dev/null
}

# 为监听主机附加端口, 裸 IPv6 自动加方括号。拒绝逗号多地址。
build_listen_address() {
    local host=$1 port=$2
    host="${host#"${host%%[![:space:]]*}"}"
    host="${host%"${host##*[![:space:]]}"}"
    if [[ -z "$host" || "$host" == *,* ]]; then
        error "v4/v5 只支持单个监听地址, 不能用逗号写多个。多地址 listen 请用 install_snell.sh。"
        return 1
    fi
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+$ || "$host" =~ ^\[.*\]:[0-9]+$ ]]; then
        error "监听主机不要包含端口, 端口在上一步已经单独填写。"
        return 1
    fi
    if [[ "$host" == *:* && "$host" != \[* ]]; then
        host="[${host}]"
    fi
    printf '%s\n' "${host}:${port}"
}

snell_tag_for_protocol() {
    case "$1" in
        4) printf '%s\n' "$snell_v4_tag" ;;
        5) printf '%s\n' "$snell_v5_tag" ;;
        *) return 1 ;;
    esac
}

assert_legacy_paths() {
    [[ "$snell_binary_path" == "/usr/local/bin/snell-server-legacy" ]] || return 1
    [[ "$snell_config_dir" == "/usr/local/etc/snell-legacy" ]] || return 1
    [[ "$snell_service_prefix" == "snell-legacy" ]] || return 1
    [[ "$snell_v6_config_dir" == "/usr/local/etc/snell" ]] || return 1
}

# --- 核心安装逻辑 ---
install_snell_core() {
    local protocol=$1
    local tag machine arch
    tag=$(snell_tag_for_protocol "$protocol") || return 1
    info "开始安装 Snell v${protocol} 服务端核心 (${tag})..."
    machine="$(uname -m)"
    # 官方命名: amd64 / aarch64 / i386 / armv7l。没有 arm64 别名, 也没有 latest 短链。
    case "$machine" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="aarch64" ;;
        i386|i686) arch="i386" ;;
        armv7|armv7l) arch="armv7l" ;;
        armv6l) arch="armv7l" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac

    local filename="snell-server-${tag}-linux-${arch}.zip"
    local url="${snell_download_base}/${filename}"
    local tmpdir
    tmpdir="$(mktemp -d)" || return 1

    info "正在下载 Snell ($filename)..."
    if ! curl -fL --retry 3 --retry-delay 1 "$url" -o "$tmpdir/snell.zip"; then
        rm -rf "$tmpdir"
        error "下载 snell-server 失败: $url"
        return 1
    fi
    if [[ ! -s "$tmpdir/snell.zip" ]]; then
        rm -rf "$tmpdir"
        error "下载结果为空: $url"
        return 1
    fi
    if ! unzip -tqq "$tmpdir/snell.zip" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        error "下载的压缩包无法通过校验: $url"
        return 1
    fi

    info "解压并安装到 ${snell_binary_path} ..."
    if ! unzip -oq "$tmpdir/snell.zip" -d "$tmpdir" || [[ ! -f "$tmpdir/snell-server" ]]; then
        rm -rf "$tmpdir"
        error "解压 snell-server 失败。"
        return 1
    fi
    chmod +x "$tmpdir/snell-server" || { rm -rf "$tmpdir"; return 1; }

    local reported
    if ! reported=$("$tmpdir/snell-server" --version 2>&1); then
        rm -rf "$tmpdir"
        error "下载的 snell-server 无法执行, 已取消安装。"
        return 1
    fi
    if ! grep -q "snell-server ${tag}" <<<"$reported"; then
        rm -rf "$tmpdir"
        error "版本校验失败, 期望 snell-server ${tag}, 实际输出: ${reported}"
        return 1
    fi

    install -m 0755 "$tmpdir/snell-server" "$snell_binary_path" || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$snell_config_dir" || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    success "Snell v${protocol} 服务端核心安装完成 (${tag})"
}

installed_snell_version() {
    [[ -x "$snell_binary_path" ]] || return 1
    "$snell_binary_path" --version 2>&1 | awk 'match($0, /snell-server v[0-9][^ ]*/) { print substr($0, RSTART, RLENGTH); exit }'
}

protocol_of_installed() {
    local ver
    ver=$(installed_snell_version 2>/dev/null || true)
    case "$ver" in
        *" v4."*) printf '4\n' ;;
        *" v5."*) printf '5\n' ;;
        *) return 1 ;;
    esac
}

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID=${ID:-}
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="unknown"; fi
}

check_system_compatibility() {
    if [[ "$(uname -s)" != "Linux" ]]; then error "仅支持 Linux"; return 1; fi
    detect_system
    local supported_distros=("ubuntu" "debian" "kali" "raspbian" "deepin" "mint" "elementary" "alpine")
    local distro_detected=false
    local s
    for s in "${supported_distros[@]}"; do [[ "${OS_ID}" == "$s" ]] && distro_detected=true && break; done
    if [[ "$distro_detected" == false ]]; then
        if command -v apt &>/dev/null && command -v dpkg &>/dev/null; then
            distro_detected=true
            OS_ID="debian-compatible"
            info "检测到基于 APT 的包管理系统, 假定为 Debian 兼容系统。"
        fi
    fi
    if [[ "$distro_detected" == false ]]; then error "错误: 未检测到支持的 Linux 发行版。"; return 1; fi
    [[ "$is_quiet" == false ]] && info "系统兼容性检查通过 | 系统: ${OS_ID} | init: ${INIT_SYSTEM}"
    local required_commands=("awk" "grep" "sed" "curl" "python3" "install" "mktemp" "unzip")
    local missing_commands=()
    local cmd
    for cmd in "${required_commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd"); done
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing_commands[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache bash curl python3 unzip coreutils
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl python3 unzip coreutils
        else
            error "当前系统不支持自动安装依赖"
            return 1
        fi
    fi
    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { error "缺少必要命令: $cmd"; return 1; }
    done
    return 0
}

pre_check() {
    [[ $(id -u) != 0 ]] && error "必须以 root 运行" && exit 1
    if ! check_system_compatibility; then exit 1; fi
    if ! assert_legacy_paths; then
        error "内部路径异常, 已中止, 避免覆盖 Snell v6。"
        exit 1
    fi
}

# --- 服务管理 (每端口一个服务实例: snell-legacy@<port>) ---
install_service_systemd() {
    local port=$1 loglevel=$2
    local conf="${snell_config_dir}/snell-server-${port}.conf"
    info "安装 Systemd 服务实例 (snell-legacy@${port}, User=root)..."
    cat >"/etc/systemd/system/snell-legacy@${port}.service" <<EOF
[Unit]
Description=Snell Legacy Server v4/v5 (port ${port})
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=${snell_binary_path} -c ${conf} --loglevel ${loglevel}
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    [[ -s "/etc/systemd/system/snell-legacy@${port}.service" ]] || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now "snell-legacy@${port}" || return 1
    success "Systemd 服务实例 snell-legacy@${port} 已安装并启动"
}

install_service_openrc() {
    local port=$1 loglevel=$2
    local conf="${snell_config_dir}/snell-server-${port}.conf"
    info "安装 OpenRC 服务实例 (snell-legacy.${port})..."
    cat >"/etc/init.d/snell-legacy.${port}" <<EOF
#!/sbin/openrc-run
name="snell-legacy-${port}"
description="Snell Legacy Server v4/v5 (port ${port})"
command="${snell_binary_path}"
command_args="-c ${conf} --loglevel ${loglevel}"
command_background=true
pidfile="/run/snell-legacy-${port}.pid"
start_stop_daemon_args="--make-pidfile --background"

depend() {
  need net
  use dns
}
EOF
    [[ -s "/etc/init.d/snell-legacy.${port}" ]] || return 1
    chmod +x "/etc/init.d/snell-legacy.${port}" || return 1
    rc-update add "snell-legacy.${port}" default || return 1
    rc-service "snell-legacy.${port}" restart || rc-service "snell-legacy.${port}" start || return 1
    success "OpenRC 服务实例 snell-legacy.${port} 已安装并启动"
}

setup_service() {
    local port=$1
    local loglevel
    loglevel=$(read_kv "$(snell_meta_path "$port")" "loglevel" 2>/dev/null || true)
    [[ -z "$loglevel" ]] && loglevel="warning"
    if ! is_valid_loglevel "$loglevel"; then
        error "日志等级无效: $loglevel"
        return 1
    fi
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then install_service_systemd "$port" "$loglevel"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then install_service_openrc "$port" "$loglevel"
    else error "无法确定服务管理器 (需要 systemd 或 OpenRC), 请手动配置自启动。"; return 1; fi
}

service_restart() {
    local port=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart "snell-legacy@${port}" || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service "snell-legacy.${port}" restart || return 1
    else error "无法确定服务管理器, 请手动重启 snell-legacy@${port}。"; return 1; fi
    sleep 1
    service_is_active "$port"
}

service_is_active() {
    local port=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active --quiet "snell-legacy@${port}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service "snell-legacy.${port}" status >/dev/null 2>&1 && rc-service "snell-legacy.${port}" status 2>/dev/null | grep -qi started
    else return 1; fi
}

service_stop_disable() {
    local port=$1
    if ! assert_legacy_paths; then
        error "服务前缀异常, 已中止, 不会改动 Snell v6。"
        return 1
    fi
    if ! is_valid_port "$port"; then
        error "拒绝操作非法端口: $port"
        return 1
    fi
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "snell-legacy@${port}" 2>/dev/null || true
        systemctl disable "snell-legacy@${port}" 2>/dev/null || true
        rm -f "/etc/systemd/system/snell-legacy@${port}.service"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "snell-legacy.${port}" stop 2>/dev/null || true
        rc-update del "snell-legacy.${port}" default 2>/dev/null || true
        rm -f "/etc/init.d/snell-legacy.${port}"
    fi
}

check_snell_status() {
    if [[ ! -f "$snell_binary_path" ]]; then snell_status_info="  Snell v4/v5 状态: ${red}未安装${none}"; return; fi
    local snell_version count
    snell_version=$(installed_snell_version 2>/dev/null || echo "未知")
    count=$(snell_node_count 2>/dev/null || echo 0)
    snell_status_info="  Snell v4/v5 状态: ${green}已安装${none} | 版本: ${cyan}${snell_version}${none} | 节点: ${cyan}${count}${none} 个"
}

# --- 配置文件读写 ---
snell_conf_path() { printf '%s/snell-server-%s.conf' "$snell_config_dir" "$1"; }
snell_meta_path() { printf '%s/snell-server-%s.meta' "$snell_config_dir" "$1"; }
snell_v6_conf_path() { printf '%s/snell-server-%s.conf' "$snell_v6_config_dir" "$1"; }
snell_link_path() { printf '/root/mihomo_snell_legacy_link_%s.txt' "$1"; }

list_snell_ports() {
    local p
    for p in "${snell_config_dir}"/snell-server-*.conf; do
        [[ -f "$p" ]] || continue
        basename "$p" | sed -nE 's/^snell-server-([0-9]+)\.conf$/\1/p'
    done | sort -n
}

snell_node_count() {
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    [[ -z "$ports" ]] && { echo 0; return; }
    printf '%s\n' "$ports" | wc -l | tr -d ' '
}

# 官方向导写的是裸值。读取时顺带剥一层可选引号, 兼容手工编辑。
# 官方解析器不把 # 当注释, 所以这里也不按 # 截断。
read_kv() {
    local path=$1 key=$2
    [[ -f "$path" ]] || return 1
    python3 - "$path" "$key" <<'PY'
import sys
path, key = sys.argv[1:3]
found = False
with open(path, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("[") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                v = v[1:-1]
            print(v)
            found = True
            break
if not found:
    raise SystemExit(1)
PY
}

# TCP LISTEN 即视为占用。/proc 能看到绑在非 127.0.0.1 上的端口, 没有 ss 时也能用。
port_is_listening() {
    local port=$1
    if python3 - "$port" <<'PY'
import sys
port = int(sys.argv[1])
want = f"{port:04X}"
for path in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        next(fh, None)
        for line in fh:
            cols = line.split()
            if len(cols) < 4 or ":" not in cols[1]:
                continue
            if cols[1].rsplit(":", 1)[1].upper() == want and cols[3] == "0A":
                raise SystemExit(0)
raise SystemExit(1)
PY
    then
        return 0
    fi
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":${port} " && return 0
    fi
    (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}

# 返回 0 且在 stdout 给出原因时, 表示这个端口不能再用。
# 会同时看本脚本的配置、v6 脚本的配置, 以及当前是否已有进程在监听。
port_conflict_message() {
    local port=$1
    if [[ -f "$(snell_conf_path "$port")" ]]; then
        printf '端口 %s 的 v4/v5 节点已存在。\n' "$port"
        return 0
    fi
    if [[ -f "$(snell_v6_conf_path "$port")" ]]; then
        printf '端口 %s 已被 Snell v6 (install_snell.sh) 占用。\n' "$port"
        return 0
    fi
    if port_is_listening "$port"; then
        printf '端口 %s 已被其他进程占用。\n' "$port"
        return 0
    fi
    return 1
}

backup_config() {
    local conf=$1
    local backup
    backup=$(mktemp "${conf}.bak.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$conf" "$backup" || { rm -f "$backup"; return 1; }
    chmod 600 "$backup"
    printf '%s\n' "$backup"
}

backup_config_archive() {
    [[ -d "$snell_config_dir" ]] || return 0
    local archive
    archive=$(mktemp "/root/snell-legacy-config-backup-$(date +%Y%m%d%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C "$(dirname "$snell_config_dir")" "$(basename "$snell_config_dir")"; then
        rm -f "$archive"
        return 1
    fi
    chmod 600 "$archive" || return 1
    printf '%s\n' "$archive"
}

# 写入节点配置。server INI 只包含该版本真正会读的键;
# 日志等级和 obfs-host (仅客户端需要) 放在旁边的 .meta, 不进 INI。
write_snell_files() {
    local port=$1 listen=$2 psk=$3 ipv6=$4 obfs=$5 dns=$6 egress=$7 loglevel=$8 obfs_host=$9 protocol=${10}
    local conf meta conf_backup="" meta_backup=""
    conf=$(snell_conf_path "$port")
    meta=$(snell_meta_path "$port")
    mkdir -p "$snell_config_dir" || return 1

    if [[ -f "$conf" ]]; then
        conf_backup=$(backup_config "$conf") || return 1
    fi
    if [[ -f "$meta" ]]; then
        meta_backup=$(backup_config "$meta") || return 1
    fi

    if ! python3 - "$conf" "$meta" "$listen" "$psk" "$ipv6" "$obfs" "$dns" "$egress" "$loglevel" "$obfs_host" "$protocol" <<'PY'
import os, sys, tempfile

(conf, meta, listen, psk, ipv6, obfs, dns, egress, loglevel, obfs_host, protocol) = sys.argv[1:12]

def ini_bare(value):
    value = value.strip()
    if value == "" or any(c in value for c in " \t\n\r\"#;"):
        raise SystemExit("配置值含 INI 不安全字符, 拒绝写入: %r" % value)
    return value

if protocol not in ("4", "5"):
    raise SystemExit("protocol")
if ipv6 not in ("true", "false"):
    raise SystemExit("ipv6")
if obfs not in ("off", "http"):
    raise SystemExit("obfs")
if loglevel not in ("error", "warning", "notify", "info", "verbose", "trace"):
    raise SystemExit("loglevel")
if protocol != "5":
    egress = ""
if obfs != "http":
    obfs_host = ""

lines = [
    "[snell-server]",
    "listen = %s" % ini_bare(listen),
    "psk = %s" % ini_bare(psk),
    "ipv6 = %s" % ipv6,
]
if obfs == "http":
    lines.append("obfs = http")
if dns.strip():
    parts = [ini_bare(p) for p in dns.split(",") if p.strip()]
    if not parts:
        raise SystemExit("dns")
    lines.append("dns = %s" % ",".join(parts))
if egress.strip():
    lines.append("egress-interface = %s" % ini_bare(egress))
conf_text = "\n".join(lines) + "\n"

meta_lines = ["loglevel = %s" % loglevel]
if obfs_host.strip():
    meta_lines.append("obfs_host = %s" % ini_bare(obfs_host))
meta_text = "\n".join(meta_lines) + "\n"

def atomic_write(path, content):
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".snell-legacy.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

atomic_write(conf, conf_text)
atomic_write(meta, meta_text)
PY
    then
        if [[ -n "$conf_backup" ]]; then cp "$conf_backup" "$conf"; else rm -f "$conf"; fi
        if [[ -n "$meta_backup" ]]; then cp "$meta_backup" "$meta"; else rm -f "$meta"; fi
        error "写入配置失败, 已恢复原配置。"
        return 1
    fi

    chmod 600 "$conf" "$meta"
    success "节点配置已写入: $conf"
}

# snell-server 没有 -t。探测时把 listen 换成本机临时端口, 确认配置能被解析,
# 起来后立刻关掉, 避免和即将启动的正式实例抢端口。
probe_snell_conf() {
    [[ -x "$snell_binary_path" ]] || return 0
    local port=$1
    local conf
    conf=$(snell_conf_path "$port") || return 1
    [[ -f "$conf" ]] || return 1

    local probe_dir
    probe_dir=$(mktemp -d) || return 1

    if ! python3 - "$conf" "${probe_dir}/probe.conf" <<'PY'
import re, socket, sys
src, dst = sys.argv[1:3]

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port

def addr_ok(addr):
    if ":" not in addr or "," in addr:
        return False
    host, _, port = addr.rpartition(":")
    m = re.fullmatch(r"\[(.+)\]", host)
    inner = m.group(1) if m else host
    if not inner or not port.isdigit():
        return False
    return 1 <= int(port) <= 65535

with open(src, encoding="utf-8") as handle:
    lines = handle.readlines()

out = []
bad = []
for raw in lines:
    stripped = raw.strip()
    if stripped.startswith("listen") and "=" in stripped:
        value = stripped.partition("=")[2].strip().strip('"').strip("'")
        if not addr_ok(value):
            bad.append(value)
            out.append(raw)
            continue
        out.append("listen = 127.0.0.1:%d\n" % free_port())
    else:
        out.append(raw)

with open(dst, "w", encoding="utf-8") as handle:
    handle.writelines(out)
if bad:
    print("invalid listen address: " + ", ".join(bad), file=sys.stderr)
    raise SystemExit(3)
PY
    then
        rm -rf "$probe_dir"
        error "listen 地址不合法。"
        return 1
    fi

    local log_file="${probe_dir}/probe.log"
    "$snell_binary_path" -c "${probe_dir}/probe.conf" --loglevel warning >"$log_file" 2>&1 &
    local pid=$!
    local waited=0
    local alive=true
    while (( waited < 20 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            alive=false
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    if [[ "$alive" == "true" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    else
        wait "$pid" 2>/dev/null || true
    fi

    # 非法 obfs / 非法 dns 有时进程并不退出, 只在日志里打 ERR, 必须看日志。
    if [[ "$alive" == "false" ]] || grep -qiE '<ERR>|Parameter |Invalid |Unknown |signal ' "$log_file" 2>/dev/null; then
        cat "$log_file" >&2
        rm -rf "$probe_dir"
        return 1
    fi
    rm -rf "$probe_dir"
    return 0
}

restart_snell_node() {
    local port=$1
    if [[ ! -f "$(snell_conf_path "$port")" ]]; then error "端口 $port 的节点配置不存在" && return 1; fi
    info "正在重启 snell-legacy@${port} 服务..."
    if ! service_restart "$port"; then
        error "重启失败, 请查看日志 (journalctl -u snell-legacy@${port})"
        return 1
    fi
    success "snell-legacy@${port} 服务已成功重启。"
}

# --- 自定义连接地址管理 (与 v6 / 其他脚本共用同一个文件) ---
set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "说明: 如果服务器是 NAT VPS, 或对外地址与网卡地址不同,"
    echo "请在此填入实际用于外部连接的 IP 或 DDNS 域名。"
    echo "这个文件与 install_snell.sh 以及其他脚本共用。"
    echo "-------------------------------------------------"
    if [[ -f "$address_file" ]]; then
        local current_addr
        current_addr=$(cat "$address_file")
        echo -e "当前已设置: ${cyan}${current_addr}${none}"
    else
        echo -e "当前状态: ${yellow}自动获取公网 IP${none}"
    fi
    echo ""
    local new_addr
    read -r -p "请输入新的连接地址 (留空并回车则恢复自动获取): " new_addr
    if [[ -z "$new_addr" ]]; then
        rm -f "$address_file"
        success "已恢复为自动获取公网 IP 模式。"
    else
        local normalized_addr
        if ! normalized_addr=$(normalize_connection_address "$new_addr"); then
            error "连接地址无效, 请输入纯 IP 地址或域名 (不要包含协议和端口)。"
            return 1
        fi
        printf '%s\n' "$normalized_addr" > "$address_file"
        chmod 600 "$address_file"
        success "连接地址已更新为: $normalized_addr"
    fi
}

# --- 节点信息: Surge 行 + Mihomo YAML ---
view_node_info() {
    local target_port="${1:-}"
    if [[ -z "$target_port" ]]; then
        target_port=$(select_existing_port "请输入要查看的端口: " false) || return 1
    fi

    local conf
    conf=$(snell_conf_path "$target_port")
    [[ -f "$conf" ]] || { error "端口 $target_port 的节点配置不存在。"; return 1; }

    local protocol
    protocol=$(protocol_of_installed 2>/dev/null || true)
    [[ -z "$protocol" ]] && protocol="?"

    local psk ipv6 obfs dns egress loglevel obfs_host meta
    psk=$(read_kv "$conf" "psk" 2>/dev/null || true)
    ipv6=$(read_kv "$conf" "ipv6" 2>/dev/null || true)
    obfs=$(read_kv "$conf" "obfs" 2>/dev/null || true)
    dns=$(read_kv "$conf" "dns" 2>/dev/null || true)
    egress=$(read_kv "$conf" "egress-interface" 2>/dev/null || true)
    meta=$(snell_meta_path "$target_port")
    loglevel=$(read_kv "$meta" "loglevel" 2>/dev/null || true)
    obfs_host=$(read_kv "$meta" "obfs_host" 2>/dev/null || true)
    [[ -z "$ipv6" ]] && ipv6="false"
    [[ -z "$obfs" ]] && obfs="off"
    [[ -z "$loglevel" ]] && loglevel="warning"
    [[ "$obfs" == "http" && -z "$obfs_host" ]] && obfs_host="$snell_default_obfs_host"

    local ip=""
    if [[ -f "$address_file" && -s "$address_file" ]]; then
        ip=$(cat "$address_file")
    fi
    if [[ -z "$ip" ]]; then
        ip=$(get_public_ip || true)
    fi
    [[ -z "$ip" ]] && { error "无法确定连接地址。"; return 1; }

    local ipinfo_json="" country="" org="" link_name
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null || true)
    if [[ -n "$ipinfo_json" ]]; then
        country=$(printf '%s\n' "$ipinfo_json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
        org=$(printf '%s\n' "$ipinfo_json" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then link_name="${country} - ${org}"
    else link_name="snell-v${protocol}-${target_port}"; fi

    local rendered surge_line client_yaml
    rendered=$(python3 -c '
import json, re, sys
name, server, port, psk, version, obfs, obfs_host = sys.argv[1:8]
safe = re.sub(r"\s+", " ", name.replace(",", " ").replace("=", " ").replace("\n", " ")).strip()
if not safe:
    safe = "snell-v%s-%s" % (version, port)
parts = [safe + " = snell", server, port, "psk=" + psk, "version=" + version]
lines = [
    "  - name: " + json.dumps(safe, ensure_ascii=False),
    "    type: snell",
    "    server: " + json.dumps(server, ensure_ascii=False),
    "    port: " + port,
    "    psk: " + json.dumps(psk, ensure_ascii=False),
    "    version: " + version,
    "    udp: true",
]
if obfs == "http":
    parts.append("obfs=http")
    parts.append("obfs-host=" + obfs_host)
    lines.append("    obfs-opts:")
    lines.append("      mode: http")
    lines.append("      host: " + json.dumps(obfs_host, ensure_ascii=False))
print(", ".join(parts))
print("<<<YAML>>>")
print("\n".join(lines))' "$link_name" "$ip" "$target_port" "$psk" "$protocol" "$obfs" "$obfs_host" 2>/dev/null) || {
        error "生成客户端配置失败。"
        return 1
    }
    surge_line=${rendered%%$'\n'<<<YAML>>>*}
    client_yaml=${rendered#*<<<YAML>>>$'\n'}

    local save_file
    save_file=$(snell_link_path "$target_port")
    {
        printf '%s\n' "# Surge"
        printf '%s\n' "$surge_line"
        printf '\n%s\n' "# Mihomo"
        printf '%s\n' "$client_yaml"
    } > "$save_file"
    chmod 600 "$save_file"

    if [[ "$is_quiet" == true ]]; then
        printf '%s\n\n%s\n' "$surge_line" "$client_yaml"
        return 0
    fi

    local ver_text
    ver_text=$(installed_snell_version 2>/dev/null || echo "v${protocol}")
    echo "----------------------------------------------------------------"
    echo -e "${green} --- Snell v${protocol} 节点信息 (${ver_text}) --- ${none}"
    echo -e "${yellow} 地址:   ${cyan}${ip}${none}"
    echo -e "${yellow} 端口:   ${cyan}${target_port}${none}"
    echo -e "${yellow} PSK:    ${cyan}${psk}${none}"
    echo -e "${yellow} IPv6:   ${cyan}${ipv6}${none}"
    echo -e "${yellow} Obfs:   ${cyan}${obfs}${none}"
    [[ -n "$dns" ]] && echo -e "${yellow} DNS:    ${cyan}${dns}${none}"
    [[ -n "$egress" ]] && echo -e "${yellow} 出口:   ${cyan}${egress}${none}"
    echo -e "${yellow} 日志:   ${cyan}${loglevel}${none}"
    echo "----------------------------------------------------------------"
    echo -e "${green} Surge [Proxy] 行:${none}\n"
    echo -e "${cyan}${surge_line}${none}"
    echo
    echo -e "${green} Mihomo 客户端 proxies 片段 (已保存到 ${save_file}):${none}\n"
    echo -e "${cyan}${client_yaml}${none}"
    echo "----------------------------------------------------------------"
    echo -e "${yellow}[!] 客户端 version 填 ${protocol}。PSK 与服务端保持一致。"
    if [[ "$protocol" == "5" ]]; then
        echo -e "    v5 会在同一端口额外监听 UDP (QUIC Proxy), 防火墙需要同时放行 UDP。"
        echo -e "    若不需要 QUIC, Surge 客户端可以把 version 改成 4, v5 服务端向下兼容 v4 客户端。"
    fi
    if [[ "$obfs" == "http" ]]; then
        echo -e "    已启用 obfs=http, 客户端的 obfs / obfs-host 要和上面一致。"
    fi
    echo -e "    v4/v5 与 v6 不互通。v6 请继续用 install_snell.sh。${none}"
    echo "----------------------------------------------------------------"
}

# prompts 走 stderr, 选中的端口走 stdout, 方便 target=$(select_existing_port ...)。
select_existing_port() {
    local prompt=$1 force_prompt=$2
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        error "未找到任何 Snell v4/v5 节点。"
        return 1
    fi
    local count
    count=$(printf '%s\n' "$ports" | wc -l | tr -d ' ')
    if [[ "$force_prompt" == false && "$count" -eq 1 ]]; then
        printf '%s\n' "$ports"
        return 0
    fi
    echo "当前 Snell v4/v5 节点:" >&2
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        echo " - 端口: $p" >&2
    done <<< "$ports"
    echo "" >&2
    local input_p
    while true; do
        read -r -p "$prompt" input_p
        if printf '%s\n' "$ports" | grep -qx "$input_p"; then
            printf '%s\n' "$input_p"
            return 0
        fi
        error "未找到该端口"
    done
}

choose_protocol() {
    if [[ -x "$snell_binary_path" ]]; then
        local got
        if ! got=$(protocol_of_installed); then
            error "已安装的 snell-server-legacy 无法识别版本, 请先卸载或在菜单里重新安装。"
            return 1
        fi
        # 本函数的 stdout 只留给协议号, 提示必须走 stderr, 否则会被 $() 吃掉。
        info "检测到已安装的 Snell v${got} legacy 核心, 新节点会沿用这个版本。" >&2
        printf '%s\n' "$got"
        return 0
    fi
    echo "请选择要安装的 Snell 协议版本 (下载对应的官方最新构建):" >&2
    echo -e "  ${green}1.${none} v5   ${snell_v5_tag} (默认; QUIC Proxy, 支持 egress-interface)" >&2
    echo -e "  ${cyan}2.${none} v4   ${snell_v4_tag} (仅当 v5 仍被干扰时再退回这一版)" >&2
    local choice
    while true; do
        read -r -p "请输入选项 [1-2] (默认 1): " choice
        case "${choice:-1}" in
            1) printf '5\n'; return 0 ;;
            2) printf '4\n'; return 0 ;;
            *) error "请输入 1 或 2。" ;;
        esac
    done
}

# mode=install 时 PSK 留空会生成新密钥; mode=modify 时留空保持原值。
prompt_node_settings() {
    local mode=$1 protocol=$2
    local cur_psk=${3:-} cur_ipv6=${4:-false} cur_obfs=${5:-off}
    local cur_dns=${6:-} cur_egress=${7:-} cur_log=${8:-warning} cur_host=${9:-$snell_default_obfs_host}

    echo ""
    if [[ "$mode" == "modify" ]]; then
        read -r -p "请输入新的 PSK (回车保持当前密钥): " NODE_PSK
        [[ -z "$NODE_PSK" ]] && NODE_PSK="$cur_psk"
    else
        read -r -p "请输入 PSK (回车生成 32 位随机密钥): " NODE_PSK
        if [[ -z "$NODE_PSK" ]]; then
            NODE_PSK=$(generate_psk)
            info "已自动生成 PSK: ${cyan}${NODE_PSK}${none}"
        fi
    fi

    local input_ipv6 input_obfs input_host input_dns input_egress input_log
    read -r -p "$(echo -e "ipv6 出口 [true/false] (默认: ${cyan}${cur_ipv6}${none}): ")" input_ipv6
    NODE_IPV6=${input_ipv6:-$cur_ipv6}

    read -r -p "$(echo -e "obfs [off/http] (默认: ${cyan}${cur_obfs}${none}, 仅 http 会真正启用): ")" input_obfs
    NODE_OBFS=${input_obfs:-$cur_obfs}
    NODE_OBFS_HOST=""
    if [[ "$NODE_OBFS" == "http" ]]; then
        read -r -p "$(echo -e "obfs-host, 只写进客户端配置 (默认: ${cyan}${cur_host}${none}): ")" input_host
        NODE_OBFS_HOST=${input_host:-$cur_host}
    fi

    if [[ "$mode" == "modify" ]]; then
        echo -e "${yellow}[!] dns 直接回车保持原值; 输入 - 清空, 改回系统 DNS。多个地址用逗号分隔, 必须是 IP。${none}"
    else
        echo -e "${yellow}[!] dns 留空则不写入配置, 使用系统 DNS。多个地址用逗号分隔, 必须是 IP。${none}"
    fi
    local dns_hint=${cur_dns:-未设置}
    read -r -p "$(echo -e "dns (当前: ${cyan}${dns_hint}${none}): ")" input_dns
    if [[ "$mode" == "modify" && "$input_dns" == "-" ]]; then
        NODE_DNS=""
    elif [[ -z "$input_dns" ]]; then
        NODE_DNS="$cur_dns"
    else
        NODE_DNS="$input_dns"
    fi

    NODE_EGRESS=""
    if [[ "$protocol" == "5" ]]; then
        if [[ "$mode" == "modify" ]]; then
            echo -e "${yellow}[!] egress-interface 直接回车保持原值; 输入 - 表示取消绑定。网卡必须已经存在。${none}"
        else
            echo -e "${yellow}[!] egress-interface 留空则不写。仅 v5 支持, 网卡必须已经存在。${none}"
        fi
        local egress_hint=${cur_egress:-未设置}
        read -r -p "$(echo -e "egress-interface (当前: ${cyan}${egress_hint}${none}): ")" input_egress
        if [[ "$mode" == "modify" && "$input_egress" == "-" ]]; then
            NODE_EGRESS=""
        elif [[ -z "$input_egress" ]]; then
            NODE_EGRESS="$cur_egress"
        else
            NODE_EGRESS="$input_egress"
        fi
    fi

    read -r -p "$(echo -e "日志等级 [error/warning/notify/info/verbose/trace] (默认: ${cyan}${cur_log}${none}): ")" input_log
    NODE_LOGLEVEL=${input_log:-$cur_log}
}

validate_node_settings() {
    local protocol=$1
    if ! is_valid_psk "$NODE_PSK"; then
        error "PSK 须为 ${snell_psk_min_len}-${snell_psk_max_len} 字节, 且只能包含 A-Za-z0-9+/=_- 。"
        return 1
    fi
    if ! is_valid_ipv6_flag "$NODE_IPV6"; then
        error "ipv6 只能是 true 或 false。"
        return 1
    fi
    local obfs_norm
    if ! obfs_norm=$(normalize_obfs "$NODE_OBFS"); then
        error "obfs 只能是 off 或 http。v4.1.1 / v5.0.1 不会启用 tls。"
        return 1
    fi
    NODE_OBFS=$obfs_norm
    if [[ "$NODE_OBFS" == "http" ]]; then
        local normalized_host
        if ! normalized_host=$(normalize_connection_address "$NODE_OBFS_HOST"); then
            error "obfs-host 不是合法的 IP 或域名。"
            return 1
        fi
        NODE_OBFS_HOST=$normalized_host
    else
        NODE_OBFS_HOST=""
    fi
    if [[ -n "$NODE_DNS" ]]; then
        NODE_DNS=$(normalize_dns_list "$NODE_DNS")
    fi
    if ! is_valid_dns_list "$NODE_DNS"; then
        error "dns 的每一项都必须是 IP 地址, 例如 1.1.1.1,8.8.8.8 。"
        return 1
    fi
    if [[ "$protocol" != "5" && -n "$NODE_EGRESS" ]]; then
        error "egress-interface 只有 v5 支持, 当前协议是 v${protocol}。"
        return 1
    fi
    if ! is_valid_iface "$NODE_EGRESS"; then
        error "egress-interface 无效, 或该网卡不存在: ${NODE_EGRESS}"
        return 1
    fi
    if ! is_valid_loglevel "$NODE_LOGLEVEL"; then
        error "日志等级无效: $NODE_LOGLEVEL (error/warning/notify/info/verbose/trace)"
        return 1
    fi
    return 0
}

install_snell_node() {
    local protocol
    protocol=$(choose_protocol) || return 1

    if [[ -x "$snell_binary_path" ]]; then
        info "继续操作将添加一个新的 v${protocol} 节点, 不会动 Snell v6。"
    fi

    local port
    while true; do
        read -r -p "$(echo -e "监听端口 [1-65535] (默认: ${cyan}6160${none}): ")" port
        [[ -z "$port" ]] && port=6160
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        local conflict
        if conflict=$(port_conflict_message "$port"); then
            error "$conflict"
            continue
        fi
        break
    done

    echo ""
    echo -e "${yellow}[!] 请输入监听主机, 不要包含端口。v4/v5 只能写一个地址。"
    echo -e "    一般用 0.0.0.0 (仅 IPv4)。纯 IPv6 机器请填 [::] 或 :: 。"
    echo -e "    逗号多地址是 v6 才有的功能。${none}"
    local listen_host=""
    read -r -p "$(echo -e "监听主机 (默认: ${cyan}0.0.0.0${none}): ")" listen_host
    [[ -z "$listen_host" ]] && listen_host="0.0.0.0"

    prompt_node_settings install "$protocol" "" false off "" "" warning "$snell_default_obfs_host" || return 1
    validate_node_settings "$protocol" || return 1

    local listen
    listen=$(build_listen_address "$listen_host" "$port") || return 1
    if ! is_valid_listen "$listen"; then
        error "监听地址格式无效: $listen"
        return 1
    fi

    run_install_node "$protocol" "$port" "$listen" "$NODE_PSK" "$NODE_IPV6" "$NODE_OBFS" "$NODE_DNS" "$NODE_EGRESS" "$NODE_LOGLEVEL" "$NODE_OBFS_HOST" || return 1
    view_node_info "$port"
}

run_install_node() {
    local protocol=$1 port=$2 listen=$3 psk=$4 ipv6=$5 obfs=$6 dns=$7 egress=$8 loglevel=$9 obfs_host=${10}

    if [[ ! -x "$snell_binary_path" ]]; then
        install_snell_core "$protocol" || return 1
    else
        local got
        got=$(protocol_of_installed) || { error "无法识别已安装的 snell-server-legacy 版本。"; return 1; }
        if [[ "$got" != "$protocol" ]]; then
            error "已安装的是 v${got}, 与本次选择的 v${protocol} 不一致。请先在菜单里切换版本。"
            return 1
        fi
    fi

    write_snell_files "$port" "$listen" "$psk" "$ipv6" "$obfs" "$dns" "$egress" "$loglevel" "$obfs_host" "$protocol" || return 1

    if ! probe_snell_conf "$port"; then
        rm -f "$(snell_conf_path "$port")" "$(snell_meta_path "$port")"
        error "snell-server 无法加载新配置, 已移除该节点。"
        return 1
    fi

    if ! setup_service "$port"; then
        rm -f "$(snell_conf_path "$port")" "$(snell_meta_path "$port")"
        service_stop_disable "$port" >/dev/null 2>&1 || true
        error "服务安装失败, 已移除该节点。"
        return 1
    fi

    if ! restart_snell_node "$port"; then
        rm -f "$(snell_conf_path "$port")" "$(snell_meta_path "$port")"
        service_stop_disable "$port" >/dev/null 2>&1 || true
        error "节点启动失败, 已移除该节点。"
        return 1
    fi
    success "Snell v${protocol} 节点 (端口 ${port}) 安装完成。"
}

delete_snell_node() {
    local target_p
    target_p=$(select_existing_port "请输入要删除的端口: " true) || return 0
    local confirm
    read -r -p "确定要永久删除端口 ${target_p} 的 Snell v4/v5 节点吗? [y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return 0; fi

    info "正在删除节点..."
    local conf delete_backup
    conf=$(snell_conf_path "$target_p")
    delete_backup=$(backup_config "$conf" 2>/dev/null) || { error "备份配置失败"; return 1; }
    rm -f "$conf" "$(snell_meta_path "$target_p")"
    service_stop_disable "$target_p"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload || true
    fi
    rm -f "$(snell_link_path "$target_p")"
    success "Snell v4/v5 节点 (端口 $target_p) 已删除。配置备份: $delete_backup"
}

modify_config() {
    local target_p
    target_p=$(select_existing_port "请输入要修改的端口: " true) || return 0
    local protocol
    protocol=$(protocol_of_installed) || { error "无法识别已安装版本, 取消修改。"; return 1; }

    local conf meta listen psk ipv6 obfs dns egress loglevel obfs_host
    conf=$(snell_conf_path "$target_p")
    meta=$(snell_meta_path "$target_p")
    listen=$(read_kv "$conf" "listen" 2>/dev/null || true)
    psk=$(read_kv "$conf" "psk" 2>/dev/null || true)
    ipv6=$(read_kv "$conf" "ipv6" 2>/dev/null || true)
    obfs=$(read_kv "$conf" "obfs" 2>/dev/null || true)
    dns=$(read_kv "$conf" "dns" 2>/dev/null || true)
    egress=$(read_kv "$conf" "egress-interface" 2>/dev/null || true)
    loglevel=$(read_kv "$meta" "loglevel" 2>/dev/null || true)
    obfs_host=$(read_kv "$meta" "obfs_host" 2>/dev/null || true)
    [[ -z "$listen" ]] && { error "读取原 listen 失败, 取消修改。"; return 1; }
    [[ -z "$ipv6" ]] && ipv6="false"
    [[ -z "$obfs" ]] && obfs="off"
    [[ -z "$loglevel" ]] && loglevel="warning"
    [[ -z "$obfs_host" ]] && obfs_host="$snell_default_obfs_host"

    info "修改会重写该端口的配置并重启 snell-legacy@${target_p}。监听地址保持 ${listen} 。"
    prompt_node_settings modify "$protocol" "$psk" "$ipv6" "$obfs" "$dns" "$egress" "$loglevel" "$obfs_host" || return 1
    validate_node_settings "$protocol" || return 1

    local conf_backup="" meta_backup=""
    conf_backup=$(backup_config "$conf") || { error "备份配置失败"; return 1; }
    if [[ -f "$meta" ]]; then
        meta_backup=$(backup_config "$meta") || { error "备份元数据失败"; return 1; }
    fi

    if ! write_snell_files "$target_p" "$listen" "$NODE_PSK" "$NODE_IPV6" "$NODE_OBFS" "$NODE_DNS" "$NODE_EGRESS" "$NODE_LOGLEVEL" "$NODE_OBFS_HOST" "$protocol" \
        || ! probe_snell_conf "$target_p"; then
        [[ -n "$conf_backup" ]] && cp "$conf_backup" "$conf"
        [[ -n "$meta_backup" ]] && cp "$meta_backup" "$meta"
        error "修改失败, 已恢复原配置。"
        return 1
    fi
    if ! setup_service "$target_p" || ! restart_snell_node "$target_p"; then
        [[ -n "$conf_backup" ]] && cp "$conf_backup" "$conf"
        [[ -n "$meta_backup" ]] && cp "$meta_backup" "$meta"
        setup_service "$target_p" >/dev/null 2>&1 || true
        service_restart "$target_p" >/dev/null 2>&1 || true
        error "修改后服务未能正常启动, 已恢复原配置。"
        return 1
    fi
    success "修改完成"
    view_node_info "$target_p"
}

snapshot_tree() {
    local dest=$1
    mkdir -p "$dest"
    if [[ -d "$snell_config_dir" ]]; then
        cp -a "$snell_config_dir"/. "$dest/"
    fi
}

restore_snapshot() {
    local src=$1
    if [[ -f "$src/../binary" ]]; then
        install -m 0755 "$src/../binary" "$snell_binary_path" || return 1
    fi
    mkdir -p "$snell_config_dir"
    find "$snell_config_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    if [[ -n "$(ls -A "$src" 2>/dev/null || true)" ]]; then
        cp -a "$src"/. "$snell_config_dir/"
    fi
    local ports p
    ports=$(list_snell_ports 2>/dev/null || true)
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        setup_service "$p" || true
        service_restart "$p" || true
    done <<< "$ports"
}

strip_egress_interface() {
    python3 - "$snell_config_dir" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
if not root.is_dir():
    raise SystemExit(0)
for path in root.glob("snell-server-*.conf"):
    lines = path.read_text(encoding="utf-8").splitlines(True)
    kept = []
    for raw in lines:
        stripped = raw.strip()
        if "=" in stripped and not stripped.startswith("["):
            key = stripped.split("=", 1)[0].strip()
            if key == "egress-interface":
                continue
        kept.append(raw if raw.endswith("\n") else raw + "\n")
    path.write_text("".join(kept), encoding="utf-8")
    os.chmod(path, 0o600)
PY
}

# 替换二进制。target 是 4 或 5。切换到 v4 时先去掉 v5 专属的 egress-interface。
# 任何一个现有节点无法被新二进制加载, 就连二进制和配置一起回滚。
replace_snell_binary() {
    local target=$1 strip_egress=$2
    local snap
    snap=$(mktemp -d) || return 1
    if [[ -x "$snell_binary_path" ]]; then
        cp "$snell_binary_path" "$snap/binary" || { rm -rf "$snap"; return 1; }
    fi
    snapshot_tree "$snap/conf" || { rm -rf "$snap"; return 1; }

    if [[ "$strip_egress" == true ]]; then
        strip_egress_interface || {
            restore_snapshot "$snap/conf" || true
            rm -rf "$snap"
            error "清理 egress-interface 失败, 已尝试回滚。"
            return 1
        }
    fi

    if ! install_snell_core "$target"; then
        restore_snapshot "$snap/conf" || true
        rm -rf "$snap"
        error "安装新核心失败, 已回滚。"
        return 1
    fi

    local ports p failed=false
    ports=$(list_snell_ports 2>/dev/null || true)
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! probe_snell_conf "$p"; then
            error "端口 ${p} 的配置无法被 v${target} 加载。"
            failed=true
            break
        fi
    done <<< "$ports"
    if [[ "$failed" == true ]]; then
        restore_snapshot "$snap/conf" || true
        rm -rf "$snap"
        error "已回滚到替换前的核心和配置。"
        return 1
    fi

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! setup_service "$p" || ! restart_snell_node "$p"; then
            restore_snapshot "$snap/conf" || true
            rm -rf "$snap"
            error "重启节点失败, 已回滚到替换前的核心和配置。"
            return 1
        fi
    done <<< "$ports"
    rm -rf "$snap"
    success "snell-server-legacy 现在是 v${target} ($(snell_tag_for_protocol "$target"))。"
}

update_or_switch_snell() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server-legacy 未安装" && return; fi
    local current tag other
    current=$(protocol_of_installed) || { error "无法识别当前版本"; return 1; }
    tag=$(snell_tag_for_protocol "$current")
    if [[ "$current" == "5" ]]; then other=4; else other=5; fi
    info "当前: ${cyan}$(installed_snell_version)${none}"
    echo "  1. 重新安装当前主版本的官方构建 (${tag})"
    echo "  2. 切换到 v${other} ($(snell_tag_for_protocol "$other"))"
    echo "  0. 返回"
    local choice
    read -r -p "请输入选项 [0-2]: " choice
    case "$choice" in
        1) replace_snell_binary "$current" false ;;
        2)
            echo ""
            if [[ "$other" == "4" ]]; then
                warn "切到 v4 后, 客户端 version 要改成 4。配置里的 egress-interface 会被去掉 (v4 不支持)。"
            else
                warn "切到 v5 后, 客户端 version 要改成 5 才能用 QUIC Proxy。v5 服务端仍然兼容把客户端留在 version=4。"
            fi
            local confirm
            read -r -p "确定切换到 v${other}? [y/N]: " confirm
            if [[ ! $confirm =~ ^[yY]$ ]]; then info "已取消。"; return 0; fi
            local strip=false
            [[ "$other" == "4" ]] && strip=true
            replace_snell_binary "$other" "$strip"
            ;;
        0|"") info "已取消。" ;;
        *) error "无效选项" ;;
    esac
}

uninstall_snell() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server-legacy 未安装" && return; fi
    if ! assert_legacy_paths; then
        error "路径异常, 已中止卸载, 不会删除 Snell v6 的文件。"
        return 1
    fi
    local confirm
    read -r -p "确定卸载 snell-server-legacy (v4/v5) 吗? 不会删除 Snell v6。配置会先自动备份。[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消。"; return; fi
    local config_archive=""
    if ! config_archive=$(backup_config_archive); then
        error "配置备份失败, 已取消卸载, 未删除任何文件。"
        return 1
    fi
    info "正在卸载 v4/v5 ..."
    local ports p
    ports=$(list_snell_ports 2>/dev/null || true)
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        service_stop_disable "$p"
    done <<< "$ports"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload || true
    fi
    rm -f -- "$snell_binary_path"
    rm -rf -- "$snell_config_dir"
    rm -f /root/mihomo_snell_legacy_link_*.txt
    success "snell-server-legacy 已卸载。配置备份: ${config_archive:-无}"
    info "说明: Snell v6 的二进制、配置和服务未改动。/root/inbound_address.txt 由本套脚本共用, 未删除。"
}

view_snell_log() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server-legacy 未安装" && return; fi
    local target_p
    target_p=$(select_existing_port "请输入要查看日志的端口: " false) || return 0
    info "显示 snell-legacy@${target_p} 日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journalctl -u "snell-legacy@${target_p}" -f --no-pager || true
    else
        error "OpenRC 下请直接查看 /var/log/messages 或服务输出。"
    fi
    trap - SIGINT
    echo ""
    read -r -n 1 -s -p "按任意键返回主菜单..." || true
}

udp_port_is_bound() {
    local port=$1
    python3 - "$port" <<'PY'
import sys
port = int(sys.argv[1])
want = f"{port:04X}"
for path in ("/proc/net/udp", "/proc/net/udp6"):
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        continue
    with fh:
        next(fh, None)
        for line in fh:
            cols = line.split()
            if len(cols) < 4 or ":" not in cols[1]:
                continue
            if cols[1].rsplit(":", 1)[1].upper() == want:
                raise SystemExit(0)
raise SystemExit(1)
PY
}

test_connectivity() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server-legacy 未安装" && return; fi
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell v4/v5 节点。"; return; fi
    local protocol
    protocol=$(protocol_of_installed 2>/dev/null || echo "?")

    echo "连通性测试 (本机连监听端口, 看能否建立 TCP):"
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if (echo > "/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1 || port_is_listening "$p"; then
            echo -e " ${green}✔${none} 端口 ${p}  (TCP 正在监听)"
        else
            echo -e " ${red}✖${none} 端口 ${p}  (TCP 没在监听, 检查服务是否运行)"
        fi
        if [[ "$protocol" == "5" ]]; then
            if udp_port_is_bound "$p"; then
                echo -e " ${green}✔${none} 端口 ${p}  (UDP 已绑定, QUIC Proxy 可用)"
            else
                echo -e " ${yellow}!${none} 端口 ${p}  (没看到 UDP 绑定, QUIC Proxy 可能没起来)"
            fi
        fi
    done <<< "$ports"
    echo ""
    echo -e "${yellow}[!] 这里只验证本机监听是否存活。"
    echo -e "    真正能否代理流量, 需要从外部用客户端实测。${none}"
}

press_any_key_to_continue() {
    echo ""
    read -r -n 1 -s -p "按任意键返回主菜单..." || true
}

restart_snell_menu() {
    local target_p
    target_p=$(select_existing_port "请输入要重启的端口: " false) || return 0
    restart_snell_node "$target_p"
}

main_menu() {
    while true; do
        clear || true
        echo -e "${cyan} Snell v4/v5 服务端 一键安装管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${yellow} Surge 官方 snell-server ${snell_v4_tag} / ${snell_v5_tag}"
        echo -e " 与 install_snell.sh (v6) 使用不同的二进制、配置目录和服务名${none}"
        echo "---------------------------------------------"
        check_snell_status
        echo -e "${snell_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/添加 Snell v4/v5 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新/切换协议版本"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Snell v4/v5 服务"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 snell-server-legacy"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Snell 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改/重置节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看节点信息"
        printf "  ${cyan}%-2s${none} %-35s\n" "8." "测试连通性"
        printf "  ${red}%-2s${none} %-35s\n" "9." "删除指定节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "10." "设置连接地址 (NAT/DDNS)"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        local choice
        read -r -p "请输入选项 [0-10]: " choice

        local needs_pause=true
        case $choice in
            1) install_snell_node ;;
            2) update_or_switch_snell ;;
            3) restart_snell_menu ;;
            4) uninstall_snell ;;
            5) view_snell_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_node_info "" ;;
            8) test_connectivity ;;
            9) delete_snell_node ;;
            10) set_connection_address ;;
            0) success "感谢使用。"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        if [ "$needs_pause" = true ]; then press_any_key_to_continue; fi
    done
}

install_snell_noninteractive() {
    local port="" psk="" protocol="" listen_host="0.0.0.0"
    local ipv6="false" obfs="off" obfs_host="$snell_default_obfs_host"
    local dns="" egress="" loglevel="warning"
    local protocol_given=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --protocol|--port|--psk|--listen-host|--ipv6|--obfs|--obfs-host|--dns|--egress-interface|--loglevel)
                [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; exit 1; }
                case "$1" in
                    --protocol) protocol="$2"; protocol_given=true ;;
                    --port) port="$2" ;;
                    --psk) psk="$2" ;;
                    --listen-host) listen_host="$2" ;;
                    --ipv6) ipv6="$2" ;;
                    --obfs) obfs="$2" ;;
                    --obfs-host) obfs_host="$2" ;;
                    --dns) dns="$2" ;;
                    --egress-interface) egress="$2" ;;
                    --loglevel) loglevel="$2" ;;
                esac
                shift 2
                ;;
            --quiet|-q) is_quiet=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知参数: $1"; exit 1 ;;
        esac
    done

    if [[ -x "$snell_binary_path" ]]; then
        local got
        got=$(protocol_of_installed) || { error "无法识别已安装的 snell-server-legacy 版本。"; exit 1; }
        if [[ "$protocol_given" == true && "$protocol" != "$got" ]]; then
            error "已安装 v${got}, 与 --protocol ${protocol} 不一致。请在菜单中切换版本, 或先卸载再装。"
            exit 1
        fi
        protocol=$got
    else
        [[ -z "$protocol" ]] && protocol=5
    fi

    [[ -z "$port" ]] && port=6160
    if ! is_valid_protocol "$protocol"; then error "protocol 无效: $protocol (4 或 5)"; exit 1; fi
    if ! is_valid_port "$port"; then error "端口无效: $port"; exit 1; fi
    if [[ -z "$psk" ]]; then
        psk=$(generate_psk)
    elif ! is_valid_psk "$psk"; then
        error "PSK 须为 ${snell_psk_min_len}-${snell_psk_max_len} 字节, 且只能包含 A-Za-z0-9+/=_- 。"
        exit 1
    fi
    NODE_PSK=$psk
    NODE_IPV6=$ipv6
    NODE_OBFS=$obfs
    NODE_OBFS_HOST=$obfs_host
    NODE_DNS=$dns
    NODE_EGRESS=$egress
    NODE_LOGLEVEL=$loglevel
    validate_node_settings "$protocol" || exit 1

    local conflict
    if conflict=$(port_conflict_message "$port"); then
        error "$conflict"
        exit 1
    fi

    local listen
    listen=$(build_listen_address "$listen_host" "$port") || exit 1
    if ! is_valid_listen "$listen"; then error "监听地址无效: $listen"; exit 1; fi

    run_install_node "$protocol" "$port" "$listen" "$NODE_PSK" "$NODE_IPV6" "$NODE_OBFS" "$NODE_DNS" "$NODE_EGRESS" "$NODE_LOGLEVEL" "$NODE_OBFS_HOST" || exit 1
    view_node_info "$port"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
    pre_check
    if [[ $# -gt 0 && "$1" == "install" ]]; then
        shift
        if [[ $# -gt 0 ]]; then
            install_snell_noninteractive "$@" || exit 1
        else
            install_snell_node
        fi
    else
        main_menu
    fi
}

main "$@"
