#!/bin/bash

# ==============================================================================
# Snell 服务端 一键安装管理脚本
# 使用 Surge 官方 snell-server 构建服务端, 与 Mihomo 节点体系并行运行
# 版本: V-Snell-Server-1.0
# 功能:
# - 安装/管理 Snell v6 服务端 (官方 snell-server 二进制, 独立服务)
# - 多端口/多节点管理 (每个端口一个独立 conf + systemd/OpenRC 服务实例)
# - 支持 v6 三种加密模式: default / unshaped / unsafe-raw
# - 支持 dns-ip-preference 出口协议栈偏好
# - 支持自定义连接地址 (NAT/DDNS)
# - 精准删除指定端口节点
# - 生成 Mihomo 客户端 YAML 片段 (version: 6, 需要 mihomo >= 1.19.34)
#
# 说明: snell-server 与 mihomo 是两个独立服务, 配置目录、服务单元、二进制互不干扰。
# Snell v6 已移除 obfs 混淆层, 由 PSK 派生的流量整形替代; 客户端必须同样填写
# version: 6 且 mode 与服务端一致, 低版本 mihomo 无法连接 v6 服务端。
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-Snell-Server-1.0"
readonly snell_config_dir="/usr/local/etc/snell"
readonly snell_binary_path="/usr/local/bin/snell-server"
readonly address_file="/root/inbound_address.txt"
readonly snell_download_base="https://dl.nssurge.com/snell"
readonly snell_tag="v6.0.0"        # 官方不提供 latest 短链, 版本号需显式跟进
readonly snell_service_prefix="snell"

# v6 PSK 长度限制 (官方服务端与 mihomo 客户端同为 12-255 字节)
readonly snell_psk_min_len=12
readonly snell_psk_max_len=255

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

# PSK 校验: 官方 v6 服务端限制 12-255 字节 (按字节计, 非 UTF-8 字符数);
# ASCII PSK 下与字符数等价, 多字节 PSK 以字节数按官方语义限制。
is_valid_psk() {
    local psk=$1
    python3 -c '
import sys
psk = sys.argv[1].encode("utf-8")
sys.exit(0 if 12 <= len(psk) <= 255 else 1)' "$psk" 2>/dev/null
}

is_valid_mode() {
    case "$1" in
        default|unshaped|unsafe-raw) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_dns_pref() {
    case "$1" in
        default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only) return 0 ;;
        *) return 1 ;;
    esac
}

# --- 核心安装逻辑 ---
install_snell_core() {
    info "开始安装 Snell 服务端核心..."
    local arch machine; machine="$(uname -m)"
    # 官方命名: amd64 / aarch64 / i386 / armv7l; 没有 arm64 / armv7 别名,
    # 也没有 latest 短链, 版本号变化时需要在此处跟进。
    case "$machine" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="aarch64" ;;
        i386|i686) arch="i386" ;;
        armv7|armv7l) arch="armv7l" ;;
        armv6l) arch="armv7l" ;;  # 官方无 armv6 构建, armv6 用户态与 armv7 二进制兼容
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac

    local filename="snell-server-${snell_tag}-linux-${arch}.zip"
    local url="${snell_download_base}/${filename}"

    info "目标版本: ${snell_tag}"
    local tmpdir; tmpdir="$(mktemp -d)" || return 1

    info "正在下载 Snell ($filename)..."
    if ! curl -fL "$url" -o "$tmpdir/snell.zip"; then
        rm -rf "$tmpdir"; error "下载 snell-server 失败: $url"; return 1
    fi

    info "解压并安装到 /usr/local/bin ..."
    if ! unzip -oq "$tmpdir/snell.zip" -d "$tmpdir" || [[ ! -f "$tmpdir/snell-server" ]]; then
        rm -rf "$tmpdir"; error "解压 snell-server 失败。"; return 1
    fi
    if ! chmod +x "$tmpdir/snell-server" || ! "$tmpdir/snell-server" --version >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        error "下载的 snell-server 无法执行，已取消安装。"
        return 1
    fi
    install -m 0755 "$tmpdir/snell-server" "$snell_binary_path" || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$snell_config_dir" || return 1
    rm -rf "$tmpdir"
    success "Snell 服务端核心安装完成 (${snell_tag})"
}

installed_snell_version() {
    [[ -x "$snell_binary_path" ]] || return 1
    "$snell_binary_path" --version 2>/dev/null | head -n 1
}

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID=${ID:-}; fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="unknown"; fi
}

