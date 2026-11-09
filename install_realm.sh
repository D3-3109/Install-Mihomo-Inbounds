#!/bin/bash

# ==============================================================================
# Realm 端口转发 一键安装管理脚本
# 使用 realm 作为纯 TCP/UDP 转发服务端，与 Mihomo 节点配合做落地/中转
# 版本: V-Realm-Forward-1.0
# 功能:
# - 安装/管理 realm 转发 (单端口 TCP+UDP 或纯 TCP)
# - 智能追加配置 (不覆盖已有 endpoints)
# - 多端口/多转发管理
# - 支持自定义连接地址 (NAT/DDNS)
# - 精准删除指定转发
#
# 说明: realm 与 mihomo 是两个独立服务, 配置目录、服务单元、二进制互不干扰。
# 典型用法是把 realm 装在中转机上, 把落地机的 mihomo 节点端口转发出去。
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-Realm-Forward-1.0"
readonly realm_config_dir="/usr/local/etc/realm"
readonly realm_config_path="${realm_config_dir}/config.toml"
readonly realm_binary_path="/usr/local/bin/realm"
readonly realm_service_name="realm"
readonly address_file="/root/inbound_address.txt"
readonly realm_repo="zhboner/realm"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
realm_status_info=""
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

# --- 地址校验 ---
# realm 对地址只做 split(':') + parse 后 panic, 没有配置校验模式,
# 因此坏地址必须在这里挡掉, 否则服务会以 panic (exit 101) 直接退出。
is_valid_port() { local port=$1; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; }

is_valid_domain() { local domain=$1; [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]; }

# listen 只接受 ip:port (v4/v6), 因为 realm 用它做本地 bind
is_valid_listen() {
    local addr=$1
    [[ "$addr" == *:* ]] || return 1
    local host="${addr%:*}" port="${addr##*:}"
    is_valid_port "$port" || return 1
    host="${host#[}"; host="${host%]}"
    [[ -n "$host" ]] || return 1
    if [[ "$host" =~ ^[0-9.]+$ ]]; then return 0; fi
    if [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]; then return 0; fi
    return 1
}

# remote 接受 ip:port / [v6]:port / domain:port
is_valid_remote() {
    local addr=$1
    [[ "$addr" == *:* ]] || return 1
    local host="${addr%:*}" port="${addr##*:}"
    is_valid_port "$port" || return 1
    host="${host#[}"; host="${host%]}"
    [[ -n "$host" ]] || return 1
    if [[ "$host" =~ ^[0-9.]+$ ]]; then return 0; fi
    if [[ "$host" =~ ^[0-9A-Fa-f:]+$ ]]; then return 0; fi
    is_valid_domain "$host"
}

# --- 核心安装逻辑 ---
install_realm_core() {
    info "开始安装 realm 核心..."
    local arch machine; machine="$(uname -m)"
    # 一律用 musl 静态构建: 不依赖目标机的 glibc 版本, Alpine / 老 Debian 都能跑
    case "$machine" in
        x86_64|amd64) arch="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) arch="aarch64-unknown-linux-musl" ;;
        armv7|armv7l) arch="armv7-unknown-linux-musleabihf" ;;
        armv6l) arch="arm-unknown-linux-musleabihf" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac

    local api="https://api.github.com/repos/${realm_repo}/releases/latest"
    info "获取 realm 最新版本信息..."
    local tag
    tag="$(curl -fsSL "$api" | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    if [[ -z "${tag:-}" ]]; then
        error "无法获取 realm 最新版本号 (GitHub API 受限?)"
        return 1
    fi
    info "目标版本: $tag"

    local tmpdir; tmpdir="$(mktemp -d)" || return 1
    local filename="realm-${arch}.tar.gz"
    local url="https://github.com/${realm_repo}/releases/download/${tag}/${filename}"

    info "正在下载 realm ($filename)..."
    if ! curl -fL "$url" -o "$tmpdir/realm.tar.gz"; then
        rm -rf "$tmpdir"; error "下载 realm 失败: $url"; return 1
    fi

    info "解压并安装到 /usr/local/bin ..."
    if ! tar -xzf "$tmpdir/realm.tar.gz" -C "$tmpdir" || [[ ! -f "$tmpdir/realm" ]]; then
        rm -rf "$tmpdir"; error "解压 realm 失败。"; return 1
    fi
    if ! chmod +x "$tmpdir/realm" || ! "$tmpdir/realm" --version >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        error "下载的 realm 无法执行，已取消安装。"
        return 1
    fi
    install -m 0755 "$tmpdir/realm" "$realm_binary_path" || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$realm_config_dir" || return 1
    rm -rf "$tmpdir"
    success "realm 核心安装完成"
}

