#!/bin/bash

# ==============================================================================
# Mihomo TUIC v5 一键安装管理脚本
# 版本: V-TUIC-v5-Mihomo-1.0
#
# TUIC v5 作为 Mihomo listener 写进 /usr/local/etc/mihomo/config.yaml,
# 和 VLESS / SS / AnyTLS 共用同一个核心、同一份配置、同一套 systemd/OpenRC。
# 路由工具按 listeners 列表识别入站, 备份/还原/卸载按客户端状态文件名归档,
# 所以这里不另起 tuic-server 进程。
#
# 服务端字段以 mihomo 文档为准 (type: tuic, users 为 UUID:密码):
#   https://wiki.metacubex.one/en/config/inbound/listeners/tuic-v5/
# udp-relay-mode 是客户端参数 (native / quic), 不写进 listener。
# 拥塞控制写进 listener, 客户端输出保持一致。
#
# 证书三种来源:
#   selfsign  脚本用 openssl 生成, 客户端必须 skip-cert-verify
#   file      使用已有 PEM, 复制到配置目录 (mihomo 只读自己的 home)
#   acme      调 acme.sh HTTP-01 申请, 需要域名解析到本机且 TCP/80 空闲
# ==============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="V-TUIC-v5-Mihomo-1.0"
readonly mihomo_config_dir="/usr/local/etc/mihomo"
readonly mihomo_config_path="${mihomo_config_dir}/config.yaml"
readonly mihomo_binary_path="/usr/local/bin/mihomo"
readonly address_file="/root/inbound_address.txt"
readonly node_prefix="tuic-v5-in-"
readonly default_alpn="h3"
readonly default_congestion="bbr"
readonly default_udp_mode="native"
readonly default_sni="tuic.local"

readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

mihomo_status_info=""
is_quiet=false
OS_ID=""
INIT_SYSTEM=""

error() { echo -e "\n${red}[✖] $1${none}\n" >&2; }
warn()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${magenta}[⚠] $1${none}\n" >&2; fi; return 0; }
info()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${yellow}[!] $1${none}\n"; fi; return 0; }
success(){ if [[ "$is_quiet" = false ]]; then echo -e "\n${green}[✔] $1${none}\n"; fi; return 0; }