check_system_compatibility() {
    if [[ "$(uname -s)" != "Linux" ]]; then error "仅支持 Linux"; return 1; fi
    detect_system
    local supported_distros=("ubuntu" "debian" "kali" "raspbian" "deepin" "mint" "elementary" "alpine")
    local distro_detected=false
    for s in "${supported_distros[@]}"; do [[ "${OS_ID}" == "$s" ]] && distro_detected=true && break; done
    if [[ "$distro_detected" == false ]]; then
        if command -v apt &>/dev/null && command -v dpkg &>/dev/null; then
            distro_detected=true; OS_ID="debian-compatible"
            info "检测到基于 APT 的包管理系统，假定为 Debian 兼容系统。"
        fi
    fi
    if [[ "$distro_detected" == false ]]; then error "错误: 未检测到支持的 Linux 发行版。"; return 1; fi
    [[ "$is_quiet" == false ]] && info "系统兼容性检查通过 | 系统: ${OS_ID} | init: ${INIT_SYSTEM}"
    local required_commands=("awk" "grep" "sed" "curl" "python3" "install" "mktemp" "unzip")
    local missing_commands=()
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
}

# --- 服务管理 (每端口一个服务实例: snell@<port>) ---
install_service_systemd() {
    local port=$1 conf="$2"
    info "安装 Systemd 服务实例 (snell@${port}, User=root)..."
    cat >"/etc/systemd/system/snell@${port}.service" <<EOF
[Unit]
Description=Snell Server (port ${port})
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=${snell_binary_path} -c ${conf} --loglevel warning
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    [[ -s "/etc/systemd/system/snell@${port}.service" ]] || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now "snell@${port}" || return 1
    success "Systemd 服务实例 snell@${port} 已安装并启动"
}

install_service_openrc() {
    local port=$1 conf="$2"
    info "安装 OpenRC 服务实例 (snell.${port})..."
    cat >"/etc/init.d/snell.${port}" <<EOF
#!/sbin/openrc-run
name="snell-${port}"
description="Snell Server (port ${port})"
command="${snell_binary_path}"
command_args="-c ${conf} --loglevel warning"
command_background=true
pidfile="/run/snell-${port}.pid"
start_stop_daemon_args="--make-pidfile --background"

depend() {
  need net
  use dns
}
EOF
    [[ -s "/etc/init.d/snell.${port}" ]] || return 1
    chmod +x "/etc/init.d/snell.${port}" || return 1
    rc-update add "snell.${port}" default || return 1
    rc-service "snell.${port}" restart || rc-service "snell.${port}" start || return 1
    success "OpenRC 服务实例 snell.${port} 已安装并启动"
}

# setup_service <port> <listen>
# listen 用于决定服务是否绑定了 IPv6 地址 (v6-only 机器需要 [::] 才能对外)
setup_service() {
    local port=$1 listen=$2
    local conf="${snell_config_dir}/snell-server-${port}.conf"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then install_service_systemd "$port" "$conf"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then install_service_openrc "$port" "$conf"
    else error "无法确定服务管理器，请手动配置自启动。"; return 1; fi
}

service_restart() {
    local port=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart "snell@${port}" || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service "snell.${port}" restart || return 1
    else error "无法确定服务管理器，请手动重启 snell@${port}。"; return 1; fi
    sleep 1
    service_is_active "$port"
}

service_is_active() {
    local port=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active --quiet "snell@${port}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service "snell.${port}" status >/dev/null 2>&1 && rc-service "snell.${port}" status 2>/dev/null | grep -qi started
    else return 1; fi
}

service_stop_disable() {
    local port=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "snell@${port}" 2>/dev/null || true
        systemctl disable "snell@${port}" 2>/dev/null || true
        rm -f "/etc/systemd/system/snell@${port}.service"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "snell.${port}" stop 2>/dev/null || true
        rc-update del "snell.${port}" default 2>/dev/null || true
        rm -f "/etc/init.d/snell.${port}"
    fi
}

check_snell_status() {
    if [[ ! -f "$snell_binary_path" ]]; then snell_status_info="  Snell 状态: ${red}未安装${none}"; return; fi
    local snell_version
    snell_version=$(installed_snell_version 2>/dev/null || echo "未知")
    local count
    count=$(snell_node_count 2>/dev/null || echo 0)
    snell_status_info="  Snell 状态: ${green}已安装${none} | 版本: ${cyan}${snell_version}${none} | 节点: ${cyan}${count}${none} 个"
}

# --- 配置文件读写 ---
# snell-server conf 是扁平 [snell-server] 单表 INI, 键值一行一个,
# 每个端口一个独立文件, 不存在多块追加/删除的问题, 比 mihomo 的 YAML 简单得多。
snell_conf_path() { printf '%s/snell-server-%s.conf' "$snell_config_dir" "$1"; }

list_snell_ports() {
    local p
    for p in "${snell_config_dir}"/snell-server-*.conf; do
        [[ -f "$p" ]] || continue
        basename "$p" | sed -E 's/^snell-server-([0-9]+)\.conf$/\1/'
    done | sort -n
}

