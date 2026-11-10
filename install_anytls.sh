#!/bin/bash

# ==============================================================================
# Mihomo AnyTLS 一键安装管理脚本
# 使用 Mihomo 的 anytls listener 承载 AnyTLS 协议
# 版本: V-AnyTLS-Mihomo-1.0
# 功能:
# - 安装/管理 AnyTLS 节点 (JLS 握手伪装 / 原生 TLS 双模式)
# - JLS 模式无需证书, 由内核生成一次性握手证书, 未认证连接回落 dest
# - 智能追加配置 (不覆盖其他 listeners)
# - 多端口/多节点管理
# - 支持自定义连接地址 (NAT/DDNS)
# - 精准删除指定 AnyTLS 节点
#
# 内核要求: mihomo >= 1.19.29 (JLS 支持在 v1.19.29 随
# "feat: support jls for anytls outbound and listener" 引入)
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-AnyTLS-Mihomo-1.0"
readonly MIN_MIHOMO_VERSION="1.19.29"
readonly mihomo_config_dir="/usr/local/etc/mihomo"
readonly mihomo_config_path="${mihomo_config_dir}/config.yaml"
readonly mihomo_binary_path="/usr/local/bin/mihomo"
readonly address_file="/root/inbound_address.txt"
readonly node_prefix="anytls-jls-in-"
readonly default_dest="www.bing.com:443"
readonly default_alpn="h2,http/1.1"

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
mihomo_status_info=""
is_quiet=false
OS_ID=""
INIT_SYSTEM=""
SECURITY_MODE="jls"

# --- 辅助函数 ---
error() { echo -e "\n${red}[✖] $1${none}\n" >&2; }
warn()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${magenta}[⚠] $1${none}\n" >&2; fi; return 0; }
info()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${yellow}[!] $1${none}\n"; fi; return 0; }
success(){ if [[ "$is_quiet" = false ]]; then echo -e "\n${green}[✔] $1${none}\n"; fi; return 0; }

spinner() {
    local pid=$1; local spinstr='|/-\\'
    if [[ "$is_quiet" = true ]]; then wait "$pid"; return; fi
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}; printf " [%c]  "$spinstr
        local spinstr=$temp${spinstr%"$temp"}; sleep 0.1; printf "\r"
    done; printf "    \r"
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

format_uri_host() {
    if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

url_encode() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Gen 一个只含安全字符的密码, 避免 YAML / 分享链接的转义问题
generate_secret() {
    local length="${1:-24}"
    python3 - "$length" <<'PY'
import secrets, string, sys
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(int(sys.argv[1]))))
PY
}

# 语义化版本比较: version_ge 1.19.33 1.19.29 -> 0
version_ge() {
    python3 - "$1" "$2" <<'PY'
import re, sys
def parts(v):
    return tuple(int(x) if x.isdigit() else 0 for x in re.findall(r'\d+', v))
sys.exit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
PY
}

# --- 核心安装逻辑 ---
install_mihomo_core() {
    info "开始安装 Mihomo 核心..."
    local arch machine; machine="$(uname -m)"
    case "$machine" in
        # 关键: 默认 amd64 新版使用 GOAMD64=v3, 老 CPU 会直接报 illegal instruction
        x86_64|amd64) arch="amd64-compatible" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7|armv7l) arch="armv7" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac
    [[ "$arch" == "armv7" ]] && echo -e "\n${yellow}[!] 警告: ARMv7 支持目前处于 Alpha 阶段，二进制来自预发布版本，可能存在不稳定情况，请谨慎使用。${none}\n"

    local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    info "获取 Mihomo 最新版本信息..."
    local tag
    tag="$(curl -fsSL "$api" | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    local version_str="${tag:-latest}"
    info "目标版本: $version_str"

    local tmpdir; tmpdir="$(mktemp -d)" || return 1
    local filename="mihomo-linux-${arch}-${tag}.gz"
    local url_tag="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${filename}"
    local url_alt="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${arch}.gz"

    info "正在下载 Mihomo ($filename)..."
    if [[ -n "${tag:-}" ]] && curl -fL "$url_tag" -o "$tmpdir/mihomo.gz"; then :;
    elif curl -fL "$url_alt" -o "$tmpdir/mihomo.gz"; then :;
    else rm -rf "$tmpdir"; error "下载 Mihomo 失败"; return 1; fi

    info "解压并安装到 /usr/local/bin ..."
    if ! gzip -d "$tmpdir/mihomo.gz" || ! chmod +x "$tmpdir/mihomo" || ! "$tmpdir/mihomo" -v >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        error "下载的 Mihomo 核心无法执行，已取消安装。"
        return 1
    fi
    install -m 0755 "$tmpdir/mihomo" "$mihomo_binary_path" || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$mihomo_config_dir" || return 1
    rm -rf "$tmpdir"
    success "Mihomo 核心安装完成"
}

installed_mihomo_version() {
    [[ -x "$mihomo_binary_path" ]] || return 1
    "$mihomo_binary_path" -v 2>/dev/null | head -n 1 | awk '{print $3}'
}