usage() {
    cat <<EOF
Mihomo TUIC v5 安装脚本 ${SCRIPT_VERSION}

交互菜单:
  sudo $0

非交互 (默认端口 443, 自签证书, 拥塞控制 bbr, ALPN h3, UDP relay native):
  sudo $0 install [--port N] [--listen-host 0.0.0.0]
                  [--uuid UUID] [--password TEXT]
                  [--congestion bbr|cubic|new_reno]
                  [--alpn h3] [--udp-relay-mode native|quic]
                  [--sni 域名或IP]
                  [--cert-mode selfsign|file|acme]
                  [--cert 路径 --key 路径] [--domain 域名]
                  [--quiet]

TUIC 走 QUIC, 请放行 UDP 端口。自签证书的客户端输出会带 skip-cert-verify。
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

format_uri_host() {
    if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

url_encode() {
    python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

generate_secret() {
    local length="${1:-24}"
    python3 - "$length" <<'PY'
import secrets, string, sys
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(int(sys.argv[1]))))
PY
}

generate_uuid() {
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

is_valid_port() { local port=$1; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; }

is_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_valid_password() {
    local password=$1
    [[ ${#password} -ge 8 && ${#password} -le 128 ]] || return 1
    [[ "$password" =~ ^[A-Za-z0-9]+$ ]]
}

is_valid_congestion() {
    case "$1" in
        bbr|cubic|new_reno) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_udp_mode() {
    case "$1" in
        native|quic) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_domain() {
    local domain=$1
    [[ ${#domain} -le 253 ]] || return 1
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

is_valid_sni() {
    python3 -c 'import ipaddress,sys
try:
    ipaddress.ip_address(sys.argv[1]); raise SystemExit(0)
except ValueError:
    raise SystemExit(1)' "$1" 2>/dev/null && return 0
    is_valid_domain "$1"
}

is_valid_alpn_list() {
    local alpn=$1 item
    [[ -n "$alpn" ]] || return 1
    local -a items=()
    IFS=',' read -r -a items <<< "$alpn"
    [[ ${#items[@]} -gt 0 ]] || return 1
    for item in "${items[@]}"; do
        [[ "$item" =~ ^[A-Za-z0-9/._-]+$ ]] || return 1
    done
}

is_valid_listen_host() {
    python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null
}

# TUIC 只占 UDP。ss 不存在时读 /proc/net/udp, 避免只探测 TCP 把端口判空。
udp_port_is_bound() {
    local port=$1
    if python3 - "$port" <<'PY'
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
            if len(cols) < 2 or ":" not in cols[1]:
                continue
            if cols[1].rsplit(":", 1)[1].upper() == want:
                raise SystemExit(0)
raise SystemExit(1)
PY
    then
        return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -uln 2>/dev/null | grep -Eq ":${port}([^0-9]|$)" && return 0
    fi
    return 1
}

tcp_port_is_bound() {
    local port=$1
    python3 - "$port" <<'PY'
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
}

is_listener_port_in_config() {
    local port=$1
    [[ -f "$mihomo_config_path" ]] || return 1
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

is_port_in_use() {
    local port=$1
    if udp_port_is_bound "$port"; then return 0; fi
    if is_listener_port_in_config "$port"; then return 0; fi
    return 1
}

managed_listener_ports() {
    [[ -f "$mihomo_config_path" ]] || return 0
    python3 - "$mihomo_config_path" "$node_prefix" <<'PY'
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

with open(path, encoding="utf-8") as handle:
    for raw in handle:
        if re.match(r"^[^\s#][^:]*:", raw):
            in_listeners = raw.split(":", 1)[0].strip() == "listeners"
            current_name = None
            continue
        if not in_listeners:
            continue
        stripped = raw.strip()
        if stripped.startswith("- name:"):
            current_name = scalar(stripped.split(":", 1)[1])
        elif current_name and current_name.startswith(prefix) and stripped.startswith("port:"):
            value = scalar(stripped.split(":", 1)[1])
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

backup_config_archive() (
    local cfg_dir="${1:-$mihomo_config_dir}" state_dir="${2:-/root}" archive tmp file
    local -a entries=(client-state)
    umask 077
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/client-state" || return 1
    if [[ -d "$cfg_dir" ]]; then
        mkdir -p "$tmp/mihomo" || return 1
        cp -a "$cfg_dir/." "$tmp/mihomo/" || return 1
        entries=(mihomo client-state)
    fi
    for file in "$state_dir"/mihomo_ss_link_*.txt \
                "$state_dir"/mihomo_vless_reality_link_*.txt \
                "$state_dir"/mihomo_reality_pubkey_*.txt \
                "$state_dir"/mihomo_vless_encryption_link_*.txt \
                "$state_dir"/mihomo_vless_encryption_client_key_*.txt \
                "$state_dir"/mihomo_anytls_link_*.txt \
                "$state_dir"/mihomo_anytls_node_*.json \
                "$state_dir"/mihomo_anytls_proxies_*.yaml \
                "$state_dir"/mihomo_tuic_link_*.txt \
                "$state_dir"/mihomo_tuic_node_*.json \
                "$state_dir"/inbound_address.txt; do
        [[ -f "$file" ]] || continue
        cp -pL -- "$file" "$tmp/client-state/" || return 1
    done
    archive=$(mktemp "${state_dir}/mihomo-config-backup-$(date +%Y%m%d%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C "$tmp" "${entries[@]}" || ! chmod 600 "$archive"; then
        rm -f -- "$archive"
        return 1
    fi
    printf '%s\n' "$archive"
)

remove_managed_listener() {
    local port=$1
    python3 - "$mihomo_config_path" "$node_prefix" "$port" <<'PY'
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

with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()

for raw in lines:
    if re.match(r"^[^\s#][^:]*:", raw):
        skip = False
        in_listeners = raw.split(":", 1)[0].strip() == "listeners"
        result.append(raw)
        continue
    stripped = raw.strip()
    indent = len(raw) - len(raw.lstrip(" "))
    if skip and indent <= skip_indent and re.match(r"^-(?:\s|$)", stripped):
        skip = False
    if in_listeners and stripped.startswith("- name:"):
        name = scalar(stripped.split(":", 1)[1])
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

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".config.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(result)
    os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

install_mihomo_core() {
    info "开始安装 Mihomo 核心..."
    local arch machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) arch="amd64-compatible" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7|armv7l) arch="armv7" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac
    [[ "$arch" == "armv7" ]] && warn "ARMv7 构建目前是 Alpha, 可能不稳定。"

    local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    local tag version_str
    tag="$(curl -fsSL "$api" | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    version_str="${tag:-latest}"
    info "目标版本: $version_str"

    local tmpdir filename url_tag url_alt
    tmpdir="$(mktemp -d)" || return 1
    filename="mihomo-linux-${arch}-${tag}.gz"
    url_tag="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${filename}"
    url_alt="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${arch}.gz"
    info "正在下载 Mihomo ($filename)..."
    if [[ -n "${tag:-}" ]] && curl -fL "$url_tag" -o "$tmpdir/mihomo.gz"; then :;
    elif curl -fL "$url_alt" -o "$tmpdir/mihomo.gz"; then :;
    else rm -rf "$tmpdir"; error "下载 Mihomo 失败"; return 1; fi
    if ! gzip -d "$tmpdir/mihomo.gz" || ! chmod +x "$tmpdir/mihomo" || ! "$tmpdir/mihomo" -v >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        error "下载的 Mihomo 核心无法执行, 已取消安装。"
        return 1
    fi
    install -m 0755 "$tmpdir/mihomo" "$mihomo_binary_path" || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$mihomo_config_dir" || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    success "Mihomo 核心安装完成"
}

installed_mihomo_version() {
    [[ -x "$mihomo_binary_path" ]] || return 1
    "$mihomo_binary_path" -v 2>/dev/null | awk 'NR==1 {print $3; exit}'
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
        error "Geo 数据文件下载失败, 原文件未被覆盖。"
        return 1
    fi
    chmod 0644 "$tmpdir/geoip.metadb" "$tmpdir/geosite.dat"
    if ! mv -f "$tmpdir/geoip.metadb" "${mihomo_config_dir}/geoip.metadb" \
        || ! mv -f "$tmpdir/geosite.dat" "${mihomo_config_dir}/geosite.dat"; then
        rm -rf "$tmpdir"
        error "Geo 数据文件安装失败。"
        return 1
    fi
    rm -rf "$tmpdir"
    success "Geo 数据文件已更新"
}

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
    else error "无法确定服务管理器, 请手动配置自启动。"; return 1; fi
}

validate_mihomo_config() {
    if [[ -x "$mihomo_binary_path" ]]; then
        "$mihomo_binary_path" -t -d "$mihomo_config_dir"
    else
        return 0
    fi
}

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

service_restart() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart mihomo || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service mihomo restart || return 1
    else error "无法确定服务管理器, 请手动重启 Mihomo。"; return 1; fi
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
    local distro_detected=false s
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
    local required_commands=("awk" "grep" "sed" "curl" "python3" "gzip" "install" "mktemp" "tar" "openssl")
    local missing_commands=() cmd
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
    if [[ ! -f "$mihomo_binary_path" ]]; then
        mihomo_status_info="  Mihomo 状态: ${red}未安装${none}"
        return
    fi
    local mihomo_version service_status count
    mihomo_version=$(installed_mihomo_version 2>/dev/null || echo "未知")
    if service_is_active; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    count=$(managed_listener_ports 2>/dev/null | wc -l | tr -d ' ' || true)
    [[ -z "$count" ]] && count=0
    mihomo_status_info="  Mihomo 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${mihomo_version}${none} | TUIC: ${cyan}${count}${none} 个"
}

init_mihomo_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then
        info "配置文件不存在, 创建新配置..."
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

cert_paths_for_port() {
    local port=$1
    printf '%s/certs/%s%s.crt\n' "$mihomo_config_dir" "$node_prefix" "$port"
    printf '%s/certs/%s%s.key\n' "$mihomo_config_dir" "$node_prefix" "$port"
}

install_cert_pair() {
    local src_crt=$1 src_key=$2 port=$3
    [[ -f "$src_crt" && -f "$src_key" ]] || { error "证书或私钥不存在。"; return 1; }
    local dir crt key
    dir="${mihomo_config_dir}/certs"
    mkdir -p "$dir" || return 1
    crt="${dir}/${node_prefix}${port}.crt"
    key="${dir}/${node_prefix}${port}.key"
    cp "$src_crt" "$crt" || return 1
    cp "$src_key" "$key" || return 1
    chmod 600 "$crt" "$key"
    printf '%s\n%s\n' "$crt" "$key"
}

generate_self_signed() {
    local sni=$1 port=$2
    local dir crt key san
    dir="${mihomo_config_dir}/certs"
    mkdir -p "$dir" || return 1
    crt="${dir}/${node_prefix}${port}.crt"
    key="${dir}/${node_prefix}${port}.key"
    if python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$sni" 2>/dev/null; then
        san="IP:${sni}"
    else
        san="DNS:${sni}"
    fi
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key" -out "$crt" -days 3650 -nodes \
        -subj "/CN=${sni}" -addext "subjectAltName=${san}" >/dev/null 2>&1; then
        error "生成自签证书失败。"
        rm -f "$crt" "$key"
        return 1
    fi
    chmod 600 "$crt" "$key"
    printf '%s\n%s\n' "$crt" "$key"
}

issue_acme_certificate() {
    local domain=$1 port=$2
    local acme="/root/.acme.sh/acme.sh"
    if tcp_port_is_bound 80; then
        error "ACME HTTP-01 需要占用 TCP/80, 该端口已有进程在监听。"
        return 1
    fi
    if [[ ! -x "$acme" ]]; then
        info "正在安装 acme.sh ..."
        local installer
        installer=$(mktemp) || return 1
        if ! curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o "$installer"; then
            rm -f "$installer"
            error "下载 acme.sh 失败。"
            return 1
        fi
        if ! sh "$installer" --install-online --home /root/.acme.sh >/tmp/acme-install.log 2>&1; then
            rm -f "$installer"
            error "安装 acme.sh 失败, 详情见 /tmp/acme-install.log"
            return 1
        fi
        rm -f "$installer"
    fi
    info "向 Let's Encrypt 申请 ${domain} 的证书 (standalone, TCP/80)..."
    if ! "$acme" --issue --standalone -d "$domain" --httpport 80 --keylength ec-256 --server letsencrypt; then
        error "ACME 申请失败。请确认域名已经解析到这台机器, 并且公网 TCP/80 能进来。"
        return 1
    fi
    local base crt key
    if [[ -f "/root/.acme.sh/${domain}_ecc/fullchain.cer" ]]; then
        base="/root/.acme.sh/${domain}_ecc"
    elif [[ -f "/root/.acme.sh/${domain}/fullchain.cer" ]]; then
        base="/root/.acme.sh/${domain}"
    else
        error "acme.sh 已返回成功, 但没有找到 fullchain.cer。"
        return 1
    fi
    crt="${base}/fullchain.cer"
    key=$(find "$base" -maxdepth 1 -type f -name '*.key' -print -quit)
    [[ -n "$key" && -f "$key" ]] || { error "没有找到 ACME 私钥。"; return 1; }
    install_cert_pair "$crt" "$key" "$port"
}

build_tuic_block() {
    local out_file=$1 port=$2 listen_host=$3 uuid=$4 password=$5
    local congestion=$6 alpn=$7 crt=$8 key=$9
    python3 - "$out_file" "$port" "$listen_host" "$uuid" "$password" "$congestion" "$alpn" "$crt" "$key" "$node_prefix" <<'PY'
import json, sys
out_file, port, listen_host, uuid, password, congestion, alpn, crt, key, prefix = sys.argv[1:11]
q = lambda value: json.dumps(value, ensure_ascii=False)
items = [part.strip() for part in alpn.split(",") if part.strip()]
lines = [
    "  - name: " + q(prefix + port),
    "    type: tuic",
    "    port: %d" % int(port),
    "    listen: " + q(listen_host),
    "    users:",
    "      %s: %s" % (q(uuid), q(password)),
    "    certificate: " + q(crt),
    "    private-key: " + q(key),
    "    congestion-controller: " + q(congestion),
    "    alpn:",
]
for item in items:
    lines.append("      - " + q(item))
with open(out_file, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
}

append_listener_block() {
    local block_file=$1
    python3 - "$mihomo_config_path" "$block_file" <<'PY'
import os, re, stat, sys, tempfile
config_path, block_file = sys.argv[1], sys.argv[2]
with open(block_file, encoding="utf-8") as handle:
    listener_block = handle.read().rstrip("\n")
with open(config_path, encoding="utf-8") as handle:
    content = handle.read()
if re.search(r"^listeners:\s*\[\]\s*(?:#.*)?$", content, re.MULTILINE):
    content = re.sub(r"^listeners:\s*\[\]\s*(?:#.*)?$", "listeners:\n" + listener_block, content, count=1, flags=re.MULTILINE)
elif re.search(r"^listeners:", content, re.MULTILINE):
    lines = content.split("\n")
    result_lines = []
    in_listeners = False
    inserted = False
    for line in lines:
        result_lines.append(line)
        if re.match(r"^listeners:", line):
            in_listeners = True
            continue
        if in_listeners and not inserted:
            if line and not line.startswith(" ") and not line.startswith("#") and ":" in line:
                result_lines.insert(len(result_lines) - 1, listener_block)
                inserted = True
                in_listeners = False
    if in_listeners and not inserted:
        result_lines.append(listener_block)
    content = "\n".join(result_lines)
else:
    content += "\nlisteners:\n" + listener_block + "\n"
directory = os.path.dirname(config_path) or "."
fd, tmp = tempfile.mkstemp(prefix=".config.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(tmp, stat.S_IMODE(os.stat(config_path).st_mode))
    os.replace(tmp, config_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

node_state_file() { printf '/root/mihomo_tuic_node_%s.json' "$1"; }
node_link_file() { printf '/root/mihomo_tuic_link_%s.txt' "$1"; }

save_node_state() {
    local port=$1 uuid=$2 password=$3 congestion=$4 alpn=$5 udp_mode=$6 sni=$7 cert_mode=$8 skip=$9 listen_host=${10}
    local state_file
    state_file=$(node_state_file "$port")
    python3 - "$state_file" "$port" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$cert_mode" "$skip" "$listen_host" <<'PY'
import json, os, sys
(path, port, uuid, password, congestion, alpn, udp_mode, sni, cert_mode, skip, listen_host) = sys.argv[1:12]
data = {
    "port": int(port),
    "uuid": uuid,
    "password": password,
    "congestion": congestion,
    "alpn": alpn,
    "udp_relay_mode": udp_mode,
    "sni": sni,
    "cert_mode": cert_mode,
    "skip_cert_verify": skip == "true",
    "listen": listen_host,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(path, 0o600)
PY
}

load_node_state() {
    local port=$1 key=$2
    local state_file
    state_file=$(node_state_file "$port")
    [[ -f "$state_file" ]] || return 1
    python3 - "$state_file" "$key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

wait_udp_listen() {
    local port=$1 i
    for ((i = 0; i < 10; i++)); do
        if udp_port_is_bound "$port"; then
            return 0
        fi
        sleep 0.4
    done
    return 1
}

show_recent_log() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u mihomo -n 40 --no-pager >&2 || true
    fi
}

rollback_config() {
    local backup=$1
    cp "$backup" "$mihomo_config_path" || true
    chmod 600 "$mihomo_config_path" || true
    service_restart >/dev/null 2>&1 || true
}

run_install_node() {
    local port=$1 listen_host=$2 uuid=$3 password=$4 congestion=$5 alpn=$6 udp_mode=$7 sni=$8 cert_mode=$9 skip=${10} crt=${11} key=${12}

    if [[ ! -x "$mihomo_binary_path" ]]; then
        install_mihomo_core || return 1
        install_geodata || return 1
    fi
    init_mihomo_config || return 1

    local block_file config_backup
    block_file=$(mktemp) || return 1
    if ! build_tuic_block "$block_file" "$port" "$listen_host" "$uuid" "$password" "$congestion" "$alpn" "$crt" "$key"; then
        rm -f "$block_file"
        error "构建 TUIC listener 失败。"
        return 1
    fi
    config_backup=$(backup_config "bak") || { rm -f "$block_file"; error "备份配置失败"; return 1; }
    if ! append_listener_block "$block_file"; then
        rm -f "$block_file"
        rollback_config "$config_backup"
        error "写入配置失败, 已恢复原配置。"
        return 1
    fi
    rm -f "$block_file"
    chmod 600 "$mihomo_config_path"
    if ! validate_mihomo_config; then
        rollback_config "$config_backup"
        error "新配置未通过 Mihomo 检查, 已恢复原配置。"
        return 1
    fi

    if ! service_is_active; then
        setup_service || { rollback_config "$config_backup"; return 1; }
    fi
    if ! service_restart; then
        show_recent_log
        rollback_config "$config_backup"
        error "Mihomo 重启失败, 已恢复原配置。"
        return 1
    fi
    if ! wait_udp_listen "$port"; then
        show_recent_log
        rollback_config "$config_backup"
        error "UDP/${port} 没有进入监听。TUIC 只走 UDP, 已回滚该节点。"
        return 1
    fi

    save_node_state "$port" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$cert_mode" "$skip" "$listen_host" \
        || warn "节点参数文件写入失败, 查看信息时会尝试从配置反查。"
    success "TUIC v5 节点 (UDP ${port}) 已启动。"
    warn "请在防火墙和安全组放行 UDP/${port}。只放行 TCP 时客户端无法连接。"
    view_node_info "$port"
}

prepare_certificate() {
    local port=$1 sni=$2 cert_mode=$3 src_crt=$4 src_key=$5 domain=$6
    case "$cert_mode" in
        selfsign) generate_self_signed "$sni" "$port" ;;
        file) install_cert_pair "$src_crt" "$src_key" "$port" ;;
        acme) issue_acme_certificate "$domain" "$port" ;;
        *) error "未知证书模式: $cert_mode"; return 1 ;;
    esac
}

view_node_info() {
    local target_port="${1:-}"
    if [[ -z "$target_port" ]]; then
        local ports
        ports=$(managed_listener_ports 2>/dev/null || true)
        if [[ -z "$ports" ]]; then error "未找到 TUIC v5 节点。"; return 1; fi
        local count
        count=$(printf '%s\n' "$ports" | wc -l | tr -d ' ')
        if [[ "$count" -eq 1 ]]; then
            target_port=$ports
        else
            echo "当前 TUIC v5 节点:" >&2
            local p
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                echo " - UDP 端口: $p" >&2
            done <<< "$ports"
            local input_p
            while true; do
                read -r -p "请输入要查看的端口: " input_p
                if printf '%s\n' "$ports" | grep -qx "$input_p"; then
                    target_port=$input_p
                    break
                fi
                error "未找到该端口"
            done
        fi
    fi

    local uuid password congestion alpn udp_mode sni cert_mode skip
    uuid=$(load_node_state "$target_port" uuid 2>/dev/null || true)
    password=$(load_node_state "$target_port" password 2>/dev/null || true)
    congestion=$(load_node_state "$target_port" congestion 2>/dev/null || true)
    alpn=$(load_node_state "$target_port" alpn 2>/dev/null || true)
    udp_mode=$(load_node_state "$target_port" udp_relay_mode 2>/dev/null || true)
    sni=$(load_node_state "$target_port" sni 2>/dev/null || true)
    cert_mode=$(load_node_state "$target_port" cert_mode 2>/dev/null || true)
    skip=$(load_node_state "$target_port" skip_cert_verify 2>/dev/null || true)
    [[ -z "$congestion" ]] && congestion=$default_congestion
    [[ -z "$alpn" ]] && alpn=$default_alpn
    [[ -z "$udp_mode" ]] && udp_mode=$default_udp_mode
    [[ -z "$sni" ]] && sni=$default_sni
    [[ -z "$cert_mode" ]] && cert_mode="selfsign"
    [[ -z "$skip" ]] && skip="true"
    if [[ -z "$uuid" || -z "$password" ]]; then
        error "缺少 UUID 或密码, 节点状态文件可能已被删除。"
        return 1
    fi

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
    if [[ -n "$country" && -n "$org" ]]; then link_name="${country} - ${org}"
    else link_name="tuic-v5-${target_port}"; fi

    local rendered surge_line share_link client_yaml
    rendered=$(python3 -c '
import json, re, sys, urllib.parse
name, server, port, uuid, password, congestion, alpn, udp_mode, sni, skip = sys.argv[1:11]
safe = re.sub(r"\s+", " ", name.replace(",", " ").replace("=", " ")).strip() or ("tuic-v5-" + port)
parts = [
    safe + " = tuic-v5",
    server,
    port,
    "uuid=" + uuid,
    "password=" + password,
    "sni=" + sni,
    "alpn=" + alpn.split(",")[0],
]
if skip == "true":
    parts.append("skip-cert-verify=true")
surge = ", ".join(parts)
query = {
    "congestion_control": congestion,
    "udp_relay_mode": udp_mode,
    "alpn": alpn,
    "sni": sni,
}
if skip == "true":
    query["allow_insecure"] = "1"
host = server
if ":" in server and not server.startswith("["):
    host = "[" + server + "]"
share = "tuic://%s:%s@%s:%s?%s#%s" % (
    urllib.parse.quote(uuid, safe=""),
    urllib.parse.quote(password, safe=""),
    host,
    port,
    urllib.parse.urlencode(query),
    urllib.parse.quote(safe, safe=""),
)
alpn_items = [item.strip() for item in alpn.split(",") if item.strip()]
lines = [
    "  - name: " + json.dumps(safe, ensure_ascii=False),
    "    type: tuic",
    "    server: " + json.dumps(server, ensure_ascii=False),
    "    port: " + port,
    "    uuid: " + json.dumps(uuid, ensure_ascii=False),
    "    password: " + json.dumps(password, ensure_ascii=False),
    "    congestion-controller: " + json.dumps(congestion, ensure_ascii=False),
    "    udp-relay-mode: " + json.dumps(udp_mode, ensure_ascii=False),
    "    alpn:",
]
for item in alpn_items:
    lines.append("      - " + json.dumps(item, ensure_ascii=False))
lines.append("    sni: " + json.dumps(sni, ensure_ascii=False))
lines.append("    skip-cert-verify: " + ("true" if skip == "true" else "false"))
lines.append("    udp: true")
print(surge)
print("<<<SHARE>>>")
print(share)
print("<<<YAML>>>")
print("\n".join(lines))
' "$link_name" "$ip" "$target_port" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$skip") || {
        error "生成客户端配置失败。"
        return 1
    }
    surge_line=${rendered%%$'\n'<<<SHARE>>>*}
    local rest=${rendered#*<<<SHARE>>>$'\n'}
    share_link=${rest%%$'\n'<<<YAML>>>*}
    client_yaml=${rest#*<<<YAML>>>$'\n'}

    local save_file udp_state
    save_file=$(node_link_file "$target_port")
    {
        printf '%s\n' "# Surge"
        printf '%s\n' "$surge_line"
        printf '\n%s\n' "# Share"
        printf '%s\n' "$share_link"
        printf '\n%s\n' "# Mihomo"
        printf '%s\n' "$client_yaml"
    } > "$save_file"
    chmod 600 "$save_file"

    if udp_port_is_bound "$target_port"; then udp_state="正在监听"; else udp_state="未监听"; fi
    if [[ "$is_quiet" == true ]]; then
        printf '%s\n\n%s\n\n%s\n' "$surge_line" "$share_link" "$client_yaml"
        return 0
    fi

    echo "----------------------------------------------------------------"
    echo -e "${green} --- TUIC v5 节点 (UDP ${target_port}, ${udp_state}) --- ${none}"
    echo -e "${yellow} 地址:     ${cyan}${ip}${none}"
    echo -e "${yellow} 端口:     ${cyan}${target_port}${none} (UDP/QUIC)"
    echo -e "${yellow} UUID:     ${cyan}${uuid}${none}"
    echo -e "${yellow} 密码:     ${cyan}${password}${none}"
    echo -e "${yellow} 拥塞控制: ${cyan}${congestion}${none}"
    echo -e "${yellow} ALPN:     ${cyan}${alpn}${none}"
    echo -e "${yellow} UDP 中继: ${cyan}${udp_mode}${none} (仅客户端)"
    echo -e "${yellow} SNI:      ${cyan}${sni}${none}"
    echo -e "${yellow} 证书:     ${cyan}${cert_mode}${none}"
    echo "----------------------------------------------------------------"
    echo -e "${green} Surge tuic-v5:${none}"
    echo -e "${cyan}${surge_line}${none}"
    echo
    echo -e "${green} 分享链接:${none}"
    echo -e "${cyan}${share_link}${none}"
    echo
    echo -e "${green} Mihomo proxies 片段 (已保存到 ${save_file}):${none}\n"
    echo -e "${cyan}${client_yaml}${none}"
    echo "----------------------------------------------------------------"
    if [[ "$skip" == "true" ]]; then
        echo -e "${yellow}[!] 这是自签证书。客户端必须打开 skip-cert-verify (分享链接里的 allow_insecure=1), 并使用 SNI ${sni}。${none}"
    else
        echo -e "${yellow}[!] 使用正式证书。客户端不要跳过校验, SNI 必须是 ${sni}。${none}"
    fi
    echo -e "${yellow}[!] 防火墙请放行 UDP/${target_port}。${none}"
    echo "----------------------------------------------------------------"
}

select_existing_port() {
    local prompt=$1
    local ports
    ports=$(managed_listener_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        error "未找到 TUIC v5 节点。"
        return 1
    fi
    echo "当前 TUIC v5 节点:" >&2
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        echo " - UDP 端口: $p" >&2
    done <<< "$ports"
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

set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "这个文件与本仓库其他脚本共用, 卸载 Mihomo 时不会删除。"
    if [[ -f "$address_file" ]]; then
        echo -e "当前已设置: ${cyan}$(cat "$address_file")${none}"
    else
        echo -e "当前状态: ${yellow}自动获取公网 IP${none}"
    fi
    local new_addr normalized_addr
    read -r -p "请输入新的连接地址 (留空则恢复自动获取): " new_addr
    if [[ -z "$new_addr" ]]; then
        rm -f "$address_file"
        success "已恢复为自动获取公网 IP。"
        return 0
    fi
    if ! normalized_addr=$(normalize_connection_address "$new_addr"); then
        error "连接地址无效, 请输入纯 IP 或域名。"
        return 1
    fi
    printf '%s\n' "$normalized_addr" > "$address_file"
    chmod 600 "$address_file"
    success "连接地址已更新为: $normalized_addr"
}

prompt_install() {
    local port listen_host uuid password congestion alpn udp_mode sni cert_mode domain
    while true; do
        read -r -p "$(echo -e "UDP 端口 [1-65535] (默认: ${cyan}443${none}): ")" port
        [[ -z "$port" ]] && port=443
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "UDP ${port} 已被占用, 或已有 listener 使用该端口。"; continue; fi
        break
    done
    echo -e "${yellow}[!] 监听地址一般填 0.0.0.0。TUIC 不使用 TCP。${none}"
    read -r -p "$(echo -e "监听地址 (默认: ${cyan}0.0.0.0${none}): ")" listen_host
    [[ -z "$listen_host" ]] && listen_host="0.0.0.0"
    uuid=$(generate_uuid)
    password=$(generate_secret 24)
    info "已生成 UUID: ${cyan}${uuid}${none}"
    info "已生成密码: ${cyan}${password}${none}"
    echo "拥塞控制:"
    echo -e "  ${green}1.${none} bbr (默认)"
    echo -e "  ${cyan}2.${none} cubic"
    echo -e "  ${cyan}3.${none} new_reno"
    local cc_choice
    read -r -p "请选择 [1-3] (默认 1): " cc_choice
    case "${cc_choice:-1}" in
        2) congestion="cubic" ;;
        3) congestion="new_reno" ;;
        *) congestion="bbr" ;;
    esac
    read -r -p "$(echo -e "ALPN (默认: ${cyan}${default_alpn}${none}, 多个用逗号分隔): ")" alpn
    [[ -z "$alpn" ]] && alpn=$default_alpn
    echo "客户端 UDP relay mode (服务端不需要这个字段):"
    echo -e "  ${green}1.${none} native (默认)"
    echo -e "  ${cyan}2.${none} quic"
    local udp_choice
    read -r -p "请选择 [1-2] (默认 1): " udp_choice
    case "${udp_choice:-1}" in
        2) udp_mode="quic" ;;
        *) udp_mode="native" ;;
    esac
    echo "证书来源:"
    echo -e "  ${green}1.${none} 自签 (客户端 skip-cert-verify)"
    echo -e "  ${cyan}2.${none} 已有证书文件"
    echo -e "  ${cyan}3.${none} ACME (acme.sh, 需要域名和空闲的 TCP/80)"
    local cert_choice src_crt="" src_key=""
    read -r -p "请选择 [1-3] (默认 1): " cert_choice
    case "${cert_choice:-1}" in
        2) cert_mode="file" ;;
        3) cert_mode="acme" ;;
        *) cert_mode="selfsign" ;;
    esac
    domain=""
    if [[ "$cert_mode" == "file" ]]; then
        while true; do
            read -r -p "证书 PEM 路径: " src_crt
            [[ -f "$src_crt" ]] && break
            error "文件不存在: $src_crt"
        done
        while true; do
            read -r -p "私钥 PEM 路径: " src_key
            [[ -f "$src_key" ]] && break
            error "文件不存在: $src_key"
        done
        read -r -p "$(echo -e "SNI / 证书域名 (默认: ${cyan}${default_sni}${none}): ")" sni
        [[ -z "$sni" ]] && sni=$default_sni
    elif [[ "$cert_mode" == "acme" ]]; then
        while true; do
            read -r -p "ACME 域名: " domain
            if is_valid_domain "$domain"; then break; fi
            error "域名无效"
        done
        sni=$domain
    else
        read -r -p "$(echo -e "自签证书 SNI (默认: ${cyan}${default_sni}${none}): ")" sni
        [[ -z "$sni" ]] && sni=$default_sni
    fi

    TUIC_PORT=$port
    TUIC_LISTEN=$listen_host
    TUIC_UUID=$uuid
    TUIC_PASSWORD=$password
    TUIC_CC=$congestion
    TUIC_ALPN=$alpn
    TUIC_UDP=$udp_mode
    TUIC_SNI=$sni
    TUIC_CERT_MODE=$cert_mode
    TUIC_DOMAIN=$domain
    TUIC_SRC_CRT=$src_crt
    TUIC_SRC_KEY=$src_key
}

validate_settings() {
    local port=$1 listen_host=$2 uuid=$3 password=$4 congestion=$5 alpn=$6 udp_mode=$7 sni=$8 cert_mode=$9 domain=${10}
    is_valid_port "$port" || { error "端口无效: $port"; return 1; }
    is_valid_listen_host "$listen_host" || { error "监听地址必须是 IP: $listen_host"; return 1; }
    is_valid_uuid "$uuid" || { error "UUID 格式无效。"; return 1; }
    is_valid_password "$password" || { error "密码须为 8-128 位字母或数字。"; return 1; }
    is_valid_congestion "$congestion" || { error "拥塞控制只能是 bbr、cubic 或 new_reno。"; return 1; }
    is_valid_alpn_list "$alpn" || { error "ALPN 无效: $alpn"; return 1; }
    is_valid_udp_mode "$udp_mode" || { error "udp-relay-mode 只能是 native 或 quic。"; return 1; }
    is_valid_sni "$sni" || { error "SNI 必须是域名或 IP: $sni"; return 1; }
    case "$cert_mode" in
        selfsign|file|acme) ;;
        *) error "证书模式只能是 selfsign、file 或 acme。"; return 1 ;;
    esac
    if [[ "$cert_mode" == "acme" ]]; then
        is_valid_domain "$domain" || { error "ACME 需要一个域名。"; return 1; }
    fi
}

install_tuic_node() {
    if [[ -x "$mihomo_binary_path" ]]; then
        info "检测到 Mihomo 已安装。继续会追加一个 TUIC listener, 不覆盖其他协议。"
    fi
    prompt_install || return 1
    validate_settings "$TUIC_PORT" "$TUIC_LISTEN" "$TUIC_UUID" "$TUIC_PASSWORD" "$TUIC_CC" "$TUIC_ALPN" "$TUIC_UDP" "$TUIC_SNI" "$TUIC_CERT_MODE" "$TUIC_DOMAIN" || return 1
    if is_port_in_use "$TUIC_PORT"; then error "UDP ${TUIC_PORT} 已被占用。"; return 1; fi
    local cert_lines crt key skip
    cert_lines=$(prepare_certificate "$TUIC_PORT" "$TUIC_SNI" "$TUIC_CERT_MODE" "$TUIC_SRC_CRT" "$TUIC_SRC_KEY" "$TUIC_DOMAIN") || return 1
    crt=$(printf '%s\n' "$cert_lines" | sed -n '1p')
    key=$(printf '%s\n' "$cert_lines" | sed -n '2p')
    if [[ "$TUIC_CERT_MODE" == "selfsign" ]]; then skip="true"; else skip="false"; fi
    if ! run_install_node "$TUIC_PORT" "$TUIC_LISTEN" "$TUIC_UUID" "$TUIC_PASSWORD" "$TUIC_CC" "$TUIC_ALPN" "$TUIC_UDP" "$TUIC_SNI" "$TUIC_CERT_MODE" "$skip" "$crt" "$key"; then
        rm -f "$crt" "$key"
        return 1
    fi
}

delete_tuic_node() {
    local target_p
    target_p=$(select_existing_port "请输入要删除的 UDP 端口: ") || return 0
    local confirm
    read -r -p "确定删除 TUIC 节点 ${target_p}? 其他协议的 listener 会保留。[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "已取消。"; return 0; fi
    local backup crt key
    backup=$(backup_config "bak.delete") || { error "备份配置失败"; return 1; }
    if ! remove_managed_listener "$target_p"; then
        error "未找到该节点。"
        return 1
    fi
    if ! validate_mihomo_config || ! service_restart; then
        cp "$backup" "$mihomo_config_path"
        service_restart >/dev/null 2>&1 || true
        error "删除后服务未能启动, 已恢复原配置。"
        return 1
    fi
    crt="${mihomo_config_dir}/certs/${node_prefix}${target_p}.crt"
    key="${mihomo_config_dir}/certs/${node_prefix}${target_p}.key"
    rm -f "$crt" "$key" "$(node_state_file "$target_p")" "$(node_link_file "$target_p")"
    success "已删除 TUIC 节点 ${target_p}。"
}

modify_config() {
    local target_p
    target_p=$(select_existing_port "请输入要修改的 UDP 端口: ") || return 0
    local uuid password congestion alpn udp_mode sni cert_mode skip listen_host
    uuid=$(load_node_state "$target_p" uuid 2>/dev/null || true)
    password=$(load_node_state "$target_p" password 2>/dev/null || true)
    congestion=$(load_node_state "$target_p" congestion 2>/dev/null || echo "$default_congestion")
    alpn=$(load_node_state "$target_p" alpn 2>/dev/null || echo "$default_alpn")
    udp_mode=$(load_node_state "$target_p" udp_relay_mode 2>/dev/null || echo "$default_udp_mode")
    sni=$(load_node_state "$target_p" sni 2>/dev/null || echo "$default_sni")
    cert_mode=$(load_node_state "$target_p" cert_mode 2>/dev/null || echo "selfsign")
    skip=$(load_node_state "$target_p" skip_cert_verify 2>/dev/null || echo "true")
    listen_host=$(load_node_state "$target_p" listen 2>/dev/null || echo "0.0.0.0")
    if [[ -z "$uuid" || -z "$password" ]]; then
        error "读不到原 UUID/密码, 请删除后重建该节点。"
        return 1
    fi
    info "修改会重写该端口的 listener 并重启 Mihomo。证书文件保持不变。"
    local input
    read -r -p "新密码 (回车保持不变): " input
    [[ -n "$input" ]] && password=$input
    read -r -p "$(echo -e "拥塞控制 [bbr/cubic/new_reno] (当前: ${cyan}${congestion}${none}): ")" input
    [[ -n "$input" ]] && congestion=$input
    read -r -p "$(echo -e "ALPN (当前: ${cyan}${alpn}${none}): ")" input
    [[ -n "$input" ]] && alpn=$input
    read -r -p "$(echo -e "客户端 udp-relay-mode [native/quic] (当前: ${cyan}${udp_mode}${none}): ")" input
    [[ -n "$input" ]] && udp_mode=$input
    validate_settings "$target_p" "$listen_host" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$cert_mode" "$sni" || return 1
    local crt key
    crt="${mihomo_config_dir}/certs/${node_prefix}${target_p}.crt"
    key="${mihomo_config_dir}/certs/${node_prefix}${target_p}.key"
    [[ -f "$crt" && -f "$key" ]] || { error "找不到该节点的证书文件。"; return 1; }

    local backup block_file
    backup=$(backup_config "bak.modify") || { error "备份失败"; return 1; }
    block_file=$(mktemp) || return 1
    if ! build_tuic_block "$block_file" "$target_p" "$listen_host" "$uuid" "$password" "$congestion" "$alpn" "$crt" "$key"; then
        rm -f "$block_file"
        error "重建配置失败。"
        return 1
    fi
    if ! remove_managed_listener "$target_p" || ! append_listener_block "$block_file"; then
        rm -f "$block_file"
        rollback_config "$backup"
        error "写入失败, 已恢复原配置。"
        return 1
    fi
    rm -f "$block_file"
    if ! validate_mihomo_config || ! service_restart || ! wait_udp_listen "$target_p"; then
        show_recent_log
        rollback_config "$backup"
        error "修改后 UDP/${target_p} 未就绪, 已恢复原配置。"
        return 1
    fi
    save_node_state "$target_p" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$cert_mode" "$skip" "$listen_host" || true
    success "修改完成"
    view_node_info "$target_p"
}

update_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    local current_version latest_version
    current_version=$(installed_mihomo_version 2>/dev/null || echo "未知")
    latest_version=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep -oE '"tag_name":\s*"[^"]+"' | cut -d'"' -f4 || true)
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败"; return 1; fi
    info "当前: ${cyan}${current_version}${none}, 最新: ${cyan}${latest_version}${none}"
    install_mihomo_core || { error "更新失败"; return 1; }
    install_geodata || return 1
    service_restart || return 1
    success "Mihomo 更新成功。"
}

restart_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return 1; fi
    info "正在重启 Mihomo..."
    if ! service_restart; then error "重启失败"; return 1; fi
    success "Mihomo 已重启。"
}

view_mihomo_log() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    info "显示日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u mihomo -f --no-pager || true
    else
        error "当前环境没有 journalctl。OpenRC 请查看 /var/log/messages。"
    fi
    trap - SIGINT
    echo ""
    read -r -n 1 -s -p "按任意键返回主菜单..." || true
}

uninstall_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    local confirm
    read -r -p "确定卸载整个 Mihomo 吗? 其他协议的 listener 也会一起删除, 配置会先备份。[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消。"; return; fi
    local config_archive=""
    if ! config_archive=$(backup_config_archive "$mihomo_config_dir" /root); then
        error "配置备份失败, 已取消卸载。"
        return 1
    fi
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mihomo || true
        systemctl disable mihomo || true
        rm -f /etc/systemd/system/mihomo.service
        systemctl daemon-reload || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo stop || true
        rc-update del mihomo default || true
        rm -f /etc/init.d/mihomo
    fi
    rm -f "$mihomo_binary_path"
    rm -rf "$mihomo_config_dir"
    rm -f /root/mihomo_tuic_link_*.txt /root/mihomo_tuic_node_*.json
    success "Mihomo 已卸载。配置备份: $config_archive"
    info "/root/inbound_address.txt 与其他脚本共用, 未删除。"
}

press_any_key_to_continue() {
    echo ""
    read -r -n 1 -s -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear || true
        echo -e "${cyan} Mihomo TUIC v5 一键安装管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${yellow} 作为 Mihomo listener 运行, 与其他协议共用配置;"
        echo -e " 流量在 UDP (QUIC), 防火墙要放行 UDP 端口${none}"
        echo "---------------------------------------------"
        check_mihomo_status
        echo -e "${mihomo_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/添加 TUIC v5 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Mihomo 核心"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Mihomo 服务"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Mihomo"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看节点信息"
        printf "  ${red}%-2s${none} %-35s\n" "8." "删除 TUIC 节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "设置连接地址 (NAT/DDNS)"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出"
        echo "---------------------------------------------"
        local choice needs_pause
        read -r -p "请输入选项 [0-9]: " choice
        needs_pause=true
        case $choice in
            1) install_tuic_node ;;
            2) update_mihomo ;;
            3) restart_mihomo ;;
            4) uninstall_mihomo ;;
            5) view_mihomo_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_node_info "" ;;
            8) delete_tuic_node ;;
            9) set_connection_address ;;
            0) success "感谢使用。"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        if [[ "$needs_pause" == true ]]; then press_any_key_to_continue; fi
    done
}