snell_node_count() {
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    [[ -z "$ports" ]] && { echo 0; return; }
    printf '%s\n' "$ports" | wc -l | tr -d ' '
}

# 从 conf 中读取原始键值 (单表扁平结构, 行扫描足够可靠)
read_conf_key() {
    local conf=$1 key=$2
    [[ -f "$conf" ]] || return 1
    python3 - "$conf" "$key" <<'PY'
import json, sys

path, key = sys.argv[1:3]
with open(path, encoding='utf-8') as f:
    for raw in f:
        line = raw.split('#', 1)[0].strip()
        if line.startswith('['):
            continue
        if '=' not in line:
            continue
        k, _, v = line.partition('=')
        if k.strip() == key:
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                v = v[1:-1]
            print(v)
            break
PY
}

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat &>/dev/null; then netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof &>/dev/null; then lsof -i ":$port" &>/dev/null && return 0
    else (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0; fi
    # 已有 snell conf 即代表服务(重启后)会占用该端口, 防止服务未运行时漏掉内部冲突
    [[ -f "$(snell_conf_path "$port")" ]] && return 0
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
    archive=$(mktemp "/root/snell-config-backup-$(date +%Y%m%d%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C "$(dirname "$snell_config_dir")" "$(basename "$snell_config_dir")"; then
        rm -f "$archive"
        return 1
    fi
    chmod 600 "$archive" || return 1
    printf '%s\n' "$archive"
}

# 写入节点配置 (原子写入: mkstemp + os.replace, 权限沿用原文件)
write_snell_conf() {
    local port=$1 listen=$2 psk=$3 mode=$4 dns_pref=$5
    local conf
    conf=$(snell_conf_path "$port")
    mkdir -p "$snell_config_dir" || return 1

    local config_backup=""
    if [[ -f "$conf" ]]; then
        config_backup=$(backup_config "$conf") || return 1
    fi

    if ! python3 - "$conf" "$listen" "$psk" "$mode" "$dns_pref" <<'PY'
import os, stat, sys, tempfile

conf, listen, psk, mode, dns_pref = sys.argv[1:6]

def ini_str(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

lines = [
    '[snell-server]',
    f'listen = {ini_str(listen)}',
    f'psk = {ini_str(psk)}',
]
# mode / dns-ip-preference 只在非默认值时写入, 保持配置文件干净;
# 默认值 (default / default) 由服务端自行采用, 显式写出反而碍日后手工编辑。
if mode != 'default':
    lines.append(f'mode = {ini_str(mode)}')
if dns_pref != 'default':
    lines.append(f'dns-ip-preference = {ini_str(dns_pref)}')

content = '\n'.join(lines) + '\n'

directory = os.path.dirname(conf) or '.'
fd, tmp = tempfile.mkstemp(prefix='.snell-conf.', dir=directory, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(content)
    if os.path.exists(conf):
        os.chmod(tmp, stat.S_IMODE(os.stat(conf).st_mode))
    else:
        os.chmod(tmp, 0o600)
    os.replace(tmp, conf)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
    then
        [[ -n "$config_backup" ]] && cp "$config_backup" "$conf"
        error "写入配置失败，已恢复原配置。"
        return 1
    fi

    chmod 600 "$conf"
    success "节点配置已写入: $conf"
}

# --- 运行前配置探测 ---
# snell-server 没有 -t 校验模式, 坏配置只在启动时以退出码失败。
# 不能拿真实配置起第二个实例: 已运行的服务占着同样的端口,
# 探测必然报 bind 冲突。因此探测时把 listen 端口换成本机临时空闲端口,
# 只验证 conf 能被解析、psk 合法、mode 合法, 起来后立刻杀掉。
probe_snell_conf() {
    [[ -x "$snell_binary_path" ]] || return 0

    local port=$1
    local conf
    conf=$(snell_conf_path "$port") || return 1
    [[ -f "$conf" ]] || return 1

    local probe_dir
    probe_dir=$(mktemp -d) || return 1

    # 改写端口会绕掉原地址的合法性校验, 所以先自己验一遍 listen,
    # 只有形如 host:port (或逗号多地址) 的才允许被替换。
    if ! python3 - "$conf" "${probe_dir}/probe.conf" <<'PY'
import re, socket, sys

src, dst = sys.argv[1:3]

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port

def addr_ok(addr):
    if ':' not in addr:
        return False
    host, _, port = addr.rpartition(':')
    # 方括号成对剥一层, 与 is_valid_listen_list 的判定保持一致
    m = re.fullmatch(r'\[(.+)\]', host)
    inner = m.group(1) if m else host
    if not inner or not port.isdigit():
        return False
    return 1 <= int(port) <= 65535

with open(src, encoding='utf-8') as f:
    lines = f.readlines()

out, bad = [], []
for raw in lines:
    stripped = raw.split('#', 1)[0].strip()
    if stripped.startswith('listen') and '=' in stripped:
        value = stripped.partition('=')[2].strip().strip('"')
        addrs = [a.strip() for a in value.split(',') if a.strip()]
        if not addrs or any(not addr_ok(a) for a in addrs):
            bad.append(value)
            out.append(raw)
            continue
        # 全部换到临时端口, host 收敛到 127.0.0.1 避免纯 v6 环境反解析问题
        out.append('listen = "127.0.0.1:%d"\n' % free_port())
    else:
        out.append(raw)

with open(dst, 'w', encoding='utf-8') as f:
    f.writelines(out)

if bad:
    print('invalid listen address: ' + ', '.join(bad), file=sys.stderr)
    raise SystemExit(3)
PY
    then
        rm -rf "$probe_dir"
        error "listen 地址不合法。"
        return 1
    fi

    local log_file="${probe_dir}/probe.log"
    "$snell_binary_path" -c "${probe_dir}/probe.conf" >"$log_file" 2>&1 &
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

    # 进程退出、或日志里出现 Parameter/Invalid 报错, 都视为配置不可用
    if [[ "$alive" == "false" ]] || grep -qiE "parameter|invalid|failed|error" "$log_file" 2>/dev/null; then
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
    info "正在重启 snell@${port} 服务..."
    if ! service_restart "$port"; then
        error "重启失败，请查看日志 (journalctl -u snell@${port} 或 /var/log/snell)"
        return 1
    fi
    success "snell@${port} 服务已成功重启！"
}

# --- 自定义连接地址管理 ---
set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "说明: 如果服务器是 NAT VPS, 或对外地址与网卡地址不同,"
    echo "请在此填入实际用于外部连接的 IP 或 DDNS 域名,"
    echo "脚本生成节点信息时会优先使用它。"
    echo "-------------------------------------------------"
    if [[ -f "$address_file" ]]; then
        local current_addr=$(cat "$address_file")
        echo -e "当前已设置: ${cyan}${current_addr}${none}"
    else
        echo -e "当前状态: ${yellow}自动获取公网 IP${none}"
    fi
    echo ""
    read -p "请输入新的连接地址 (留空并回车则恢复自动获取): " new_addr
    if [[ -z "$new_addr" ]]; then
        rm -f "$address_file"; success "已恢复为自动获取公网 IP 模式。"
    else
        local normalized_addr
        if ! normalized_addr=$(normalize_connection_address "$new_addr"); then
            error "连接地址无效，请输入纯 IP 地址或域名（不要包含协议和端口）。"
            return 1
        fi
        printf '%s\n' "$normalized_addr" > "$address_file"
        chmod 600 "$address_file"
        success "连接地址已更新为: $normalized_addr"
    fi
}

# --- 节点信息展示 (Mihomo 客户端 YAML 片段) ---
# Snell 没有 URI 分享链接格式, 官方客户端 (Surge) 走 GUI 导入;
# mihomo 用户直接复制 proxies 片段即可。version: 6 需要 mihomo >= 1.19.34。
view_node_info() {
    local target_port="${1:-}"

    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell 节点配置。"; return; fi

    if [[ -z "$target_port" ]]; then
        local count; count=$(printf '%s\n' "$ports" | wc -l | tr -d ' ')
        if [[ "$count" -eq 1 ]]; then
            target_port="$ports"
        else
            echo "当前 Snell 节点列表:"
            local p
            for p in $ports; do
                echo " - 端口: ${cyan}${p}${none}"
            done
            echo ""
            while true; do
                read -p "请输入要查看的端口: " input_p
                if printf '%s\n' "$ports" | grep -qx "$input_p"; then target_port="$input_p"; break
                else error "未找到该端口"; fi
            done
        fi
    fi

    local conf
    conf=$(snell_conf_path "$target_port")
    [[ -f "$conf" ]] || { error "端口 $target_port 的节点配置不存在。"; return 1; }

    local psk mode
    psk=$(read_conf_key "$conf" "psk" 2>/dev/null || true)
    mode=$(read_conf_key "$conf" "mode" 2>/dev/null || true)
    [[ -z "$mode" ]] && mode="default"

    local ip
    if [[ -f "$address_file" && -s "$address_file" ]]; then
        ip=$(cat "$address_file"); [[ -z "$ip" ]] && ip=$(get_public_ip)
    else ip=$(get_public_ip); fi
    [[ -z "$ip" ]] && { error "无法确定连接地址。"; return 1; }

    local ipinfo_json country org link_name
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null || true)
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | sed 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        org=$(echo "$ipinfo_json" | grep '"org"' | sed 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then link_name="${country} - ${org}"
    else link_name="snell-${target_port}"; fi

    # mihomo proxies 片段: JSON 字符串也是合法的 YAML 标量,
    # 可避免 PSK 中的引号、# 等字符破坏配置。
    local client_yaml
    client_yaml=$(python3 -c '
import json, sys
name, server, port, psk, mode = sys.argv[1:6]
lines = [
    "  - name: " + json.dumps(name, ensure_ascii=False),
    "    type: snell",
    "    server: " + json.dumps(server, ensure_ascii=False),
    "    port: " + port,
    "    psk: " + json.dumps(psk, ensure_ascii=False),
    "    version: 6",
]
if mode != "default":
    lines.append("    mode: " + json.dumps(mode, ensure_ascii=False))
lines.append("    udp: true")
print("\n".join(lines))' "$link_name" "$ip" "$target_port" "$psk" "$mode" 2>/dev/null) || {
        error "生成客户端配置片段失败。"
        return 1
    }

    local save_file="/root/mihomo_snell_link_${target_port}.txt"

    if [[ "$is_quiet" == true ]]; then
        printf '%s\n' "$client_yaml"
        return
    fi

    echo "----------------------------------------------------------------"
    echo -e "${green} --- Snell 节点信息 (v${snell_tag#v}) --- ${none}"
    echo -e "${yellow} 地址: ${cyan}${ip}${none}"
    echo -e "${yellow} 端口: ${cyan}${target_port}${none}"
    echo -e "${yellow} PSK:  ${cyan}${psk}${none}"
    echo -e "${yellow} 模式: ${cyan}${mode}${none}"
    echo "----------------------------------------------------------------"
    echo -e "${green} Mihomo 客户端 proxies 片段 (已保存到 $save_file):${none}\n"
    echo -e "${cyan}${client_yaml}${none}"
    echo "----------------------------------------------------------------"
    echo -e "${yellow}[!] 需要 mihomo >= 1.19.34; Surge 客户端请在 GUI 中手动添加。"
    echo -e "    mode 需与服务端一致 (default 可省略不写)。${none}"
    echo "----------------------------------------------------------------"
    printf '%s\n' "$client_yaml" > "$save_file"
    chmod 600 "$save_file"
}

# --- 交互向导 ---
select_psk_and_mode() {
    echo ""
    echo "请选择 Snell v6 加密模式 (mode):"
    echo -e "  ${green}1.${none} default      (推荐; PSK 派生流量整形, 抗特征分析)"
    echo -e "  ${cyan}2.${none} unshaped     (无整形层, 兼容性更好, 隐蔽性略低)"
    echo -e "  ${red}3.${none} unsafe-raw   (关闭加密, 仅调试/内网用途)"
    read -p "请输入选项 [1-3] (默认 1): " mode_choice
    [ -z "$mode_choice" ] && mode_choice=1
    case $mode_choice in
        1) SNELL_MODE="default" ;;
        2) SNELL_MODE="unshaped" ;;
        3) SNELL_MODE="unsafe-raw"
           warn "unsafe-raw 模式不加密流量, 仅建议内网或调试场景使用。" ;;
        *) error "无效选择，默认使用 default"; SNELL_MODE="default" ;;
    esac

    echo ""
    echo -ne "请输入 PSK (留空生成随机 16 字节 Base64 密钥): "
    read user_psk
    if [[ -z "$user_psk" ]]; then
        SNELL_PSK=$(openssl rand -base64 16 | tr -d '\n')
        info "已自动生成 PSK: ${cyan}${SNELL_PSK}${none}"
    else
        SNELL_PSK="$user_psk"
    fi
}