installed_realm_version() {
    [[ -x "$realm_binary_path" ]] || return 1
    "$realm_binary_path" --version 2>/dev/null | head -n 1 | awk '{print $2}'
}

# --- Systemd 服务安装 ---
install_service_systemd() {
    info "安装 Systemd 服务 (User=root)..."
    cat >/etc/systemd/system/realm.service <<'EOF'
[Unit]
Description=Realm Relay Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/realm -c /usr/local/etc/realm/config.toml --log-level warn --log-output stdout
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    [[ -s /etc/systemd/system/realm.service ]] || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now realm || return 1
    success "Systemd 服务已安装并启动"
}

install_service_openrc() {
    info "安装 OpenRC 服务..."
    install -d -m 0755 /var/log/realm || true
    cat >/etc/init.d/realm <<'EOF'
#!/sbin/openrc-run
name="realm"
description="Realm Relay Service"
command="/usr/local/bin/realm"
command_args="-c /usr/local/etc/realm/config.toml --log-level warn --log-output stdout"
command_background=true
pidfile="/run/realm.pid"
start_stop_daemon_args="--make-pidfile --background"

depend() {
  need net
  use dns
}
EOF
    [[ -s /etc/init.d/realm ]] || return 1
    chmod +x /etc/init.d/realm || return 1
    rc-update add realm default || return 1
    rc-service realm restart || rc-service realm start || return 1
    success "OpenRC 服务已安装并启动"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then install_service_systemd
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then install_service_openrc
    else error "无法确定服务管理器，请手动配置自启动。"; return 1; fi
}

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID=${ID:-}; fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="unknown"; fi
}

service_restart() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart realm || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service realm restart || return 1
    else error "无法确定服务管理器，请手动重启 realm。"; return 1; fi
    sleep 1
    service_is_active
}