# AnyTLS 自 1.19.3 起可用, JLS 自 1.19.29 起可用; 低版本会静默丢弃
# jls-config 并在 Listen 时才报 "disallow using AnyTLS without ..."
require_jls_capable_mihomo() {
    local current
    current=$(installed_mihomo_version 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        error "未检测到 Mihomo 核心，无法继续。"
        return 1
    fi
    if ! version_ge "$current" "$MIN_MIHOMO_VERSION"; then
        error "当前 Mihomo 版本 $current 不支持 JLS (需要 >= $MIN_MIHOMO_VERSION)。"
        error "请先在菜单中选择 [2] 更新 Mihomo 后再安装 AnyTLS+JLS 节点。"
        return 1
    fi
    return 0
}

install_geodata() {
    info "正在安装/更新 GeoIP 和 GeoSite 数据文件..."
    mkdir -p "$mihomo_config_dir" || return 1
    local tmpdir
    tmpdir="$(mktemp -d "${mihomo_config_dir}/.geo-install.XXXXXX")" || return 1
    if ! curl -fsSL -o "$tmpdir/geoip.metadb" https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb \
        || ! curl -fsSL -o "$tmpdir/geosite.dat" https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat \
        || [[ ! -s "$tmpdir/geoip.metadb" || ! -s "$tmpdir/geosite.dat" ]]; then
        rm -rf "$tmpdir"
        error "Geo 数据文件下载失败，原文件未被覆盖。"
        return 1
    fi
    chmod 0644 "$tmpdir/geoip.metadb" "$tmpdir/geosite.dat"
    if ! mv -f "$tmpdir/geoip.metadb" "${mihomo_config_dir}/geoip.metadb" \
        || ! mv -f "$tmpdir/geosite.dat" "${mihomo_config_dir}/geosite.dat"; then
        rm -rf "$tmpdir"; error "Geo 数据文件安装失败。"; return 1
    fi
    rm -rf "$tmpdir"
    success "Geo 数据文件已更新"
}

# --- Systemd 服务安装 ---
install_service_systemd() {
    info "安装 Systemd 服务 (User=root)..."
    cat >/etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=Mihomo Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/mihomo -d /usr/local/etc/mihomo
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=false
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    [[ -s /etc/systemd/system/mihomo.service ]] || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now mihomo || return 1
    success "Systemd 服务已安装并启动"
}

install_service_openrc() {
    info "安装 OpenRC 服务..."
    install -d -m 0755 /var/log/mihomo || true
    cat >/etc/init.d/mihomo <<'EOF'
#!/sbin/openrc-run
name="mihomo"
description="Mihomo Service"
command="/usr/local/bin/mihomo"
command_args="-d /usr/local/etc/mihomo"
command_background=true
pidfile="/run/mihomo.pid"
start_stop_daemon_args="--make-pidfile --background"

depend() {
  need net
  use dns
}
EOF
    [[ -s /etc/init.d/mihomo ]] || return 1
    chmod +x /etc/init.d/mihomo || return 1
    rc-update add mihomo default || return 1
    rc-service mihomo restart || rc-service mihomo start || return 1
    success "OpenRC 服务已安装并启动"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then install_service_systemd
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then install_service_openrc
    else error "无法确定服务管理器，请手动配置自启动。"; return 1; fi
}

validate_mihomo_config() {
    if [[ -x "$mihomo_binary_path" ]]; then
        "$mihomo_binary_path" -t -d "$mihomo_config_dir"
    else
        return 0
    fi
}

# --- 验证函数 ---
is_valid_port() { local port=$1; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; }

is_listener_port_in_config() {
    local port=$1
    [[ -f "$mihomo_config_path" ]] || return 1

    # 只检查 listeners 顶级配置段。proxies 中的 port 是远端目标端口，
    # 不会在本机监听，因此不能据此判定本地端口冲突。
    awk -v target="$port" '
        BEGIN { in_listeners = 0; found = 0 }
        /^[^[:space:]#][^:]*:/ {
            key = $0
            sub(/:.*/, "", key)
            in_listeners = (key == "listeners")
            next
        }
        in_listeners && /^[[:space:]]+port:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+port:[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/[[:space:]\"]/, "", value)
            quote = sprintf("%c", 39)
            gsub(quote, "", value)
            if (value == target) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$mihomo_config_path" 2>/dev/null
}

managed_listener_ports() {
    local prefix=$1
    [[ -f "$mihomo_config_path" ]] || return 1
    python3 - "$mihomo_config_path" "$prefix" <<'PY'
import json, re, sys
path, prefix = sys.argv[1:]
in_listeners = False
current_name = None

def scalar(value):
    value = value.strip()
    try:
        return str(json.loads(value))
    except Exception:
        return value.strip("\"'")

with open(path, encoding='utf-8') as f:
    for raw in f:
        if re.match(r'^[^\s#][^:]*:', raw):
            in_listeners = raw.split(':', 1)[0].strip() == 'listeners'
            current_name = None
            continue
        if not in_listeners:
            continue
        stripped = raw.strip()
        if stripped.startswith('- name:'):
            current_name = scalar(stripped.split(':', 1)[1])
        elif current_name and current_name.startswith(prefix) and stripped.startswith('port:'):
            value = scalar(stripped.split(':', 1)[1])
            if value.isdigit() and current_name == prefix + value:
                print(value)
PY
}

backup_config() {
    local suffix="${1:-bak}"
    local backup
    backup=$(mktemp "${mihomo_config_path}.${suffix}.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$mihomo_config_path" "$backup" || { rm -f "$backup"; return 1; }
    chmod 600 "$backup"
    printf '%s\n' "$backup"
}

backup_config_archive() {
    [[ -d "$mihomo_config_dir" ]] || return 0
    local archive
    archive=$(mktemp "/root/mihomo-config-backup-$(date +%Y%m%d%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C "$(dirname "$mihomo_config_dir")" "$(basename "$mihomo_config_dir")"; then
        rm -f "$archive"
        return 1
    fi
    chmod 600 "$archive" || return 1
    printf '%s\n' "$archive"
}

remove_managed_listener() {
    local prefix=$1 port=$2
    python3 - "$mihomo_config_path" "$prefix" "$port" <<'PY'
import json, os, re, stat, sys, tempfile
path, prefix, port = sys.argv[1:]
target_name = prefix + port
in_listeners = False
skip = False
skip_indent = -1
removed = False
result = []

def scalar(value):
    value = value.strip()
    try:
        return str(json.loads(value))
    except Exception:
        return value.strip("\"'")

with open(path, encoding='utf-8') as f:
    lines = f.readlines()

for raw in lines:
    if re.match(r'^[^\s#][^:]*:', raw):
        skip = False
        in_listeners = raw.split(':', 1)[0].strip() == 'listeners'
        result.append(raw)
        continue

    stripped = raw.strip()
    indent = len(raw) - len(raw.lstrip())
    if in_listeners and stripped.startswith('- name:'):
        if skip and indent <= skip_indent:
            skip = False
        name = scalar(stripped.split(':', 1)[1])
        if not skip and name == target_name:
            skip = True
            skip_indent = indent
            removed = True
            continue

    if skip:
        continue
    result.append(raw)

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

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat &>/dev/null; then netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof &>/dev/null; then lsof -i ":$port" &>/dev/null && return 0
    else (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0; fi
    is_listener_port_in_config "$port" && return 0
    return 1
}

# DNS 标签允许连字符出现在任意位置, `d1--ov-gotcha207b.bilivideo.com` 这种中间
# 带连续连字符的域名完全合法 (只有 xn-- 前缀才与 punycode 相关, 也不是禁则)。
# 这里只排除真正非法的形式: 首尾连字符、空标签、连续点、超长。
is_valid_domain() {
    local domain=$1
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# dest 必须是 host:port, 且 host 为 IP 或域名。Mihomo 的 jls.NewServerConfig
# 用 net.SplitHostPort 解析, 少了端口会直接报 invalid dest address。
is_valid_dest() {
    local dest=$1
    [[ "$dest" == *:* ]] || return 1
    local host="${dest%:*}" port="${dest##*:}"
    is_valid_port "$port" || return 1
    [[ -n "$host" ]] || return 1
    if [[ "$host" =~ ^[0-9.]+$ ]] || [[ "$host" == *:* ]]; then return 0; fi
    is_valid_domain "$host"
}

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID=${ID:-}; fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="unknown"; fi
}

service_restart() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart mihomo || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service mihomo restart || return 1
    else error "无法确定服务管理器，请手动重启 Mihomo。"; return 1; fi
    sleep 1
    service_is_active
}

service_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active --quiet mihomo
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service mihomo status >/dev/null 2>&1 && rc-service mihomo status 2>/dev/null | grep -qi started
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
    local required_commands=("awk" "grep" "sed" "curl" "python3" "gzip" "base64" "install" "mktemp" "tar")
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd"); done
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing_commands[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache bash curl python3 openssl gzip coreutils
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl python3 openssl gzip coreutils
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

check_mihomo_status() {
    if [[ ! -f "$mihomo_binary_path" ]]; then mihomo_status_info="  Mihomo 状态: ${red}未安装${none}"; return; fi
    local mihomo_version
    mihomo_version=$(installed_mihomo_version 2>/dev/null || echo "未知")
    local service_status
    if service_is_active; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    local jls_flag=""
    if [[ "$mihomo_version" != "未知" ]] && version_ge "$mihomo_version" "$MIN_MIHOMO_VERSION"; then
        jls_flag=" ${green}[JLS ✓]${none}"
    else
        jls_flag=" ${red}[JLS 需要 >= ${MIN_MIHOMO_VERSION}]${none}"
    fi
    mihomo_status_info="  Mihomo 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${mihomo_version}${none}${jls_flag}"
}

# --- 初始化 Mihomo 基础配置文件 ---
init_mihomo_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then
        info "配置文件不存在，创建新配置..."
        mkdir -p "$mihomo_config_dir" || return 1
        cat > "$mihomo_config_path" <<'YAML'
# Mihomo 代理服务端配置
mode: rule
log-level: warning
allow-lan: true
bind-address: "*"

listeners: []

rules:
  - MATCH,DIRECT
YAML
        chmod 600 "$mihomo_config_path"
    fi
}

# --- AnyTLS 监听块构建 ---
# 参数: out_file port tag mode password jls_user jls_password dest sni alpn proxy rate_limit padding_file
# mode: jls | tls
# 说明: jls 模式禁止同时写 certificate/private-key (内核报
# "security modes are mutually exclusive: certificate, jls"); tls 模式则必须同时写。
build_anytls_block() {
    local out_file=$1 port=$2 tag=$3 mode=$4 password=$5
    local jls_user=$6 jls_password=$7 dest=$8 sni=$9 alpn=${10}
    local proxy=${11} rate_limit=${12} padding_file=${13}
    local cert_path="${14:-}" key_path="${15:-}"

    python3 - "$out_file" "$port" "$tag" "$mode" "$password" \
        "$jls_user" "$jls_password" "$dest" "$sni" "$alpn" \
        "$proxy" "$rate_limit" "$padding_file" "$cert_path" "$key_path" <<'PY'
import json, sys

(out_file, port, tag, mode, password, jls_user, jls_password,
 dest, sni, alpn, proxy, rate_limit, padding_file, cert_path, key_path) = sys.argv[1:16]

q = lambda v: json.dumps(v, ensure_ascii=False)
lines = [
    f"  - name: {q(tag)}",
    "    type: anytls",
    f"    port: {int(port)}",
    "    listen: 0.0.0.0",
    "    users:",
    f"      {q('anytls')}: {q(password)}",
]

if mode == "jls":
    lines.append("    jls-config:")
    lines.append("      enable: true")
    lines.append("      users:")
    lines.append(f"        - username: {q(jls_user)}")
    lines.append(f"          password: {q(jls_password)}")
    lines.append(f"      dest: {q(dest)}")
    if sni:
        lines.append(f"      sni: {q(sni)}")
    alpn_items = [a.strip() for a in alpn.split(',') if a.strip()]
    if alpn_items:
        lines.append("      alpn:")
        for item in alpn_items:
            lines.append(f"        - {q(item)}")
    if proxy:
        lines.append(f"      proxy: {q(proxy)}")
    if rate_limit and int(rate_limit) > 0:
        lines.append(f"      rate-limit: {int(rate_limit)}")
else:
    lines.append(f"    certificate: {q(cert_path)}")
    lines.append(f"    private-key: {q(key_path)}")

if padding_file:
    with open(padding_file, encoding='utf-8') as f:
        scheme = f.read().rstrip('\n')
    lines.append("    padding-scheme: |")
    for part in scheme.split('\n'):
        lines.append("      " + part)

with open(out_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')
PY
}

# AnyTLS 的 TLS 配置错误在 `mihomo -t` 里全部无法发现 (解析期只检查 jls users 必填),
# 其余都要到真正 Listen 才炸。因此写盘前必须自己做字段级校验。
validate_anytls_fields() {
    local mode=$1 dest=$2 jls_user=$3 jls_password=$4 alpn=$5 padding_file=$6
    local errs=()

    if [[ "$mode" == "jls" ]]; then
        if ! is_valid_dest "$dest"; then
            errs+=("JLS dest 必须是 host:port 形式 (例如 www.bing.com:443), 当前: ${dest:-空}")
        fi
        [[ -n "$jls_user" ]] || errs+=("JLS 用户名不能为空 (内核要求 jls-config.users 至少一个)")
        [[ -n "$jls_password" ]] || errs+=("JLS 密码不能为空")
    fi

local alpn_items=() a
    IFS=',' read -ra alpn_items <<< "$alpn"
    for a in "${alpn_items[@]}"; do
        [[ -z "$a" ]] && continue
        # 不做去空格处理: "ht tp" 会被悄悄改写成 "http", 静默改变语义
        [[ "$a" =~ ^[a-zA-Z0-9/._-]+$ ]] || errs+=("ALPN 取值非法: $a")
    done

    if [[ -n "$padding_file" ]]; then
        if [[ ! -s "$padding_file" ]]; then
            errs+=("padding-scheme 文件不存在或为空: $padding_file")
        else
            # 内核 NewPaddingFactory 的硬要求: 必须有一行可 Atoi 的 stop=
            if ! grep -qE '^stop=[0-9]+[[:space:]]*$' "$padding_file"; then
                errs+=("padding-scheme 缺少可解析的 stop=N 行 (内核会报 incorrect padding scheme format)")
            fi
            # 内核按 "\n" 切分且保留其他字节, CRLF 会留下 \r 让 stop 的 Atoi 失败。
            # 用二进制读判断, 避免 grep 在部分平台做文本模式换行转换后漏检。
            if ! python3 - "$padding_file" <<'PY'
import sys
sys.exit(0 if b'\r' not in open(sys.argv[1], 'rb').read() else 1)
PY
            then
                errs+=("padding-scheme 含 CRLF 换行，内核按 LF 切分会留下 CR 导致解析失败，请转成 LF")
            fi
        fi
    fi

    if [[ ${#errs[@]} -gt 0 ]]; then
        local e
        for e in "${errs[@]}"; do error "$e"; done
        return 1
    fi
    return 0
}

append_listener_block() {
    local block_file=$1
    python3 - "$mihomo_config_path" "$block_file" <<'PY'
import os, re, stat, sys, tempfile

config_path, block_file = sys.argv[1], sys.argv[2]
with open(block_file, encoding='utf-8') as f:
    listener_block = f.read().rstrip('\n')

with open(config_path, 'r', encoding='utf-8') as f:
    content = f.read()

if re.search(r'^listeners:\s*\[\]\s*(?:#.*)?$', content, re.MULTILINE):
    content = re.sub(r'^listeners:\s*\[\]\s*(?:#.*)?$', 'listeners:\n' + listener_block, content,
                     count=1, flags=re.MULTILINE)
elif re.search(r'^listeners:', content, re.MULTILINE):
    # 不能在 "listeners:" 头行后面直接拼块: 那个头行在有内容时同样会命中,
    # 结果新节点被插到列表顶部。统一走行扫描, 追加到 listeners 块末尾。
    lines = content.split('\n')
    result_lines = []
    in_listeners = False
    inserted = False
    for line in lines:
        result_lines.append(line)
        if re.match(r'^listeners:', line):
            in_listeners = True
            continue
        if in_listeners and not inserted:
            if line and not line.startswith(' ') and not line.startswith('#') and ':' in line:
                result_lines.insert(len(result_lines) - 1, listener_block)
                inserted = True
                in_listeners = False
    if in_listeners and not inserted:
        result_lines.append(listener_block)
    content = '\n'.join(result_lines)
else:
    content += '\nlisteners:\n' + listener_block + '\n'

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
}

node_state_file() {
    printf '/root/mihomo_anytls_node_%s.json' "$1"
}

save_node_state() {
    local port=$1 mode=$2 password=$3 jls_user=$4 jls_password=$5
    local dest=$6 sni=$7 alpn=$8 proxy=$9 rate_limit=${10}
    local state_file; state_file=$(node_state_file "$port")
    python3 - "$state_file" "$port" "$mode" "$password" "$jls_user" "$jls_password" \
        "$dest" "$sni" "$alpn" "$proxy" "$rate_limit" <<'PY'
import json, os, sys
(state_file, port, mode, password, jls_user, jls_password,
 dest, sni, alpn, proxy, rate_limit) = sys.argv[1:12]
data = {
    "port": int(port),
    "mode": mode,
    "password": password,
    "jls_user": jls_user,
    "jls_password": jls_password,
    "dest": dest,
    "sni": sni,
    "alpn": alpn,
    "proxy": proxy,
    "rate_limit": int(rate_limit or 0),
}
with open(state_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.chmod(state_file, 0o600)
PY
}

load_node_state() {
    local port=$1
    local state_file; state_file=$(node_state_file "$port")
    [[ -f "$state_file" ]] || return 1
    python3 - "$state_file" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
value = data.get(sys.argv[2], "")
if isinstance(value, bool):
    value = "true" if value else ""
print(value)
PY
}

# --- 核心安装流程 ---
run_install() {
    local port=$1 mode=$2 password=$3 jls_user=$4 jls_password=$5
    local dest=$6 sni=$7 alpn=$8 proxy=$9 rate_limit=${10} padding_file=${11}

    if ! install_mihomo_core; then error "Mihomo 核心安装失败！"; return 1; fi
    install_geodata || return 1
    if ! require_jls_capable_mihomo; then return 1; fi

    local tag="${node_prefix}${port}"
    local block_file; block_file=$(mktemp) || return 1
    if ! build_anytls_block "$block_file" "$port" "$tag" "$mode" "$password" \
        "$jls_user" "$jls_password" "$dest" "$sni" "$alpn" \
        "$proxy" "$rate_limit" "$padding_file"; then
        rm -f "$block_file"; error "构建 listener 配置失败。"; return 1
    fi

    init_mihomo_config || { rm -f "$block_file"; return 1; }
    local config_backup
    if ! config_backup=$(backup_config "bak"); then rm -f "$block_file"; error "备份配置失败"; return 1; fi

    if ! append_listener_block "$block_file"; then
        rm -f "$block_file"
        cp "$config_backup" "$mihomo_config_path"
        error "写入配置失败，已恢复原配置。"
        return 1
    fi
    rm -f "$block_file"
    chmod 600 "$mihomo_config_path"

    if ! validate_mihomo_config; then
        cp "$config_backup" "$mihomo_config_path"
        error "新配置未通过 Mihomo 检查，已恢复原配置。"
        return 1
    fi
    success "配置已安全追加到: $mihomo_config_path"

    setup_service || return 1
    if ! restart_mihomo; then
        return 1
    fi

    save_node_state "$port" "$mode" "$password" "$jls_user" "$jls_password" \
        "$dest" "$sni" "$alpn" "$proxy" "$rate_limit" || warn "节点参数文件写入失败，查看订阅信息时将尝试从配置反查。"

    success "Mihomo 安装/配置成功！"
    view_subscription_info "$port"
}

# mihomo 只读取 home 目录 (或 SAFE_PATHS) 下的证书文件, `mihomo -t` 不会检查这一点,
# 结果是配置校验通过、listener 在 Listen 时静默失败。约定把证书复制进配置目录再引用。
stage_certificate() {
    local src=$1 kind=$2 port=$3
    [[ -f "$src" ]] || { error "$kind 文件不存在: $src"; return 1; }
    local name base
    base=$(basename "$src")
    name="${node_prefix}${port}-${kind}-${base}"
    local dest="${mihomo_config_dir%/}/certs/${name}"
    mkdir -p "${mihomo_config_dir%/}/certs" || return 1
    if ! cp "$src" "$dest"; then
        error "复制 $kind 到 $dest 失败。"
        return 1
    fi
    chmod 600 "$dest"
    printf '%s\n' "$dest"
}

# --- 交互向导 ---
ask_anytls_node() {
    local port password mode

    while true; do
        read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}8443${none}): ")" port
        [ -z "$port" ] && port=8443
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done

    # AnyTLS 的服务端认证只有 password, users 里的 key 是给人看的标签
    password=$(generate_secret 24)
    info "已生成 AnyTLS 密码: ${cyan}${password}${none}"

    # 安全模式
    mode="jls"
    if [[ "$is_quiet" == false ]]; then
        echo ""
        echo "安全模式:"
        echo -e "  ${green}1.${none} JLS 握手伪装 (推荐, 无需证书, 内核自生成一次性证书)"
        echo -e "  ${cyan}2.${none} 原生 TLS (需要自备证书和私钥)"
        read -p "$(echo -e "请选择 [1-2] (默认: ${cyan}1${none}): ")" sec_choice
        case "${sec_choice:-1}" in
            2) mode="tls" ;;
            *) mode="jls" ;;
        esac
    fi
    SECURITY_MODE="$mode"

    local jls_user="" jls_password="" dest="" sni="" alpn="$default_alpn" proxy="" rate_limit=0
    local cert_path="" key_path=""

    if [[ "$mode" == "jls" ]]; then
        echo ""
        echo -e "${yellow}[!] JLS 说明: 未通过 JLS 认证的连接会被原样转发到 dest,"
        echo -e "    因此 dest 必须是一个真实可达的 TLS 站点 (默认 ${default_dest})。"
        echo -e "    JLS 与 certificate/private-key 互斥, 无需也不应填写证书。${none}"
        echo ""
        while true; do
            read -p "$(echo -e "JLS 回落目标 dest (默认: ${cyan}${default_dest}${none}): ")" dest
            [ -z "$dest" ] && dest="$default_dest"
            if is_valid_dest "$dest"; then break; else error "格式必须是 host:port"; fi
        done
        while true; do
            read -p "$(echo -e "JLS 伪装 SNI (留空则由 dest 推导, 一般直接回车): ")" sni
            if [[ -z "$sni" ]]; then break; fi
            if is_valid_domain "$sni"; then break; else error "SNI 必须是域名"; fi
        done
        read -p "$(echo -e "JLS ALPN (默认: ${cyan}${default_alpn}${none}): ")" input_alpn
        [[ -n "$input_alpn" ]] && alpn="$input_alpn"
        jls_user="jls$(generate_secret 6 | tr 'A-Z' 'a-z')"
        jls_password=$(generate_secret 24)
        info "已生成 JLS 凭据: ${cyan}${jls_user}${none} / ${cyan}${jls_password}${none}"
        if [[ "$is_quiet" == false ]]; then
            read -p "$(echo -e "回落流量走哪个出站 proxy (留空则 DIRECT, 一般直接回车): ")" proxy
            proxy="${proxy:-}"
            read -p "$(echo -e "回落转发限速 bit/s (留空或 0 表示不限速): ")" rate_limit
            rate_limit="${rate_limit:-0}"
        fi
    else
        while true; do
            read -p "$(echo -e "证书 PEM 路径: ")" cert_path
            [[ -f "$cert_path" ]] && break || error "文件不存在: $cert_path"
        done
        while true; do
            read -p "$(echo -e "私钥 PEM 路径: ")" key_path
            [[ -f "$key_path" ]] && break || error "文件不存在: $key_path"
        done
        # mihomo 只读 home 目录内的证书; 先复制进来, 否则 listener 起不来
        local staged
        staged=$(stage_certificate "$cert_path" "crt" "$port") || return 1
        cert_path="$staged"
        staged=$(stage_certificate "$key_path" "key" "$port") || return 1
        key_path="$staged"
        info "证书已复制到配置目录: ${cyan}${cert_path}${none}"
    fi

    # 自定义 padding-scheme (可选)
    local padding_file=""
    if [[ "$is_quiet" == false ]]; then
        echo ""
        echo -e "${yellow}[!] padding-scheme 留空则使用内核默认方案 (stop=8 / 0=30-30 / 1=100-400 ...),"
        echo -e "    该方案是公开的; 想要更强的抗长度特征识别, 可以提供一个自定义方案文件。${none}"
        read -p "$(echo -e "自定义 padding-scheme 文件路径 (直接回车用内核默认): ")" padding_file
        if [[ -n "$padding_file" ]] && [[ ! -f "$padding_file" ]]; then
            error "文件不存在: $padding_file，将改用内核默认方案。"
            padding_file=""
        fi
    fi

    if ! validate_anytls_fields "$mode" "$dest" "$jls_user" "$jls_password" "$alpn" "$padding_file"; then
        return 1
    fi

    ANYTLS_PORT="$port"; ANYTLS_MODE="$mode"; ANYTLS_PASSWORD="$password"
    ANYTLS_JLS_USER="$jls_user"; ANYTLS_JLS_PASSWORD="$jls_password"
    ANYTLS_DEST="$dest"; ANYTLS_SNI="$sni"; ANYTLS_ALPN="$alpn"
    ANYTLS_PROXY="$proxy"; ANYTLS_RATE_LIMIT="$rate_limit"
    ANYTLS_PADDING_FILE="$padding_file"
    ANYTLS_CERT="$cert_path"; ANYTLS_KEY="$key_path"
}

install_anytls() {
    if [[ -f "$mihomo_binary_path" ]]; then
        info "检测到 Mihomo 已安装。继续操作将添加新节点。"
    fi
    ask_anytls_node || return 1

    local port="$ANYTLS_PORT" mode="$ANYTLS_MODE"
    local block_file; block_file=$(mktemp) || return 1
    if ! build_anytls_block "$block_file" "$ANYTLS_PORT" "${node_prefix}${ANYTLS_PORT}" \
        "$ANYTLS_MODE" "$ANYTLS_PASSWORD" "$ANYTLS_JLS_USER" "$ANYTLS_JLS_PASSWORD" \
        "$ANYTLS_DEST" "$ANYTLS_SNI" "$ANYTLS_ALPN" "$ANYTLS_PROXY" "$ANYTLS_RATE_LIMIT" \
        "$ANYTLS_PADDING_FILE" "$ANYTLS_CERT" "$ANYTLS_KEY"; then
        rm -f "$block_file"; error "构建 listener 配置失败。"; return 1
    fi

    init_mihomo_config || { rm -f "$block_file"; return 1; }
    if [[ ! -x "$mihomo_binary_path" ]]; then
        install_mihomo_core || { rm -f "$block_file"; return 1; }
        install_geodata || { rm -f "$block_file"; return 1; }
    fi
    if ! require_jls_capable_mihomo; then rm -f "$block_file"; return 1; fi

    local config_backup
    if ! config_backup=$(backup_config "bak"); then rm -f "$block_file"; error "备份配置失败"; return 1; fi

    if ! append_listener_block "$block_file"; then
        rm -f "$block_file"
        cp "$config_backup" "$mihomo_config_path"
        error "写入配置失败，已恢复原配置。"
        return 1
    fi
    rm -f "$block_file"
    chmod 600 "$mihomo_config_path"

    if ! validate_mihomo_config; then
        cp "$config_backup" "$mihomo_config_path"
        error "新配置未通过 Mihomo 检查，已恢复原配置。"
        return 1
    fi
    success "配置已安全追加到: $mihomo_config_path"

    setup_service || return 1
    if ! restart_mihomo; then
        cp "$config_backup" "$mihomo_config_path"
        service_restart >/dev/null 2>&1 || true
        error "节点启动失败，已恢复原配置。请检查 dest 是否可达。"
        return 1
    fi

    save_node_state "$port" "$mode" "$ANYTLS_PASSWORD" "$ANYTLS_JLS_USER" "$ANYTLS_JLS_PASSWORD" \
        "$ANYTLS_DEST" "$ANYTLS_SNI" "$ANYTLS_ALPN" "$ANYTLS_PROXY" "$ANYTLS_RATE_LIMIT" \
        || warn "节点参数文件写入失败。"

    success "Mihomo AnyTLS 节点安装完成！"
    view_subscription_info "$port"
}

# --- 订阅信息 ---
print_client_yaml() {
    local port=$1 ip=$2 mode=$3 password=$4 jls_user=$5 jls_password=$6
    local sni=$7 alpn=$8

    python3 - "$port" "$ip" "$mode" "$password" "$jls_user" "$jls_password" "$sni" "$alpn" <<'PY'
import json, sys
port, ip, mode, password, jls_user, jls_password, sni, alpn = sys.argv[1:9]
q = lambda v: json.dumps(v, ensure_ascii=False)
label = "AnyTLS-JLS-" if mode == "jls" else "AnyTLS-TLS-"
host = ip
lines = [
    "proxies:",
    f"  - name: {q(label + port)}",
    "    type: anytls",
    f"    server: {q(host)}",
    f"    port: {int(port)}",
    f"    password: {q(password)}",
    "    client-fingerprint: chrome",
    "    udp: true",
]
if sni:
    lines.append(f"    sni: {q(sni)}")
items = [a.strip() for a in alpn.split(',') if a.strip()]
if items:
    lines.append("    alpn: [" + ", ".join(items) + "]")
if mode == "jls":
    lines.append("    jls-opts:")
    lines.append(f"      username: {q(jls_user)}")
    lines.append(f"      password: {q(jls_password)}")
print('\n'.join(lines))
PY
}

view_subscription_info() {
    local target_port="${1:-}"

    if [[ -z "$target_port" ]]; then
        local ports
        ports=$(managed_listener_ports "$node_prefix" || true)
        if [[ -z "$ports" ]]; then error "未找到 AnyTLS 节点配置。"; return; fi
        local port_count; port_count=$(echo "$ports" | wc -l)
        if [[ "$port_count" -eq 1 ]]; then
            target_port=$(echo "$ports" | tr -d ' \n')
        else
            echo "发现多个 AnyTLS 节点:"
            local p
            for p in $ports; do echo " - 端口: $p"; done
            echo ""
            while true; do
                read -p "请输入要查看的端口: " input_p
                if echo "$ports" | grep -q "^$input_p$"; then target_port=$input_p; break
                else error "无效端口"; fi
            done
        fi
    fi

    local mode password jls_user jls_password dest sni alpn
    if [[ -f "$(node_state_file "$target_port")" ]]; then
        mode=$(load_node_state "$target_port" mode)
        password=$(load_node_state "$target_port" password)
        jls_user=$(load_node_state "$target_port" jls_user)
        jls_password=$(load_node_state "$target_port" jls_password)
        dest=$(load_node_state "$target_port" dest)
        sni=$(load_node_state "$target_port" sni)
        alpn=$(load_node_state "$target_port" alpn)
    else
        warn "未找到端口 $target_port 的参数文件，密码等信息需从配置中手工确认。"
        mode="unknown"; password=""; jls_user=""; jls_password=""; dest=""; sni=""; alpn="$default_alpn"
    fi

    local ip
    if [[ -f "$address_file" && -s "$address_file" ]]; then
        ip=$(cat "$address_file"); [[ -z "$ip" ]] && ip=$(get_public_ip)
    else ip=$(get_public_ip); fi
    [[ -z "$ip" ]] && { error "无法确定连接地址。"; return 1; }

    local display_ip; display_ip=$(format_uri_host "$ip")
    local ipinfo_json country org link_name
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null || true)
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | sed 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        org=$(echo "$ipinfo_json" | grep '"org"' | sed 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then link_name="${country} - ${org}"
    else link_name="$(hostname)-${target_port}"; fi

    local client_yaml
    client_yaml=$(print_client_yaml "$target_port" "$ip" "$mode" "$password" "$jls_user" "$jls_password" "$sni" "$alpn")
    local save_file=~/mihomo_anytls_link_${target_port}.txt
    local yaml_file=~/mihomo_anytls_proxies_${target_port}.yaml

    if [[ "$is_quiet" == true ]]; then
        echo "${client_yaml}"
        return
    fi

    printf '%s\n' "$client_yaml" > "$yaml_file"
    chmod 600 "$yaml_file"

    echo "----------------------------------------------------------------"
    echo -e "${green} --- Mihomo AnyTLS 节点信息 --- ${none}"
    echo -e "${yellow} 名称: ${cyan}$link_name${none}"
    echo -e "${yellow} 地址: ${cyan}$ip${none}"
    echo -e "${yellow} 端口: ${cyan}$target_port${none}"
    echo -e "${yellow} 模式: ${cyan}$mode${none}"
    echo -e "${yellow} 密码: ${cyan}$password${none}"
    if [[ "$mode" == "jls" ]]; then
        echo -e "${yellow} JLS 用户名: ${cyan}$jls_user${none}"
        echo -e "${yellow} JLS 密码: ${cyan}$jls_password${none}"
        echo -e "${yellow} JLS dest: ${cyan}$dest${none}"
        [[ -n "$sni" ]] && echo -e "${yellow} SNI: ${cyan}$sni${none}"
        echo -e "${yellow} ALPN: ${cyan}$alpn${none}"
    fi
    echo "----------------------------------------------------------------"
    echo -e "${green} 客户端配置 (已保存到 $yaml_file): ${none}"
    echo ""
    printf '%s\n' "$client_yaml"
    echo "----------------------------------------------------------------"
    if [[ "$mode" == "jls" ]]; then
        echo -e "${yellow}[!] AnyTLS 的 URI 格式只定义了 sni / insecure 两个参数,"
        echo -e "    无法表达 JLS 凭据, 因此上面的 proxies 片段是本节点唯一可用的导入方式。"
        echo -e "    客户端必须使用 mihomo >= ${MIN_MIHOMO_VERSION}。${none}"
        echo ""
        echo -e "    参考链接 (缺 jls-opts, 直接导入会因 JLS 认证失败而回落):"
        echo -e "    ${cyan}anytls://$(url_encode "$password")@${display_ip}:${target_port}?sni=$(url_encode "${sni:-}")#$(url_encode "$link_name")${none}"
    fi
    echo "----------------------------------------------------------------"

    # 兼容旧版: 保留一个与其它脚本同名的链接文件, 便于统一收集
    printf '%s\n' "$client_yaml" > "$save_file"
    chmod 600 "$save_file"
}

# --- 自定义连接地址管理 ---
set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "说明: 如果您使用的是 NAT VPS 或拥有动态 IP 的机器，"
    echo "请在此输入外部可访问的 IP 地址或 DDNS 域名。"
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

# --- 删除 AnyTLS 节点 ---
delete_anytls_node() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi

    echo "当前已安装的 AnyTLS 节点:"
    local ports
    ports=$(managed_listener_ports "$node_prefix" || true)

    if [[ -z "$ports" ]]; then error "未找到任何 AnyTLS 节点，无需删除。"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要删除的端口: " target_p
        if echo "$ports" | grep -q "^$target_p$"; then break
        else error "端口无效，请重新输入。"; fi
    done

    read -p "确定要永久删除端口 $target_p 的 AnyTLS 节点吗？[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi

    info "正在删除节点..."
    local delete_backup
    delete_backup=$(backup_config "bak.del") || { error "备份配置失败"; return 1; }

    remove_managed_listener "$node_prefix" "$target_p" || { error "删除节点配置失败，已保留备份。"; return 1; }

    rm -f "$(node_state_file "$target_p")" 2>/dev/null || true
    rm -f ~/mihomo_anytls_link_${target_p}.txt ~/mihomo_anytls_proxies_${target_p}.yaml 2>/dev/null || true

    if ! validate_mihomo_config || ! service_restart; then
        cp "$delete_backup" "$mihomo_config_path"
        service_restart >/dev/null 2>&1 || true
        error "删除后配置未能正常加载，已恢复原配置。"
        return 1
    fi
    success "AnyTLS 节点 (端口 $target_p) 已删除。"
}

# --- 修改节点配置 ---
modify_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi
    echo "当前 AnyTLS 节点:"
    local ports
    ports=$(managed_listener_ports "$node_prefix" || true)
    if [[ -z "$ports" ]]; then error "未找到节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要修改的端口: " target_p
        if echo "$ports" | grep -q "^$target_p$"; then break; else error "端口未找到"; fi
    done

    local mode password jls_user jls_password dest sni alpn proxy rate_limit
    local cur_state; cur_state=$(node_state_file "$target_p")
    if [[ -f "$cur_state" ]]; then
        mode=$(load_node_state "$target_p" mode)
        password=$(load_node_state "$target_p" password)
        jls_user=$(load_node_state "$target_p" jls_user)
        jls_password=$(load_node_state "$target_p" jls_password)
        dest=$(load_node_state "$target_p" dest)
        sni=$(load_node_state "$target_p" sni)
        alpn=$(load_node_state "$target_p" alpn)
        proxy=$(load_node_state "$target_p" proxy)
        rate_limit=$(load_node_state "$target_p" rate_limit)
        echo -e "${yellow} 当前配置: mode=${mode} dest=${dest} sni=${sni} alpn=${alpn}${none}"
    else
        warn "未找到参数文件，将按默认值重建该节点 (原密码会失效)。"
        mode="jls"; password=$(generate_secret 24); jls_user="jlsuser"
        jls_password=$(generate_secret 24); dest="$default_dest"; sni=""; alpn="$default_alpn"
        proxy=""; rate_limit=0
    fi

    echo ""
    read -p "$(echo -e "保持原密码与 JLS 凭据? [Y/n]: ")" keep
    if [[ "$keep" =~ ^[nN]$ ]]; then
        if [[ "$mode" == "jls" ]]; then
            jls_password=$(generate_secret 24)
            jls_user="jls$(generate_secret 6 | tr 'A-Z' 'a-z')"
        fi
        password=$(generate_secret 24)
        info "已重置 AnyTLS 密码: ${cyan}${password}${none}"
    fi

    if [[ "$mode" == "jls" ]]; then
        local input
        read -p "$(echo -e "JLS dest (当前: ${cyan}${dest}${none}, 直接回车保持不变): ")" input
        if [[ -n "$input" ]]; then
            if is_valid_dest "$input"; then dest="$input"; else error "dest 格式无效，保持不变。"; fi
        fi
        read -p "$(echo -e "JLS SNI (当前: ${cyan}${sni:-自动推导}${none}, 直接回车保持不变): ")" input
        if [[ -n "$input" ]]; then
            if is_valid_domain "$input"; then sni="$input"; else error "SNI 无效，保持不变。"; fi
        fi
        read -p "$(echo -e "ALPN (当前: ${cyan}${alpn}${none}, 直接回车保持不变): ")" input
        [[ -n "$input" ]] && alpn="$input"
    fi

    if ! validate_anytls_fields "$mode" "$dest" "$jls_user" "$jls_password" "$alpn" ""; then
        return 1
    fi

    local modify_backup
    modify_backup=$(backup_config "bak.modify") || { error "备份配置失败"; return 1; }
    remove_managed_listener "$node_prefix" "$target_p" || { error "删除旧节点失败"; return 1; }

    local block_file; block_file=$(mktemp) || { cp "$modify_backup" "$mihomo_config_path"; return 1; }
    if ! build_anytls_block "$block_file" "$target_p" "${node_prefix}${target_p}" "$mode" "$password" \
        "$jls_user" "$jls_password" "$dest" "$sni" "$alpn" "$proxy" "$rate_limit" "" "" ""; then
        rm -f "$block_file"; cp "$modify_backup" "$mihomo_config_path"; error "重建配置失败，已恢复。"; return 1
    fi
    if ! append_listener_block "$block_file" || ! validate_mihomo_config || ! service_restart; then
        rm -f "$block_file"
        cp "$modify_backup" "$mihomo_config_path"
        service_restart >/dev/null 2>&1 || true
        error "修改失败，已恢复原配置。"
        return 1
    fi
    rm -f "$block_file"

    save_node_state "$target_p" "$mode" "$password" "$jls_user" "$jls_password" \
        "$dest" "$sni" "$alpn" "$proxy" "$rate_limit" || warn "节点参数文件写入失败。"
    success "修改完成"
    view_subscription_info "$target_p"
}

update_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    info "正在检查最新版本..."
    local current_version; current_version=$(installed_mihomo_version)
    local latest_version=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || echo "")
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败" && return; fi
    info "当前: ${cyan}${current_version}${none}，最新: ${cyan}${latest_version}${none}"
    if ! install_mihomo_core; then error "更新失败！" && return; fi
    install_geodata || return 1
    if ! restart_mihomo; then return; fi
    success "Mihomo 更新成功！"
}

restart_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return 1; fi
    info "正在重启 Mihomo 服务..."
    if ! service_restart; then error "重启失败"; return 1; fi
    sleep 1
    if ! service_is_active; then error "启动失败，请查看日志"; return 1; fi
    success "Mihomo 服务已成功重启！"
}

uninstall_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    read -p "确定卸载 Mihomo 吗？配置会先自动备份。[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消。"; return; fi
    local config_archive=""
    if ! config_archive=$(backup_config_archive); then
        error "配置备份失败，已取消卸载，未删除任何文件。"
        return 1
    fi
    info "正在卸载..."
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mihomo || true; systemctl disable mihomo || true
        rm -f /etc/systemd/system/mihomo.service; systemctl daemon-reload || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo stop || true; rc-update del mihomo default || true
        rm -f /etc/init.d/mihomo
    fi
    rm -f "$mihomo_binary_path"
    rm -rf "$mihomo_config_dir"
    rm -f ~/mihomo_anytls_link_*.txt ~/mihomo_anytls_proxies_*.yaml /root/mihomo_anytls_node_*.json
    success "Mihomo 已成功卸载；配置备份: $config_archive"
}