install_snell_node() {
    if [[ -f "$snell_binary_path" ]]; then
        info "检测到 snell-server 已安装。继续操作将添加新的节点。"
    fi

    local port
    while true; do
        read -p "$(echo -e "监听端口 [1-65535] (默认: ${cyan}6160${none}): ")" port
        [ -z "$port" ] && port=6160
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done

    echo ""
    echo -e "${yellow}[!] 监听地址一般用 0.0.0.0 (仅 IPv4)。"
    echo -e "    需要 IPv4+IPv6 双栈时填 0.0.0.0:端口,[::]:端口 (逗号分隔);"
    echo -e "    纯 IPv6 机器请填 [::]:端口。${none}"
    local listen_host=""
    read -p "$(echo -e "监听地址 (默认: ${cyan}0.0.0.0${none}): ")" listen_host
    [[ -z "$listen_host" ]] && listen_host="0.0.0.0"

    select_psk_and_mode

    local dns_pref="default"
    echo ""
    echo -e "${yellow}[!] dns-ip-preference 控制服务端解析目标域名时的协议栈偏好,"
    echo -e "    一般保持 default 即可; 出口为纯 IPv6 时可设 ipv6-only。${none}"
    read -p "$(echo -e "dns-ip-preference [default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only] (默认: ${cyan}default${none}): ")" input_pref
    [[ -n "$input_pref" ]] && dns_pref="$input_pref"

    # 校验全部字段
    if ! is_valid_psk "$SNELL_PSK"; then
        error "PSK 长度必须为 ${snell_psk_min_len}-${snell_psk_max_len} 字节。"; return 1
    fi
    if ! is_valid_mode "$SNELL_MODE"; then error "mode 无效: $SNELL_MODE"; return 1; fi
    if ! is_valid_dns_pref "$dns_pref"; then error "dns-ip-preference 无效: $dns_pref"; return 1
    fi

    # 组装 listen: 裸 IPv6 自动加方括号; 多地址逐个括号化后拼接
    local listen="${listen_host}:${port}"
    if [[ "$listen_host" == *,* ]]; then
        listen=$(python3 -c '
import sys
addrs = sys.argv[1:]
def bracket(a):
    return "[%s]" % a if ":" in a and not a.startswith("[") else a
print(",".join(bracket(a) for a in addrs))' ${listen_host//,/ } "$port")
    fi

    if ! is_valid_listen_list "$listen"; then
        error "监听地址格式无效: $listen"; return 1
    fi

    run_install_node "$port" "$listen" "$SNELL_PSK" "$SNELL_MODE" "$dns_pref" || return 1
    view_node_info "$port"
}

run_install_node() {
    local port=$1 listen=$2 psk=$3 mode=$4 dns_pref=$5

    if [[ ! -x "$snell_binary_path" ]]; then
        install_snell_core || return 1
    fi

    write_snell_conf "$port" "$listen" "$psk" "$mode" "$dns_pref" || return 1

    # 顺序要紧: 探测必须早于 setup_service / restart。
    # 服务一旦起来就占住真实端口, 晚探测会和它抢端口误报失败。
    if ! probe_snell_conf "$port"; then
        rm -f "$(snell_conf_path "$port")"
        error "snell-server 无法加载新配置，已移除该节点。"
        return 1
    fi

    if ! setup_service "$port" "$listen"; then
        rm -f "$(snell_conf_path "$port")"
        error "服务安装失败，已移除该节点。"
        return 1
    fi

    if ! restart_snell_node "$port"; then
        rm -f "$(snell_conf_path "$port")"
        service_stop_disable "$port" >/dev/null 2>&1 || true
        error "节点启动失败，已移除该节点。"
        return 1
    fi
    success "Snell 节点 (端口 ${port}) 安装完成！"
}

# listen 列表校验: 逗号分隔的 host:port / [v6]:port, host 必须是 IP (本地 bind)。
# 方括号只能成对剥掉一层 (fullmatch), 不能用 strip("[]") 逐字符剥,
# 否则 "::]" 这类残缺输入会被剥成合法的 "::" 而漏过校验。
is_valid_listen_list() {
    python3 -c '
import ipaddress, re, sys
for addr in sys.argv[1].split(","):
    addr = addr.strip()
    if ":" not in addr:
        raise SystemExit(1)
    host, _, port = addr.rpartition(":")
    if not host or not port.isdigit() or not 1 <= int(port) <= 65535:
        raise SystemExit(1)
    m = re.fullmatch(r"\[(.+)\]", host)
    inner = m.group(1) if m else host
    try:
        ipaddress.ip_address(inner)
    except ValueError:
        raise SystemExit(1)' "$1" 2>/dev/null
}

delete_snell_node() {
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell 节点，无需删除。"; return; fi

    echo "当前 Snell 节点:"
    local p
    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要删除的端口: " target_p
        if printf '%s\n' "$ports" | grep -qx "$target_p"; then break
        else error "未找到该端口"; fi
    done

    read -p "确定要永久删除端口 $target_p 的 Snell 节点吗？[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi

    info "正在删除节点..."
    local conf
    conf=$(snell_conf_path "$target_p")
    local delete_backup
    delete_backup=$(backup_config "$conf" 2>/dev/null) || { error "备份配置失败"; return 1; }

    rm -f "$conf"
    service_stop_disable "$target_p"
    [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload || true
    rm -f "/root/mihomo_snell_link_${target_p}.txt"

    success "Snell 节点 (端口 $target_p) 已删除。配置备份: $delete_backup"
}

modify_config() {
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell 节点。"; return; fi

    echo "当前 Snell 节点:"
    local p
    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要修改的端口: " target_p
        if printf '%s\n' "$ports" | grep -qx "$target_p"; then break
        else error "未找到该端口"; fi
    done

    info "注意：修改将重写该端口配置并重启服务。"
    select_psk_and_mode

    local dns_pref="default"
    read -p "$(echo -e "dns-ip-preference [default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only] (默认: ${cyan}default${none}): ")" input_pref
    [[ -n "$input_pref" ]] && dns_pref="$input_pref"

    if ! is_valid_psk "$SNELL_PSK"; then
        error "PSK 长度必须为 ${snell_psk_min_len}-${snell_psk_max_len} 字节。"; return 1
    fi
    if ! is_valid_mode "$SNELL_MODE"; then error "mode 无效: $SNELL_MODE"; return 1; fi
    if ! is_valid_dns_pref "$dns_pref"; then error "dns-ip-preference 无效: $dns_pref"; return 1; fi

    # 端口与监听地址保持不变, 只重写凭据与偏好
    local conf listen
    conf=$(snell_conf_path "$target_p")
    listen=$(read_conf_key "$conf" "listen" 2>/dev/null || true)
    if [[ -z "$listen" ]]; then
        error "读取原 listen 失败, 取消修改。"; return 1
    fi

    local modify_backup
    modify_backup=$(backup_config "$conf") || { error "备份配置失败"; return 1; }

    if ! write_snell_conf "$target_p" "$listen" "$SNELL_PSK" "$SNELL_MODE" "$dns_pref" || ! probe_snell_conf "$target_p"; then
        cp "$modify_backup" "$conf"
        error "修改失败，已恢复原配置。"
        return 1
    fi
    if ! restart_snell_node "$target_p"; then
        cp "$modify_backup" "$conf"
        service_restart "$target_p" >/dev/null 2>&1 || true
        error "修改后服务未能正常启动，已恢复原配置。"
        return 1
    fi
    success "修改完成"
    view_node_info "$target_p"
}

update_snell() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server 未安装" && return; fi
    info "正在检查最新版本..."
    local current_version latest_version
    current_version=$(installed_snell_version 2>/dev/null || echo "未知")
    # 官方 dl.nssurge.com 无 API/无 latest 短链, 探测已知版本号列表中的最高可用项
    latest_version=$(snell_latest_known_version) || { error "探测最新版本失败" && return; }
    info "当前: ${cyan}${current_version}${none}，最新: ${cyan}${latest_version}${none}"
    if [[ "$current_version" == *"${latest_version}"* ]]; then
        success "已是最新版本。"; return
    fi
    if ! install_snell_core; then error "更新失败！" && return; fi

    # 逐个重启现有节点
    local p
    for p in $(list_snell_ports 2>/dev/null || true); do
        restart_snell_node "$p" || return 1
    done
    success "snell-server 更新成功！"
}

# 官方不提供版本 API; 依次探测已知 tag 的下载可用性, 取最高的 200。
snell_latest_known_version() {
    local tags=("v6.0.0" "v5.0.0" "v4.1.1")
    local t url code
    for t in "${tags[@]}"; do
        url="${snell_download_base}/snell-server-${t}-linux-amd64.zip"
        code=$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 8 "$url" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
            printf '%s\n' "snell-server ${t#v}"
            return 0
        fi
    done
    return 1
}

uninstall_snell() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server 未安装" && return; fi
    read -p "确定卸载 snell-server 吗？配置会先自动备份。[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消。"; return; fi
    local config_archive=""
    if ! config_archive=$(backup_config_archive); then
        error "配置备份失败，已取消卸载，未删除任何文件。"
        return 1
    fi
    info "正在卸载..."
    local p
    for p in $(list_snell_ports 2>/dev/null || true); do
        service_stop_disable "$p"
    done
    [[ "$INIT_SYSTEM" == "systemd" ]] && systemctl daemon-reload || true
    rm -f "$snell_binary_path"
    rm -rf "$snell_config_dir"
    rm -f /root/mihomo_snell_link_*.txt
    success "snell-server 已成功卸载；配置备份: $config_archive"
    info "说明: /root/inbound_address.txt 由本套脚本共用, 未删除。"
}