install_tuic_noninteractive() {
    local port="" listen_host="0.0.0.0" uuid="" password="" congestion="$default_congestion"
    local alpn="$default_alpn" udp_mode="$default_udp_mode" sni="" cert_mode=""
    local src_crt="" src_key="" domain=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|--listen-host|--uuid|--password|--congestion|--alpn|--udp-relay-mode|--sni|--cert-mode|--cert|--key|--domain)
                [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; exit 1; }
                case "$1" in
                    --port) port="$2" ;;
                    --listen-host) listen_host="$2" ;;
                    --uuid) uuid="$2" ;;
                    --password) password="$2" ;;
                    --congestion) congestion="$2" ;;
                    --alpn) alpn="$2" ;;
                    --udp-relay-mode) udp_mode="$2" ;;
                    --sni) sni="$2" ;;
                    --cert-mode) cert_mode="$2" ;;
                    --cert) src_crt="$2" ;;
                    --key) src_key="$2" ;;
                    --domain) domain="$2" ;;
                esac
                shift 2
                ;;
            --quiet|-q) is_quiet=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知参数: $1"; exit 1 ;;
        esac
    done
    [[ -z "$port" ]] && port=443
    [[ -z "$uuid" ]] && uuid=$(generate_uuid)
    [[ -z "$password" ]] && password=$(generate_secret 24)
    if [[ -z "$cert_mode" ]]; then
        if [[ -n "$src_crt" || -n "$src_key" ]]; then
            cert_mode="file"
        elif [[ -n "$domain" ]]; then
            cert_mode="acme"
        else
            cert_mode="selfsign"
        fi
    fi
    if [[ "$cert_mode" == "acme" && -z "$sni" ]]; then
        sni=$domain
    fi
    [[ -z "$sni" ]] && sni=$default_sni
    validate_settings "$port" "$listen_host" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$cert_mode" "$domain" || exit 1
    if [[ "$cert_mode" == "file" && ( -z "$src_crt" || -z "$src_key" ) ]]; then
        error "file 模式需要同时提供 --cert 和 --key。"
        exit 1
    fi
    if is_port_in_use "$port"; then
        error "UDP ${port} 已被占用, 或配置里已有同端口 listener。"
        exit 1
    fi
    local cert_lines crt key skip
    cert_lines=$(prepare_certificate "$port" "$sni" "$cert_mode" "$src_crt" "$src_key" "$domain") || exit 1
    crt=$(printf '%s\n' "$cert_lines" | sed -n '1p')
    key=$(printf '%s\n' "$cert_lines" | sed -n '2p')
    if [[ "$cert_mode" == "selfsign" ]]; then skip="true"; else skip="false"; fi
    if ! run_install_node "$port" "$listen_host" "$uuid" "$password" "$congestion" "$alpn" "$udp_mode" "$sni" "$cert_mode" "$skip" "$crt" "$key"; then
        rm -f "$crt" "$key"
        exit 1
    fi
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
            install_tuic_noninteractive "$@"
        else
            install_tuic_node
        fi
    else
        main_menu
    fi
}

main "$@"