service_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active --quiet realm
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service realm status >/dev/null 2>&1 && rc-service realm status 2>/dev/null | grep -qi started
    else return 1; fi
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
    local required_commands=("awk" "grep" "sed" "curl" "python3" "gzip" "install" "mktemp" "tar")
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd"); done
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing_commands[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache bash curl python3 gzip coreutils
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl python3 gzip coreutils
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

check_realm_status() {
    if [[ ! -f "$realm_binary_path" ]]; then realm_status_info="  Realm 状态: ${red}未安装${none}"; return; fi
    local realm_version
    realm_version=$(installed_realm_version 2>/dev/null || echo "未知")
    local service_status
    if service_is_active; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    local count
    count=$(realm_forward_count 2>/dev/null || echo 0)
    realm_status_info="  Realm 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${realm_version}${none} | 转发: ${cyan}${count}${none} 条"
}

# --- 配置文件初始化 ---
init_realm_config() {
    if [[ ! -f "$realm_config_path" ]]; then
        info "配置文件不存在，创建新配置..."
        mkdir -p "$realm_config_dir" || return 1
        cat > "$realm_config_path" <<'TOML'
# Realm 转发服务端配置
# 由 install_realm.sh 维护, 手工改动请先备份

[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = true
TOML
        chmod 600 "$realm_config_path"
    fi
}

# --- 配置读写 (TOML) ---
# realm 没有配置校验模式; 用 python 解析 TOML 只为定位 endpoint 块边界。
# 全部 [[endpoints]] 块都是无嵌套的扁平 key=value, 行扫描足够可靠,
# 且不必引入 python3 的 tomllib 之外的依赖。
list_forward_listen() {
    [[ -f "$realm_config_path" ]] || return 1
    python3 - "$realm_config_path" <<'PY'
import json, re, sys

path = sys.argv[1]
current = None
entries = []

def scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            return json.loads(value)
        except Exception:
            return value.strip('"')
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value

with open(path, encoding='utf-8') as f:
    for raw in f:
        line = raw.split('#', 1)[0].rstrip() if not raw.lstrip().startswith('#') else ''
        if not line.strip():
            continue
        if line.strip().startswith('[[endpoints]]'):
            if current:
                entries.append(current)
            current = {}
            continue
        if line.strip().startswith('['):
            if current:
                entries.append(current)
            current = None
            continue
        if current is None:
            continue
        m = re.match(r'\s*([A-Za-z0-9_-]+)\s*=\s*(.*)$', line)
        if m:
            current[m.group(1)] = scalar(m.group(2))

if current:
    entries.append(current)

for entry in entries:
    listen = entry.get('listen', '')
    remote = entry.get('remote', '')
    if listen:
        print(f"{listen}\t{remote}")
PY
}

realm_forward_count() {
    local rows
    rows=$(list_forward_listen 2>/dev/null || true)
    [[ -z "$rows" ]] && { echo 0; return; }
    printf '%s\n' "$rows" | wc -l | tr -d ' '
}

# 把 listen 里的端口单独取出, 用于按端口定位
realm_listen_port() {
    local listen=$1
    printf '%s' "${listen##*:}"
}

is_listener_port_in_config() {
    local port=$1 rows
    rows=$(list_forward_listen 2>/dev/null || true)
    [[ -z "$rows" ]] && return 1
    printf '%s\n' "$rows" | while IFS=$'\t' read -r listen _; do
        [[ -z "$listen" ]] && continue
        [[ "$(realm_listen_port "$listen")" == "$port" ]] && echo "$listen"
    done | grep -q .
}

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat &>/dev/null; then netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof &>/dev/null; then lsof -i ":$port" &>/dev/null && return 0
    else (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0; fi
    is_listener_port_in_config "$port" && return 0
    return 1
}

backup_config() {
    local suffix="${1:-bak}"
    local backup
    backup=$(mktemp "${realm_config_path}.${suffix}.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$realm_config_path" "$backup" || { rm -f "$backup"; return 1; }
    chmod 600 "$backup"
    printf '%s\n' "$backup"
}

backup_config_archive() {
    [[ -d "$realm_config_dir" ]] || return 0
    local archive
    archive=$(mktemp "/root/realm-config-backup-$(date +%Y%m%d%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C "$(dirname "$realm_config_dir")" "$(basename "$realm_config_dir")"; then
        rm -f "$archive"
        return 1
    fi
    chmod 600 "$archive" || return 1
    printf '%s\n' "$archive"
}

# --- 追加 endpoint ---
append_endpoint() {
    local listen=$1 remote=$2 use_udp=$3 no_tcp=$4 comment=$5

    init_realm_config || return 1
    local config_backup
    config_backup=$(backup_config "bak") || return 1

    if ! python3 - "$realm_config_path" "$listen" "$remote" "$use_udp" "$no_tcp" "$comment" <<'PY'
import os, re, stat, sys, tempfile

config_path, listen, remote, use_udp, no_tcp, comment = sys.argv[1:7]

def toml_str(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

block = ["[[endpoints]]", f"listen = {toml_str(listen)}", f"remote = {toml_str(remote)}"]

# 端点级 network 覆盖: 只在非默认值时写入, 保持配置文件干净
overrides = []
if no_tcp == "true":
    overrides.append("no_tcp = true")
if use_udp == "false":
    overrides.append("use_udp = false")
if overrides:
    block.append("")
    block.append("[endpoints.network]")
    block.extend(overrides)

# 注释放在 [[endpoints]] 之后而不是之前: 整块自包含,
# 删除时注释随块一起消失, 不会残留在原地错位。
if comment:
    block.insert(1, f"# {comment}")
block_text = '\n'.join(block)

with open(config_path, 'r', encoding='utf-8') as f:
    content = f.read()

# realm 的 toml 顶层必须是 [log]/[network]/[[endpoints]] 这类表, 不能有裸 key,
# 所以新块一律追加到文件末尾, 前面留一个空行。
if content and not content.endswith('\n'):
    content += '\n'
content += '\n' + block_text + '\n'

directory = os.path.dirname(config_path) or '.'
fd, tmp = tempfile.mkstemp(prefix='.config.', dir=directory, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(content)
    os.chmod(tmp, stat.S_IMODE(os.stat(config_path).st_mode))
    os.replace(tmp, config_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
    then
        cp "$config_backup" "$realm_config_path"
        error "写入配置失败，已恢复原配置。"
        return 1
    fi

    chmod 600 "$realm_config_path"
    success "配置已安全追加到: $realm_config_path"
}

# --- 删除 endpoint ---
# 按 listen 精确匹配整块删除。块内不会有嵌套表以外的内容,
# 但要处理 [[endpoints]] 后的 [endpoints.network] 子表。
remove_endpoint() {
    local target_listen=$1
    python3 - "$realm_config_path" "$target_listen" <<'PY'
import json, os, re, stat, sys, tempfile

path, target = sys.argv[1:3]
in_endpoint = False
skip_block = False
block = []
result = []
removed = False

def scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            return json.loads(value)
        except Exception:
            return value.strip('"')
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value

def flush():
    global skip_block, block
    if block and not skip_block:
        result.extend(block)
    block = []
    skip_block = False

with open(path, encoding='utf-8') as f:
    lines = f.readlines()

for raw in lines:
    stripped = raw.split('#', 1)[0].strip() if not raw.lstrip().startswith('#') else ''
    is_endpoint_header = stripped.startswith('[[endpoints]]')
    is_table_header = stripped.startswith('[') and not is_endpoint_header

    if is_endpoint_header:
        flush()
        in_endpoint = True
        block = [raw]
        skip_block = False
        continue

    if is_table_header:
        # [endpoints.network] 属于当前 endpoint; 其他顶层表结束当前块
        if in_endpoint and re.match(r'^\[\s*endpoints\.network\s*\]$', stripped):
            if skip_block:
                continue
            block.append(raw)
            continue
        flush()
        in_endpoint = False
        result.append(raw)
        continue

    if in_endpoint:
        if '=' in stripped:
            key, _, value = stripped.partition('=')
            if key.strip() == 'listen' and scalar(value) == target:
                skip_block = True
                removed = True
        if skip_block:
            continue
        block.append(raw)
        continue

    result.append(raw)

flush()

if not removed:
    raise SystemExit(2)

directory = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(prefix='.config.', dir=directory, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.writelines(result)
    os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

# realm 没有 -t 之类的校验模式, 坏配置只在启动时 panic。
# 不能直接拿真实配置起第二个实例: 已运行的服务 (或刚 setup_service 拉起的服务)
# 已经占着同样的端口, 探测必然报 "Address in use"。
# 更不能只看进程存活: bind 失败时 realm 只 panic 一个 tokio worker, 主进程还在。
# 因此探测用一份把所有 listen 改到临时空闲端口的副本, 并检查日志里的失败标记。
build_probe_config() {
    local probe_dir=$1
    local probe_conf="${probe_dir}/probe.toml"
    # 改写端口会顺带绕掉原地址的合法性校验, 所以先自己验一遍所有 listen,
    # 只有形如 host:port 的才允许被替换。
    python3 - "$realm_config_path" "$probe_conf" <<'PY'
import re, socket, sys

src, dst = sys.argv[1:3]

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port

def listen_ok(addr):
    # host:port 且 port 为 1-65535 的十进制; host 非空
    if ':' not in addr:
        return False
    host, _, port = addr.rpartition(':')
    host = host.strip('[]')
    if not host or not port.isdigit():
        return False
    return 1 <= int(port) <= 65535

with open(src, encoding='utf-8') as f:
    lines = f.readlines()

out = []
bad = []
for raw in lines:
    m = re.match(r'^(\s*listen\s*=\s*)"([^"]*)"(\s*(?:#.*)?)$', raw)
    if m:
        original = m.group(2)
        if not listen_ok(original):
            bad.append(original)
            out.append(raw)
            continue
        out.append(f'{m.group(1)}"127.0.0.1:{free_port()}"{m.group(3)}\n')
    else:
        out.append(raw)

with open(dst, 'w', encoding='utf-8') as f:
    f.writelines(out)

if bad:
    print("invalid listen address: " + ", ".join(bad), file=sys.stderr)
    raise SystemExit(3)
PY
    [[ -s "$probe_conf" ]] || return 1
    printf '%s\n' "$probe_conf"
}

probe_realm_config() {
    local probe_dir=$1
    [[ -x "$realm_binary_path" ]] || return 0

    local probe_conf
    probe_conf=$(build_probe_config "$probe_dir") || {
        error "生成探测用临时配置失败。"
        return 1
    }

    local log_file="${probe_dir}/probe.log"
    "$realm_binary_path" -c "$probe_conf" >"$log_file" 2>&1 &
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

    # 进程退出、或日志里出现 panic / bind 失败, 都视为配置不可用
    if [[ "$alive" == "false" ]] || grep -qiE "panicked|failed to bind|invalid .*address|missing field" "$log_file" 2>/dev/null; then
        cat "$log_file" >&2
        return 1
    fi
    return 0
}

restart_realm() {
    if [[ ! -f "$realm_binary_path" ]]; then error "realm 未安装" && return 1; fi
    info "正在重启 realm 服务..."
    if ! service_restart; then error "重启失败"; return 1; fi
    sleep 1
    if ! service_is_active; then error "启动失败，请查看日志"; return 1; fi
    success "realm 服务已成功重启！"
}

# --- 自定义连接地址管理 ---
set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "说明: 如果中转机是 NAT VPS, 或对外地址与网卡地址不同,"
    echo "请在此填入实际用于外部连接的 IP 或 DDNS 域名,"
    echo "脚本生成转发信息时会优先使用它。"
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

# --- 转发信息展示 ---
view_forward_info() {
    local target_listen="${1:-}"

    if [[ ! -f "$realm_config_path" ]]; then error "配置不存在"; return; fi
    local rows
    rows=$(list_forward_listen 2>/dev/null || true)
    if [[ -z "$rows" ]]; then error "未找到任何 realm 转发配置。"; return; fi

    if [[ -z "$target_listen" ]]; then
        local count; count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
        if [[ "$count" -eq 1 ]]; then
            target_listen=$(printf '%s\n' "$rows" | head -1 | cut -f1)
        else
            echo "当前 realm 转发列表:"
            local listen remote
            while IFS=$'\t' read -r listen remote; do
                echo " - ${cyan}${listen}${none} -> ${cyan}${remote}${none}"
            done <<< "$rows"
            echo ""
            while true; do
                read -p "请输入要查看的本地监听地址 (如 0.0.0.0:8443): " input_l
                if printf '%s\n' "$rows" | cut -f1 | grep -qx "$input_l"; then target_listen="$input_l"; break
                else error "未找到该监听地址"; fi
            done
        fi
    fi

    local remote
    remote=$(printf '%s\n' "$rows" | awk -F'\t' -v t="$target_listen" '$1 == t {print $2; exit}')
    local port; port=$(realm_listen_port "$target_listen")

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
    else link_name="$(hostname)-${port}"; fi

    if [[ "$is_quiet" == true ]]; then
        printf '%s:%s -> %s\n' "$ip" "$port" "$remote"
        return
    fi

    echo "----------------------------------------------------------------"
    echo -e "${green} --- Realm 转发信息 --- ${none}"
    echo -e "${yellow} 名称:     ${cyan}$link_name${none}"
    echo -e "${yellow} 本机监听: ${cyan}$target_listen${none}"
    echo -e "${yellow} 对外地址: ${cyan}${ip}:${port}${none}"
    echo -e "${yellow} 转发到:   ${cyan}$remote${none}"
    echo "----------------------------------------------------------------"
    echo -e "${yellow}[!] realm 是纯端口转发, 本身不产生可导入的节点链接。"
    echo -e "    客户端请使用 ${cyan}${ip}:${port}${none} 作为服务器地址,"
    echo -e "    协议与凭据沿用目标节点 (${cyan}${remote}${none}) 上配置的那一套。${none}"
    echo "----------------------------------------------------------------"
}

# --- 交互向导 ---
install_forward() {
    if [[ -f "$realm_binary_path" ]]; then
        info "检测到 realm 已安装。继续操作将添加新的转发。"
    fi

    local listen_port remote_addr use_udp=true no_tcp=false listen_host="0.0.0.0"

    while true; do
        read -p "$(echo -e "本机监听端口 [1-65535] (默认: ${cyan}8443${none}): ")" listen_port
        [ -z "$listen_port" ] && listen_port=8443
        if ! is_valid_port "$listen_port"; then error "端口无效"; continue; fi
        if is_port_in_use "$listen_port"; then error "端口 $listen_port 已被占用"; continue; fi
        break
    done

    echo ""
    echo -e "${yellow}[!] 监听地址一般用 0.0.0.0 (含 IPv4)。纯 IPv6 机器请填 [::]。${none}"
    read -p "$(echo -e "监听地址 (默认: ${cyan}0.0.0.0${none}): ")" input_host
    if [[ -n "$input_host" ]]; then
        listen_host="$input_host"
        if [[ "$listen_host" == *:* && "$listen_host" != \[* ]]; then listen_host="[${listen_host}]"; fi
    fi
    local listen_addr="${listen_host}:${listen_port}"
    if ! is_valid_listen "$listen_addr"; then
        error "监听地址格式无效: $listen_addr"; return 1
    fi

    while true; do
        read -p "$(echo -e "转发目标 remote (host:port, 例如 ${cyan}10.0.0.2:8443${none}): ")" remote_addr
        [ -z "$remote_addr" ] && { error "remote 不能为空"; continue; }
        if is_valid_remote "$remote_addr"; then break; else error "格式必须是 host:port"; fi
    done

    echo ""
    echo -e "${yellow}[!] realm 默认同时转发 TCP 和 UDP。"
    echo -e "    如果目标节点只用 TCP (如 VLESS+Reality、AnyTLS),"
    echo -e "    关掉 UDP 可以少一个 UDP 关联表, 也更贴近纯 TCP 特征。${none}"
    read -p "$(echo -e "同时转发 UDP? [Y/n]: ")" yn
    [[ "$yn" =~ ^[nN]$ ]] && use_udp=false
    if [[ "$use_udp" == "false" ]]; then
        read -p "完全禁用 TCP 只转 UDP? [y/N]: " yn2
        [[ "$yn2" =~ ^[yY]$ ]] && no_tcp=true
    fi

    local comment="realm-${listen_port}"
    if ! append_endpoint "$listen_addr" "$remote_addr" "$use_udp" "$no_tcp" "$comment"; then
        return 1
    fi

    if [[ ! -x "$realm_binary_path" ]]; then
        install_realm_core || return 1
    fi

    # 顺序要紧: 探测必须早于 setup_service / restart_realm。
    # 服务一旦起来就占住真实端口, 晚探测会和它抢端口误报失败。
    local probe_dir; probe_dir=$(mktemp -d) || return 1
    if ! probe_realm_config "$probe_dir"; then
        rm -rf "$probe_dir"
        # 回滚最后追加的块
        remove_endpoint "$listen_addr" >/dev/null 2>&1 || true
        error "realm 无法加载新配置，已移除该转发。"
        error "请确认监听地址可用 (端口是否被占用 / 地址是否属于本机)。"
        return 1
    fi
    rm -rf "$probe_dir"

    setup_service || {
        remove_endpoint "$listen_addr" >/dev/null 2>&1 || true
        error "服务安装失败，已移除该转发。"
        return 1
    }

    if ! restart_realm; then
        remove_endpoint "$listen_addr" >/dev/null 2>&1 || true
        service_restart >/dev/null 2>&1 || true
        error "节点启动失败，已移除该转发。"
        return 1
    fi
    success "Realm 转发安装完成！"
    view_forward_info "$listen_addr"
}

delete_forward() {
    if [[ ! -f "$realm_config_path" ]]; then error "配置不存在"; return; fi

    local rows
    rows=$(list_forward_listen 2>/dev/null || true)
    if [[ -z "$rows" ]]; then error "未找到任何 realm 转发，无需删除。"; return; fi

    echo "当前 realm 转发:"
    local listen remote
    while IFS=$'\t' read -r listen remote; do
        echo " - ${listen} -> ${remote}"
    done <<< "$rows"
    echo ""

    local target_listen
    while true; do
        read -p "请输入要删除的本地监听地址: " target_listen
        if printf '%s\n' "$rows" | cut -f1 | grep -qx "$target_listen"; then break
        else error "未找到该监听地址"; fi
    done

    read -p "确定要永久删除 $target_listen 这条转发吗？[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi

    info "正在删除转发..."
    local delete_backup
    delete_backup=$(backup_config "bak.del") || { error "备份配置失败"; return 1; }

    if ! remove_endpoint "$target_listen"; then
        error "删除转发配置失败，已保留备份。"
        return 1
    fi

    local remaining
    remaining=$(realm_forward_count 2>/dev/null || echo 0)
    if [[ "$remaining" == "0" ]]; then
        warn "已无剩余转发，realm 服务将保持空转 (无监听端口)。"
    fi

    if ! restart_realm; then
        cp "$delete_backup" "$realm_config_path"
        service_restart >/dev/null 2>&1 || true
        error "删除后服务未能正常启动，已恢复原配置。"
        return 1
    fi
    success "转发 $target_listen 已删除。"
}

update_realm() {
    if [[ ! -f "$realm_binary_path" ]]; then error "realm 未安装" && return; fi
    info "正在检查最新版本..."
    local current_version; current_version=$(installed_realm_version)
    local latest_version
    latest_version=$(curl -fsSL "https://api.github.com/repos/${realm_repo}/releases/latest" 2>/dev/null | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || true)
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败" && return; fi
    info "当前: ${cyan}${current_version}${none}，最新: ${cyan}${latest_version}${none}"
    if [[ "$current_version" == "${latest_version#v}" ]]; then
        success "已是最新版本。"; return
    fi
    if ! install_realm_core; then error "更新失败！" && return; fi
    if ! restart_realm; then return; fi
    success "realm 更新成功！"
}

uninstall_realm() {
    if [[ ! -f "$realm_binary_path" ]]; then error "realm 未安装" && return; fi
    read -p "确定卸载 realm 吗？配置会先自动备份。[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消。"; return; fi
    local config_archive=""
    if ! config_archive=$(backup_config_archive); then
        error "配置备份失败，已取消卸载，未删除任何文件。"
        return 1
    fi
    info "正在卸载..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop realm || true; systemctl disable realm || true
        rm -f /etc/systemd/system/realm.service; systemctl daemon-reload || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service realm stop || true; rc-update del realm default || true
        rm -f /etc/init.d/realm
    fi
    rm -f "$realm_binary_path"
    rm -rf "$realm_config_dir"
    success "realm 已成功卸载；配置备份: $config_archive"
    info "说明: /root/inbound_address.txt 由本套脚本共用, 未删除。"
}

view_realm_log() {
    if [[ ! -f "$realm_binary_path" ]]; then error "realm 未安装" && return; fi
    info "显示日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if command -v journalctl >/dev/null 2>&1; then journalctl -u realm -f --no-pager || true
    elif [[ -d /var/log/realm ]]; then (tail -n 200 -F /var/log/realm/*.log 2>/dev/null) || true
    else error "无法找到日志"; fi
    trap - SIGINT; echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

test_forward() {
    if [[ ! -f "$realm_config_path" ]]; then error "配置不存在"; return; fi
    local rows
    rows=$(list_forward_listen 2>/dev/null || true)
    if [[ -z "$rows" ]]; then error "未找到任何转发配置。"; return; fi

    echo "连通性测试 (本机连监听端口, 看能否建立 TCP):"
    local listen remote port
    while IFS=$'\t' read -r listen remote; do
        port=$(realm_listen_port "$listen")
        if (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
            echo -e " ${green}✔${none} ${listen} -> ${remote}  (本地 TCP 可连接)"
        else
            echo -e " ${red}✖${none} ${listen} -> ${remote}  (本地 TCP 连不上, 检查服务是否运行)"
        fi
    done <<< "$rows"
    echo ""
    echo -e "${yellow}[!] 这里只验证本地监听是否存活。"
    echo -e "    真正能否通到目标, 需要从外部用客户端实测。${none}"
}

press_any_key_to_continue() {
    echo ""; read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear
        echo -e "${cyan} Realm 端口转发 一键安装管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${yellow} 纯 TCP/UDP 转发, 与 Mihomo 服务端并行运行;"
        echo -e " 典型场景: 中转机转发到落地机的节点端口${none}"
        echo "---------------------------------------------"
        check_realm_status
        echo -e "${realm_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/添加 realm 转发"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 realm"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 realm"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 realm"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 realm 日志"
        printf "  ${green}%-2s${none} %-35s\n" "6." "查看转发信息"
        printf "  ${cyan}%-2s${none} %-35s\n" "7." "测试转发连通性"
        printf "  ${red}%-2s${none} %-35s\n" "8." "删除指定转发"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "设置连接地址 (NAT/DDNS)"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-9]: " choice

        local needs_pause=true
        case $choice in
            1) install_forward ;;
            2) update_realm ;;
            3) restart_realm ;;
            4) uninstall_realm ;;
            5) view_realm_log; needs_pause=false ;;
            6) view_forward_info ;;
            7) test_forward ;;
            8) delete_forward ;;
            9) set_connection_address ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        if [ "$needs_pause" = true ]; then press_any_key_to_continue; fi
    done
}

main() {
    pre_check
    if [[ $# -gt 0 && "$1" == "install" ]]; then
        shift
        local port="" listen_host="0.0.0.0" remote_addr=""
        local use_udp=true no_tcp=false comment=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --port|--listen-host|--remote|--comment)
                    [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; exit 1; }
                    case "$1" in
                        --port) port="$2" ;;
                        --listen-host) listen_host="$2" ;;
                        --remote) remote_addr="$2" ;;
                        --comment) comment="$2" ;;
                    esac
                    shift 2
                    ;;
                --udp) use_udp=true; shift ;;
                --no-udp) use_udp=false; shift ;;
                --no-tcp) no_tcp=true; shift ;;
                --quiet|-q) is_quiet=true; shift ;;
                *) error "未知参数: $1"; exit 1 ;;
            esac
        done

        [[ -z "$port" ]] && port=8443
        if ! is_valid_port "$port"; then error "端口无效。" && exit 1; fi
        if [[ -z "$remote_addr" ]]; then error "必须提供 --remote host:port。" && exit 1; fi
        if ! is_valid_remote "$remote_addr"; then error "remote 格式无效: $remote_addr" && exit 1; fi
        if [[ "$listen_host" == *:* && "$listen_host" != \[* ]]; then listen_host="[${listen_host}]"; fi
        local listen_addr="${listen_host}:${port}"
        if ! is_valid_listen "$listen_addr"; then error "监听地址无效: $listen_addr" && exit 1; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用。" && exit 1; fi
        [[ -z "$comment" ]] && comment="realm-${port}"

        if ! append_endpoint "$listen_addr" "$remote_addr" "$use_udp" "$no_tcp" "$comment"; then
            exit 1
        fi
        if [[ ! -x "$realm_binary_path" ]]; then
            install_realm_core || exit 1
        fi

        # 顺序要紧: 探测必须早于 setup_service, 服务起来后会占住真实端口。
        local probe_dir; probe_dir=$(mktemp -d) || exit 1
        if ! probe_realm_config "$probe_dir"; then
            rm -rf "$probe_dir"
            remove_endpoint "$listen_addr" >/dev/null 2>&1 || true
            error "realm 无法加载配置，已移除该转发。"
            exit 1
        fi
        rm -rf "$probe_dir"

        if ! setup_service; then
            remove_endpoint "$listen_addr" >/dev/null 2>&1 || true
            error "服务安装失败，已移除该转发。"
            exit 1
        fi

        if ! restart_realm; then
            remove_endpoint "$listen_addr" >/dev/null 2>&1 || true
            service_restart >/dev/null 2>&1 || true
            error "节点启动失败，已移除该转发。"
            exit 1
        fi
        success "Realm 转发安装完成！"
        view_forward_info "$listen_addr"
    else
        main_menu
    fi
}

main "$@"