view_snell_log() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server 未安装" && return; fi
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell 节点。"; return; fi
    local target_p
    if [[ $(printf '%s\n' "$ports" | wc -l | tr -d ' ') -eq 1 ]]; then
        target_p="$ports"
    else
        echo "当前 Snell 节点:"
        local p
        for p in $ports; do echo " - 端口: $p"; done
        echo ""
        while true; do
            read -p "请输入要查看日志的端口: " target_p
            if printf '%s\n' "$ports" | grep -qx "$target_p"; then break
            else error "未找到该端口"; fi
        done
    fi
    info "显示 snell@${target_p} 日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        journalctl -u "snell@${target_p}" -f --no-pager || true
    else
        error "OpenRC 下请直接查看 /var/log/messages 或服务输出。"
    fi
    trap - SIGINT; echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

test_connectivity() {
    if [[ ! -f "$snell_binary_path" ]]; then error "snell-server 未安装" && return; fi
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell 节点。"; return; fi

    echo "连通性测试 (本机连监听端口, 看能否建立 TCP):"
    local p
    for p in $ports; do
        if (echo > "/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1; then
            echo -e " ${green}✔${none} 端口 ${p}  (本地 TCP 可连接)"
        else
            echo -e " ${red}✖${none} 端口 ${p}  (本地 TCP 连不上, 检查服务是否运行)"
        fi
    done
    echo ""
    echo -e "${yellow}[!] 这里只验证本地监听是否存活。"
    echo -e "    真正能否代理流量, 需要从外部用客户端实测。${none}"
}

press_any_key_to_continue() {
    echo ""; read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear
        echo -e "${cyan} Snell 服务端 一键安装管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${yellow} Surge 官方 snell-server v6, 独立服务运行;"
        echo -e " 客户端用 Mihomo (>= 1.19.34) 或 Surge 连接${none}"
        echo "---------------------------------------------"
        check_snell_status
        echo -e "${snell_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/添加 Snell 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 snell-server"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Snell 服务"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 snell-server"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Snell 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改/重置节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看节点信息"
        printf "  ${cyan}%-2s${none} %-35s\n" "8." "测试连通性"
        printf "  ${red}%-2s${none} %-35s\n" "9." "删除指定节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "0." "设置连接地址 (NAT/DDNS) 并退出"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-9]: " choice

        local needs_pause=true
        case $choice in
            1) install_snell_node ;;
            2) update_snell ;;
            3) restart_snell_menu ;;
            4) uninstall_snell ;;
            5) view_snell_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_node_info "" ;;
            8) test_connectivity ;;
            9) delete_snell_node ;;
            0) set_connection_address; success "感谢使用！"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        if [ "$needs_pause" = true ]; then press_any_key_to_continue; fi
    done
}