view_mihomo_log() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    info "显示日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if command -v journalctl >/dev/null 2>&1; then journalctl -u mihomo -f --no-pager || true
    elif [[ -d /var/log/mihomo ]]; then (tail -n 200 -F /var/log/mihomo/*.log 2>/dev/null) || true
    else error "无法找到日志"; fi
    trap - SIGINT; echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

press_any_key_to_continue() {
    echo ""; read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear
        echo -e "${cyan} Mihomo AnyTLS 一键安装管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${yellow} JLS 模式无需证书, 未认证连接回落 dest;"
        echo -e " 需要 mihomo >= ${MIN_MIHOMO_VERSION}${none}"
        echo "---------------------------------------------"
        check_mihomo_status
        echo -e "${mihomo_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 AnyTLS 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Mihomo"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Mihomo"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Mihomo 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        printf "  ${red}%-2s${none} %-35s\n" "8." "删除 AnyTLS 节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "设置连接地址 (NAT/DDNS)"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Mihomo"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-9]: " choice

        local needs_pause=true
        case $choice in
            1) install_anytls ;;
            2) update_mihomo ;;
            3) restart_mihomo ;;
            4) uninstall_mihomo ;;
            5) view_mihomo_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_subscription_info ;;
            8) delete_anytls_node ;;
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
        local port="" mode="" password="" jls_user="" jls_password=""
        local dest="" sni="" alpn="$default_alpn" proxy="" rate_limit=0 padding_file=""
        local cert_path="" key_path=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --port|--mode|--password|--dest|--sni|--alpn|--proxy|--rate-limit|--padding-file|--jls-user|--jls-password|--cert|--key)
                    [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; exit 1; }
                    case "$1" in
                        --port) port="$2" ;;
                        --mode) mode="$2" ;;
                        --password) password="$2" ;;
                        --dest) dest="$2" ;;
                        --sni) sni="$2" ;;
                        --alpn) alpn="$2" ;;
                        --proxy) proxy="$2" ;;
                        --rate-limit) rate_limit="$2" ;;
                        --padding-file) padding_file="$2" ;;
                        --jls-user) jls_user="$2" ;;
                        --jls-password) jls_password="$2" ;;
                        --cert) cert_path="$2" ;;
                        --key) key_path="$2" ;;
                    esac
                    shift 2
                    ;;
                --quiet|-q) is_quiet=true; shift ;;
                *) error "未知参数: $1"; exit 1 ;;
            esac
        done
        [[ -z "$port" ]] && port=8443
        [[ -z "$mode" ]] && mode="jls"
        if ! is_valid_port "$port"; then error "端口无效。" && exit 1; fi
        if ! [[ "$mode" == "jls" || "$mode" == "tls" ]]; then error "--mode 只能是 jls 或 tls。" && exit 1; fi
        [[ -z "$password" ]] && password=$(generate_secret 24)
        if [[ "$mode" == "jls" ]]; then
            [[ -z "$dest" ]] && dest="$default_dest"
            [[ -z "$rate_limit" ]] && rate_limit=0
            if [[ -z "$jls_user" ]]; then jls_user="jls$(generate_secret 6 | tr 'A-Z' 'a-z')"; fi
            if [[ -z "$jls_password" ]]; then jls_password=$(generate_secret 24); fi
        else
            if [[ -z "$cert_path" || -z "$key_path" ]]; then
                error "--mode tls 需要同时提供 --cert 和 --key。"; exit 1
            fi
        fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用。" && exit 1; fi
        if ! validate_anytls_fields "$mode" "$dest" "$jls_user" "$jls_password" "$alpn" "$padding_file"; then
            exit 1
        fi
        SECURITY_MODE="$mode"
        ANYTLS_CERT=""; ANYTLS_KEY=""
        if [[ "$mode" == "tls" ]]; then
            # 证书必须落在 mihomo home 目录内, 否则 listener 起不来
            mkdir -p "$mihomo_config_dir" || exit 1
            ANYTLS_CERT=$(stage_certificate "$cert_path" "crt" "$port") || exit 1
            ANYTLS_KEY=$(stage_certificate "$key_path" "key" "$port") || exit 1
        fi
        run_install "$port" "$mode" "$password" "$jls_user" "$jls_password" \
            "$dest" "$sni" "$alpn" "$proxy" "$rate_limit" "$padding_file"
    else
        main_menu
    fi
}

main "$@"