restart_snell_menu() {
    local ports
    ports=$(list_snell_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then error "未找到任何 Snell 节点。"; return; fi
    local target_p
    if [[ $(printf '%s\n' "$ports" | wc -l | tr -d ' ') -eq 1 ]]; then
        restart_snell_node "$ports"
        return
    fi
    echo "当前 Snell 节点:"
    local p
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    while true; do
        read -p "请输入要重启的端口: " target_p
        if printf '%s\n' "$ports" | grep -qx "$target_p"; then break
        else error "未找到该端口"; fi
    done
    restart_snell_node "$target_p"
}

# --- 非交互安装 (flag 模式) ---
install_snell_noninteractive() {
    local port="" psk="" mode="default" dns_pref="default" listen_host="0.0.0.0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|--psk|--mode|--dns-ip-preference|--listen-host)
                [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; exit 1; }
                case "$1" in
                    --port) port="$2" ;;
                    --psk) psk="$2" ;;
                    --mode) mode="$2" ;;
                    --dns-ip-preference) dns_pref="$2" ;;
                    --listen-host) listen_host="$2" ;;
                esac
                shift 2
                ;;
            --quiet|-q) is_quiet=true; shift ;;
            *) error "未知参数: $1"; exit 1 ;;
        esac
    done

    [[ -z "$port" ]] && port=6160
    if ! is_valid_port "$port"; then error "端口无效: $port" && exit 1; fi
    if [[ -z "$psk" ]]; then
        psk=$(openssl rand -base64 16 | tr -d '\n')
    elif ! is_valid_psk "$psk"; then
        error "PSK 长度必须为 ${snell_psk_min_len}-${snell_psk_max_len} 字节。" && exit 1
    fi
    if ! is_valid_mode "$mode"; then error "mode 无效: $mode (default/unshaped/unsafe-raw)" && exit 1; fi
    if ! is_valid_dns_pref "$dns_pref"; then error "dns-ip-preference 无效: $dns_pref" && exit 1; fi
    if is_port_in_use "$port"; then error "端口 $port 已被占用。" && exit 1; fi

    # 组装 listen: 多地址/裸 IPv6 统一括号化
    local listen="${listen_host}:${port}"
    if [[ "$listen_host" == *,* ]]; then
        listen=$(python3 -c '
import sys
addrs = sys.argv[1:]
def bracket(a):
    return "[%s]" % a if ":" in a and not a.startswith("[") else a
print(",".join(bracket(a) for a in addrs))' ${listen_host//,/ } "$port")
    fi
    if ! is_valid_listen_list "$listen"; then error "监听地址无效: $listen" && exit 1; fi

    run_install_node "$port" "$listen" "$psk" "$mode" "$dns_pref" || exit 1
    view_node_info "$port"
}

main() {
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
