#!/bin/bash

# ==============================================================================
# Mihomo Hysteria2 Realm 汇合服务一键安装管理脚本
# 版本: V-Hy2Realm-Mihomo-1.0
#
# 作为 Mihomo listener 写入 /usr/local/etc/mihomo/config.yaml,
# 和其他协议共用同一个核心、同一份配置、同一套 systemd/OpenRC。
# 字段以 mihomo 文档为准:
#   https://wiki.metacubex.one/config/inbound/listeners/hysteria2-realm/
# ==============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="V-Hy2Realm-Mihomo-1.0"
readonly mihomo_config_dir="/usr/local/etc/mihomo"
readonly mihomo_config_path="${mihomo_config_dir}/config.yaml"
readonly mihomo_binary_path="/usr/local/bin/mihomo"
readonly address_file="/root/inbound_address.txt"
readonly node_prefix="hysteria2-realm-in-"
readonly state_id="hy2realm"
readonly default_port="2080"
readonly MIN_MIHOMO_VERSION="1.19.25"
readonly default_sni="realm.local"
readonly proto_label="Hysteria2 Realm"

readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

mihomo_status_info=""
is_quiet=false
OS_ID=""
INIT_SYSTEM=""

error() { echo -e "\n${red}[✖] $1${none}\n" >&2; }
warn()  { if [[ "$is_quiet" == false ]]; then echo -e "\n${magenta}[⚠] $1${none}\n" >&2; fi; return 0; }
info()  { if [[ "$is_quiet" == false ]]; then echo -e "\n${yellow}[!] $1${none}\n"; fi; return 0; }
success(){ if [[ "$is_quiet" == false ]]; then echo -e "\n${green}[✔] $1${none}\n"; fi; return 0; }

usage() {
    cat <<EOF
Mihomo Hysteria2 Realm 汇合服务一键安装管理脚本 ${SCRIPT_VERSION}

交互菜单:
  sudo $0

非交互:
  sudo $0 install [参数...]

  --token <令牌>         默认随机
  --max-realms <数量>    默认 65536, 0 为不限制
  --max-realms-per-ip <数量>  默认 4
  --cert-mode <none|selfsign|file|acme>  默认 none
  --cert <路径> --key <路径>
  --domain <域名>
  --sni <域名或IP>

通用参数:
  --port <端口>            默认 ${default_port}
  --listen-host <IP>       默认 0.0.0.0
  -q, --quiet              标准输出只保留客户端配置
  -h, --help               显示本帮助
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

version_ge() {
    python3 - "$1" "$2" <<'PY'
import re, sys
def parts(v):
    return tuple(int(x) if x.isdigit() else 0 for x in re.findall(r'\d+', v))
sys.exit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
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

is_valid_username() {
    local name=$1
    [[ ${#name} -ge 1 && ${#name} -le 64 ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
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

is_valid_listen_host() {
    python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null
}

is_valid_dest() {
    local dest=$1 host port
    [[ "$dest" == *:* ]] || return 1
    host="${dest%:*}"
    port="${dest##*:}"
    is_valid_port "$port" || return 1
    [[ -n "$host" ]] || return 1
    if [[ "$host" =~ ^[0-9.]+$ ]] || [[ "$host" == *:* ]]; then return 0; fi
    is_valid_domain "$host"
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
    local port=$1 kind=${2:-tcp}
    case "$kind" in
        tcp) tcp_port_is_bound "$port" && return 0 ;;
        udp) udp_port_is_bound "$port" && return 0 ;;
        both)
            tcp_port_is_bound "$port" && return 0
            udp_port_is_bound "$port" && return 0
            ;;
    esac
    is_listener_port_in_config "$port" && return 0
    return 1
}

json_get() {
    python3 -c 'import json,sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
' "$1" "$2"
}

json_set() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys
path, key, kind, value = sys.argv[1:5]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
if kind == "int":
    data[key] = int(value)
elif kind == "bool":
    data[key] = value == "true"
else:
    data[key] = value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(path, 0o600)
PY
}

write_json() {
    local out=$1
    shift
    python3 - "$out" "$@" <<'PY'
import json, os, sys
out = sys.argv[1]
args = sys.argv[2:]
if len(args) % 2:
    raise SystemExit("internal: odd json fields")
data = {}
for i in range(0, len(args), 2):
    key, val = args[i], args[i + 1]
    if val == "__TRUE__":
        data[key] = True
    elif val == "__FALSE__":
        data[key] = False
    elif val.startswith("__INT__:"):
        data[key] = int(val.split(":", 1)[1])
    else:
        data[key] = val
with open(out, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(out, 0o600)
PY
}

proto() {
    python3 - "$@" <<'PY'

import json, sys, urllib.parse

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

def q(value):
    return json.dumps(value, ensure_ascii=False)

def host_of(ip):
    if ":" in ip and not ip.startswith("["):
        return "[" + ip + "]"
    return ip

def listener_head(st, prefix, ltype):
    return [
        "  - name: " + q(prefix + str(int(st["port"]))),
        "    type: " + q(ltype),
        "    port: %d" % int(st["port"]),
        "    listen: " + q(st.get("listen") or "0.0.0.0"),
    ]

def cert_lines(st):
    if not st.get("certificate"):
        return []
    return [
        "    certificate: " + q(st["certificate"]),
        "    private-key: " + q(st["private_key"]),
    ]

def alpn_lines(alpn):
    items = [part.strip() for part in str(alpn or "").split(",") if part.strip()]
    lines = ["    alpn:"]
    for item in items:
        lines.append("      - " + q(item))
    return lines

def user_ok(name):
    return isinstance(name, str) and 1 <= len(name) <= 64 and all(c.isalnum() or c in "._-" for c in name)

def pass_ok(password):
    return isinstance(password, str) and 8 <= len(password) <= 128 and password.isalnum()

def ws_ok(path):
    path = (path or "").strip()
    return path == "" or (path.startswith("/") and " " not in path and len(path) <= 128)

def tls_errors(st, required):
    errs = []
    mode = st.get("cert_mode") or "none"
    if mode == "none":
        if required:
            errs.append("这个协议必须配置证书 (selfsign、file 或 acme)。")
        return errs
    if mode not in ("selfsign", "file", "acme"):
        errs.append("证书模式只能是 selfsign、file、acme 或 none。")
        return errs
    if mode == "file" and not st.get("certificate"):
        if not st.get("cert_src") or not st.get("key_src"):
            errs.append("file 模式需要同时提供 --cert 和 --key。")
    if mode == "acme" and not st.get("domain") and not st.get("certificate"):
        errs.append("acme 模式需要 --domain。")
    return errs

def yaml_proxy(name, rows):
    lines = ["proxies:", "  - name: " + q(name)]
    lines.extend(rows)
    return "\n".join(lines)


def validate(st):
    errs = []
    token = st.get("token") or ""
    if not pass_ok(token) and not (isinstance(token, str) and 8 <= len(token) <= 128 and token.replace("-", "").replace("_", "").isalnum()):
        errs.append("token 须为 8-128 位字母、数字、下划线或连字符。")
    try:
        realms = int(st.get("max_realms"))
        per_ip = int(st.get("max_per_ip"))
    except (TypeError, ValueError):
        errs.append("max-realms 和 max-realms-per-ip 必须是整数。")
        realms, per_ip = 0, 0
    if realms < 0 or per_ip < 0:
        errs.append("数量上限不能为负数, 0 表示不限制。")
    errs.extend(tls_errors(st, required=False))
    return errs

def build_lines(st, prefix):
    lines = listener_head(st, prefix, "hysteria2-realm")
    lines += [
        "    token: " + q(st["token"]),
        "    max-realms: %d" % int(st["max_realms"]),
        "    max-realms-per-ip: %d" % int(st["max_per_ip"]),
        "    realm-name-pattern: " + q(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"),
    ]
    if (st.get("cert_mode") or "none") != "none":
        lines.extend(cert_lines(st))
        lines.extend(alpn_lines("h2,http/1.1"))
    return lines

def render(st, ip, name):
    tls = (st.get("cert_mode") or "none") != "none"
    scheme = "https" if tls else "http"
    url = "%s://%s:%s" % (scheme, host_of(ip), int(st["port"]))
    lines = [
        "# 这不是代理节点, 而是 Hysteria2 realm-opts 的汇合服务器",
        "server-url: " + url,
        "token: " + st["token"],
        "",
        "# 填进 hysteria2 listener / 客户端的 realm-opts:",
        "realm-opts:",
        "  enable: true",
        "  server-url: " + q(url),
        "  token: " + q(st["token"]),
    ]
    return "\n".join(lines)

def kind(st):
    return "tcp"

def summary(st):
    return "Token: %s\n证书: %s\n最大 realm: %s\n每 IP: %s" % (
        st.get("token", ""), st.get("cert_mode") or "none", st.get("max_realms", ""), st.get("max_per_ip", ""),
    )

def notes(st):
    if (st.get("cert_mode") or "none") == "none":
        return "当前是明文 HTTP。Hysteria2 节点的 realm-opts.server-url 填上面的 http 地址, token 必须一致。不要把它当成 Hysteria2 代理。"
    return "当前通过 TLS 提供 HTTPS。server-url 使用 https, token 必须一致。不要把它当成 Hysteria2 代理。"


def main():
    cmd = sys.argv[1]
    if cmd == "validate":
        errs = validate(load(sys.argv[2]))
        if errs:
            print("\n".join(errs))
            raise SystemExit(1)
    elif cmd == "build":
        st = load(sys.argv[2])
        text = "\n".join(build_lines(st, sys.argv[3])) + "\n"
        with open(sys.argv[4], "w", encoding="utf-8") as handle:
            handle.write(text)
    elif cmd == "render":
        text = render(load(sys.argv[2]), sys.argv[3], sys.argv[4])
        if not text.endswith("\n"):
            text += "\n"
        sys.stdout.write(text)
    elif cmd == "kind":
        print(kind(load(sys.argv[2])))
    elif cmd == "summary":
        print(summary(load(sys.argv[2])))
    elif cmd == "notes":
        text = notes(load(sys.argv[2]))
        if text:
            print(text)
    else:
        raise SystemExit("unknown cmd " + cmd)

if __name__ == "__main__":
    main()

PY
}

install_mihomo_core() {
    info "开始安装 Mihomo 核心..."
    local arch machine
    machine="$(uname -m)"
    case "$machine" in
        # 默认 amd64 新版使用 GOAMD64=v3, 老 CPU 会直接报 illegal instruction
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
    info "目标版本: ${tag:-latest}"

    local tmpdir
    tmpdir="$(mktemp -d)" || return 1
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
    "$mihomo_binary_path" -v 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

require_min_mihomo() {
    [[ -n "$MIN_MIHOMO_VERSION" ]] || return 0
    local current
    current=$(installed_mihomo_version 2>/dev/null || true)
    if [[ -z "$current" ]]; then
        error "未检测到 Mihomo 核心，无法继续。"
        return 1
    fi
    if ! version_ge "$current" "$MIN_MIHOMO_VERSION"; then
        error "当前 Mihomo 版本 $current 不支持 ${proto_label} (需要 >= ${MIN_MIHOMO_VERSION})。"
        error "请先在菜单中选择 [2] 更新 Mihomo 后再安装。"
        return 1
    fi
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
                "$state_dir"/mihomo_http_link_*.txt \
                "$state_dir"/mihomo_http_node_*.json \
                "$state_dir"/mihomo_socks_link_*.txt \
                "$state_dir"/mihomo_socks_node_*.json \
                "$state_dir"/mihomo_mixed_link_*.txt \
                "$state_dir"/mihomo_mixed_node_*.json \
                "$state_dir"/mihomo_tunnel_link_*.txt \
                "$state_dir"/mihomo_tunnel_node_*.json \
                "$state_dir"/mihomo_vmess_link_*.txt \
                "$state_dir"/mihomo_vmess_node_*.json \
                "$state_dir"/mihomo_trojan_link_*.txt \
                "$state_dir"/mihomo_trojan_node_*.json \
                "$state_dir"/mihomo_hysteria2_link_*.txt \
                "$state_dir"/mihomo_hysteria2_node_*.json \
                "$state_dir"/mihomo_shadowquic_link_*.txt \
                "$state_dir"/mihomo_shadowquic_node_*.json \
                "$state_dir"/mihomo_mieru_link_*.txt \
                "$state_dir"/mihomo_mieru_node_*.json \
                "$state_dir"/mihomo_sudoku_link_*.txt \
                "$state_dir"/mihomo_sudoku_node_*.json \
                "$state_dir"/mihomo_trusttunnel_link_*.txt \
                "$state_dir"/mihomo_trusttunnel_node_*.json \
                "$state_dir"/mihomo_hy2realm_link_*.txt \
                "$state_dir"/mihomo_hy2realm_node_*.json \
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
    indent = len(raw) - len(raw.lstrip())
    if in_listeners and skip and indent <= skip_indent and re.match(r"^-(?:\s|$)", stripped):
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

# 删掉最后一个节点后, 空的 "listeners:" 会被下一节顶上来, 变成 null。
# 改回 listeners: [] , 和其他脚本新建配置时的写法一致。
text = "".join(result)
if re.search(r"^listeners:\s*$", text, re.MULTILINE):
    body = []
    in_listeners = False
    empty = True
    for raw in result:
        if re.match(r"^[^\s#][^:]*:", raw):
            if in_listeners and empty:
                body.append("listeners: []\n")
            in_listeners = raw.split(":", 1)[0].strip() == "listeners"
            if not in_listeners:
                body.append(raw)
            continue
        if in_listeners:
            if raw.strip():
                empty = False
                body.append(raw)
            continue
        body.append(raw)
    if in_listeners and empty:
        body.append("listeners: []\n")
    result = body

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

node_state_file() { printf '/root/mihomo_%s_node_%s.json' "$state_id" "$1"; }
node_link_file() { printf '/root/mihomo_%s_link_%s.txt' "$state_id" "$1"; }

save_state_file() {
    local port=$1 src=$2 dest
    dest=$(node_state_file "$port")
    cp "$src" "$dest"
    chmod 600 "$dest"
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

prepare_tls() {
    local state=$1 mode port sni domain src_crt src_key existing_crt existing_key
    mode=$(json_get "$state" cert_mode)
    [[ -z "$mode" || "$mode" == "none" ]] && return 0
    existing_crt=$(json_get "$state" certificate)
    existing_key=$(json_get "$state" private_key)
    if [[ -n "$existing_crt" && -n "$existing_key" && -f "$existing_crt" && -f "$existing_key" ]]; then
        return 0
    fi
    port=$(json_get "$state" port)
    sni=$(json_get "$state" sni)
    domain=$(json_get "$state" domain)
    src_crt=$(json_get "$state" cert_src)
    src_key=$(json_get "$state" key_src)
    [[ -z "$sni" ]] && sni=$default_sni
    local lines crt key skip
    case "$mode" in
        selfsign) lines=$(generate_self_signed "$sni" "$port") || return 1; skip="true" ;;
        file) lines=$(install_cert_pair "$src_crt" "$src_key" "$port") || return 1; skip="false" ;;
        acme) lines=$(issue_acme_certificate "$domain" "$port") || return 1; skip="false" ;;
        *) error "未知证书模式: $mode"; return 1 ;;
    esac
    crt=$(printf '%s\n' "$lines" | sed -n '1p')
    key=$(printf '%s\n' "$lines" | sed -n '2p')
    python3 - "$state" "$crt" "$key" "$sni" "$skip" <<'PY'
import json, os, sys
path, crt, key, sni, skip = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["certificate"] = crt
data["private_key"] = key
data["sni"] = sni
data["skip_cert_verify"] = skip == "true"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.chmod(path, 0o600)
PY
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

wait_listen() {
    local port=$1 kind=$2 i
    for ((i = 0; i < 10; i++)); do
        case "$kind" in
            tcp) tcp_port_is_bound "$port" && return 0 ;;
            udp) udp_port_is_bound "$port" && return 0 ;;
            both) tcp_port_is_bound "$port" && udp_port_is_bound "$port" && return 0 ;;
        esac
        sleep 0.4
    done
    return 1
}

ensure_core() {
    if [[ ! -x "$mihomo_binary_path" ]]; then
        install_mihomo_core || return 1
        install_geodata || return 1
    fi
    require_min_mihomo || return 1
}

apply_listener() {
    local state=$1 replacing=${2:-false}
    local port kind block_file config_backup
    port=$(json_get "$state" port)
    kind=$(proto kind "$state")
    if [[ "$replacing" != "true" ]] && is_port_in_use "$port" "$kind"; then
        error "端口 $port 已被占用, 或已有 listener 使用该端口。"
        return 1
    fi
    ensure_core || return 1
    init_mihomo_config || return 1
    block_file=$(mktemp) || return 1
    if ! proto build "$state" "$node_prefix" "$block_file"; then
        rm -f "$block_file"
        error "构建 ${proto_label} listener 失败。"
        return 1
    fi
    config_backup=$(backup_config "bak") || { rm -f "$block_file"; error "备份配置失败"; return 1; }
    if [[ "$replacing" == "true" ]]; then
        if ! remove_managed_listener "$port"; then
            rm -f "$block_file"
            error "未找到要修改的节点, 原配置未改动。"
            return 1
        fi
    fi
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
    if ! wait_listen "$port" "$kind"; then
        show_recent_log
        rollback_config "$config_backup"
        error "端口 ${port} (${kind}) 没有进入监听, 已回滚该节点。"
        return 1
    fi
    save_state_file "$port" "$state" || warn "节点参数文件写入失败。"
    success "${proto_label} 节点 (端口 ${port}) 已启动。"
    view_node_info "$port"
}

install_from_state() {
    local state=$1
    local errs port kind
    if ! errs=$(proto validate "$state"); then
        error "${errs:-参数无效}"
        return 1
    fi
    port=$(json_get "$state" port)
    kind=$(proto kind "$state")
    if is_port_in_use "$port" "$kind"; then
        error "端口 $port 已被占用, 或已有 listener 使用该端口。"
        return 1
    fi
    prepare_tls "$state" || return 1
    apply_listener "$state" false
}

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
    local required_commands=("awk" "grep" "sed" "curl" "python3" "openssl" "gzip" "base64" "install" "mktemp" "tar")
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
    if [[ ! -f "$mihomo_binary_path" ]]; then
        mihomo_status_info="  Mihomo 状态: ${red}未安装${none}"
        return
    fi
    local mihomo_version service_status count
    mihomo_version=$(installed_mihomo_version 2>/dev/null || echo "未知")
    if service_is_active; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    count=$(managed_listener_ports 2>/dev/null | wc -l | tr -d ' ' || true)
    [[ -z "$count" ]] && count=0
    mihomo_status_info="  Mihomo 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${mihomo_version}${none} | ${proto_label}: ${cyan}${count}${none} 个"
}

select_existing_port() {
    local prompt=$1
    local ports
    ports=$(managed_listener_ports 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        error "未找到 ${proto_label} 节点。"
        return 1
    fi
    echo "当前 ${proto_label} 节点:" >&2
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        echo " - 端口: $p" >&2
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

link_name_for() {
    local port=$1 ipinfo_json country org
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null || true)
    if [[ -n "$ipinfo_json" ]]; then
        country=$(printf '%s\n' "$ipinfo_json" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
        org=$(printf '%s\n' "$ipinfo_json" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then
        printf '%s\n' "${country} - ${org}"
    else
        printf '%s\n' "${state_id}-${port}"
    fi
}

view_node_info() {
    local target_port="${1:-}"
    if [[ -z "$target_port" ]]; then
        local ports count input_p
        ports=$(managed_listener_ports 2>/dev/null || true)
        if [[ -z "$ports" ]]; then error "未找到 ${proto_label} 节点。"; return 1; fi
        count=$(printf '%s\n' "$ports" | wc -l | tr -d ' ')
        if [[ "$count" -eq 1 ]]; then
            target_port=$ports
        else
            target_port=$(select_existing_port "请输入要查看的端口: ") || return 1
        fi
    fi
    local state ip link_name rendered save_file
    state=$(node_state_file "$target_port")
    if [[ ! -f "$state" ]]; then
        error "缺少端口 ${target_port} 的参数文件, 无法还原客户端配置。"
        return 1
    fi
    if [[ -f "$address_file" && -s "$address_file" ]]; then
        ip=$(cat "$address_file")
    else
        ip=$(get_public_ip || true)
    fi
    [[ -z "$ip" ]] && { error "无法确定连接地址。"; return 1; }
    link_name=$(link_name_for "$target_port")
    rendered=$(proto render "$state" "$ip" "$link_name") || { error "生成客户端配置失败。"; return 1; }
    save_file=$(node_link_file "$target_port")
    printf '%s\n' "$rendered" > "$save_file"
    chmod 600 "$save_file"
    if [[ "$is_quiet" == true ]]; then
        printf '%s\n' "$rendered"
        return 0
    fi
    echo "----------------------------------------------------------------"
    echo -e "${green} --- ${proto_label} 节点 (端口 ${target_port}) --- ${none}"
    echo -e "${yellow} 地址: ${cyan}${ip}${none}"
    echo -e "${yellow} 端口: ${cyan}${target_port}${none}"
    proto summary "$state" >&2 || true
    echo "----------------------------------------------------------------"
    echo -e "${green} 客户端配置 (已保存到 ${save_file}):${none}\n"
    printf '%s\n' "$rendered"
    echo "----------------------------------------------------------------"
    proto notes "$state" || true
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

delete_node() {
    local target_p backup crt key
    target_p=$(select_existing_port "请输入要删除的端口: ") || return 0
    local confirm
    read -r -p "确定删除 ${proto_label} 节点 ${target_p}? 其他协议的 listener 会保留。[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "已取消。"; return 0; fi
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
    success "已删除 ${proto_label} 节点 ${target_p}。"
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

remove_geo_updater() {
    local cron_file filtered_file
    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi
    cron_file=$(mktemp) || return 0
    filtered_file=$(mktemp) || { rm -f "$cron_file"; return 0; }
    if ! crontab -l > "$cron_file" 2>/dev/null; then
        rm -f "$cron_file" "$filtered_file"
        return 0
    fi
    awk '
        ($1 ~ /^[0-9*]/ && $6 ~ /^\/root\/update_geo[.]sh($|[<>])/) ||
        ($1 ~ /^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)$/ && $2 ~ /^\/root\/update_geo[.]sh($|[<>])/) { next }
        { print }
    ' "$cron_file" > "$filtered_file" || { rm -f "$cron_file" "$filtered_file"; return 0; }
    if ! cmp -s "$cron_file" "$filtered_file"; then
        crontab "$filtered_file" || true
    fi
    rm -f "$cron_file" "$filtered_file"
    rm -f -- /root/update_geo.sh || true
}

uninstall_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    local confirm config_archive=""
    read -r -p "确定卸载整个 Mihomo 吗? 其他协议的 listener 也会一起删除, 配置会先备份。[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消。"; return; fi
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
    rm -f /root/mihomo_${state_id}_link_*.txt /root/mihomo_${state_id}_node_*.json
    remove_geo_updater || true
    success "Mihomo 已卸载。配置备份: $config_archive"
    info "/root/inbound_address.txt 与其他脚本共用, 未删除。"
}

press_any_key_to_continue() {
    echo ""
    read -r -n 1 -s -p "按任意键返回主菜单..." || true
}

ask_port() {
    local kind=$1 port
    while true; do
        read -r -p "$(echo -e "端口 [1-65535] (默认: ${cyan}${default_port}${none}): ")" port
        [[ -z "$port" ]] && port=$default_port
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port" "$kind"; then error "端口 $port 已被占用"; continue; fi
        printf '%s\n' "$port"
        return 0
    done
}

ask_listen() {
    local listen
    read -r -p "$(echo -e "监听地址 (默认: ${cyan}0.0.0.0${none}): ")" listen
    [[ -z "$listen" ]] && listen="0.0.0.0"
    if ! is_valid_listen_host "$listen"; then
        error "监听地址必须是 IP。"
        return 1
    fi
    printf '%s\n' "$listen"
}

ask_cert_mode() {
    local mode src_crt src_key domain sni
    echo "证书来源:" >&2
    echo -e "  ${green}1.${none} 自签 (客户端 skip-cert-verify)" >&2
    echo -e "  ${cyan}2.${none} 已有证书文件" >&2
    echo -e "  ${cyan}3.${none} ACME (acme.sh, 需要域名和空闲的 TCP/80)" >&2
    local choice
    read -r -p "请选择 [1-3] (默认 1): " choice
    case "${choice:-1}" in
        2) mode="file" ;;
        3) mode="acme" ;;
        *) mode="selfsign" ;;
    esac
    src_crt=""; src_key=""; domain=""; sni=""
    if [[ "$mode" == "file" ]]; then
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
    elif [[ "$mode" == "acme" ]]; then
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
    printf '%s\n%s\n%s\n%s\n%s\n' "$mode" "$sni" "$domain" "$src_crt" "$src_key"
}

install_node() {
    local state
    state=$(mktemp) || return 1
    if ! prompt_state "$state"; then
        rm -f "$state"
        return 1
    fi
    if [[ -x "$mihomo_binary_path" ]]; then
        info "检测到 Mihomo 已安装。继续会追加一个 ${proto_label} listener, 不覆盖其他协议。"
    fi
    install_from_state "$state"
    local status=$?
    rm -f "$state"
    return $status
}

modify_config() {
    local target_p src tmp
    target_p=$(select_existing_port "请输入要修改的端口: ") || return 0
    src=$(node_state_file "$target_p")
    if [[ ! -f "$src" ]]; then
        error "读不到原参数文件, 请删除后重建该节点。"
        return 1
    fi
    tmp=$(mktemp) || return 1
    cp "$src" "$tmp"
    chmod 600 "$tmp"
    if ! prompt_modify "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    local errs
    if ! errs=$(proto validate "$tmp"); then
        error "${errs:-参数无效}"
        rm -f "$tmp"
        return 1
    fi
    info "修改会重写该端口的 listener 并重启 Mihomo。"
    if ! apply_listener "$tmp" true; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

main_menu() {
    while true; do
        clear || true
        echo -e "${cyan} Mihomo Hysteria2 Realm 汇合服务一键安装管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${yellow} 给 hysteria2 realm-opts 用的 HTTP(S) 汇合服务, 不是 Hysteria2 代理节点${none}"
        echo "---------------------------------------------"
        check_mihomo_status
        echo -e "${mihomo_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/添加 Hysteria2 Realm 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Mihomo 核心"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Mihomo 服务"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Mihomo"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看节点信息"
        printf "  ${red}%-2s${none} %-35s\n" "8." "删除 Hysteria2 Realm 节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "设置连接地址 (NAT/DDNS)"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出"
        echo "---------------------------------------------"
        local choice needs_pause
        read -r -p "请输入选项 [0-9]: " choice
        needs_pause=true
        case $choice in
            1) install_node ;;
            2) update_mihomo ;;
            3) restart_mihomo ;;
            4) uninstall_mihomo ;;
            5) view_mihomo_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_node_info "" ;;
            8) delete_node ;;
            9) set_connection_address ;;
            0) success "感谢使用。"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        if [[ "$needs_pause" == true ]]; then press_any_key_to_continue; fi
    done
}

install_noninteractive() {
    local state
    state=$(mktemp) || exit 1
    if ! flags_state "$state" "$@"; then
        rm -f "$state"
        exit 1
    fi
    if ! install_from_state "$state"; then
        rm -f "$state"
        exit 1
    fi
    rm -f "$state"
}


prompt_state() {
    local out=$1 port listen token mode="none" sni="" domain="" src_crt="" src_key="" choice cert_blob
    port=$(ask_port "tcp") || return 1
    listen=$(ask_listen) || return 1
    token=$(generate_secret 24)
    info "已生成 Bearer token: ${token}"
    echo "传输:" >&2
    echo -e "  ${green}1.${none} 明文 HTTP (默认, 不用证书)" >&2
    echo -e "  ${cyan}2.${none} HTTPS (自签 / 已有证书 / ACME)" >&2
    read -r -p "请选择 [1-2] (默认 1): " choice
    if [[ "${choice:-1}" == "2" ]]; then
        cert_blob=$(ask_cert_mode) || return 1
        mode=$(printf '%s\n' "$cert_blob" | sed -n '1p')
        sni=$(printf '%s\n' "$cert_blob" | sed -n '2p')
        domain=$(printf '%s\n' "$cert_blob" | sed -n '3p')
        src_crt=$(printf '%s\n' "$cert_blob" | sed -n '4p')
        src_key=$(printf '%s\n' "$cert_blob" | sed -n '5p')
    fi
    write_json "$out" \
        port "__INT__:${port}" listen "$listen" token "$token" \
        max_realms "__INT__:65536" max_per_ip "__INT__:4" \
        cert_mode "$mode" sni "$sni" domain "$domain" \
        cert_src "$src_crt" key_src "$src_key" certificate "" private_key "" skip_cert_verify "__FALSE__"
}

flags_state() {
    local out=$1
    shift
    local port="" listen="0.0.0.0" token="" max_realms="65536" max_per_ip="4"
    local sni="" cert_mode="" src_crt="" src_key="" domain=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|--listen-host|--token|--max-realms|--max-realms-per-ip|--sni|--cert-mode|--cert|--key|--domain)
                [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; return 1; }
                case "$1" in
                    --port) port="$2" ;;
                    --listen-host) listen="$2" ;;
                    --token) token="$2" ;;
                    --max-realms) max_realms="$2" ;;
                    --max-realms-per-ip) max_per_ip="$2" ;;
                    --sni) sni="$2" ;;
                    --cert-mode) cert_mode="$2" ;;
                    --cert) src_crt="$2" ;;
                    --key) src_key="$2" ;;
                    --domain) domain="$2" ;;
                esac
                shift 2 ;;
            --quiet|-q) is_quiet=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "未知参数: $1"; return 1 ;;
        esac
    done
    [[ -z "$port" ]] && port=$default_port
    [[ -z "$token" ]] && token=$(generate_secret 24)
    if [[ -z "$cert_mode" ]]; then
        if [[ -n "$src_crt" || -n "$src_key" ]]; then cert_mode="file"
        elif [[ -n "$domain" ]]; then cert_mode="acme"
        else cert_mode="none"; fi
    fi
    [[ -z "$sni" && "$cert_mode" == "acme" ]] && sni=$domain
    [[ -z "$sni" && "$cert_mode" != "none" ]] && sni=$default_sni
    is_valid_port "$port" || { error "端口无效。"; return 1; }
    is_valid_listen_host "$listen" || { error "监听地址必须是 IP。"; return 1; }
    [[ "$max_realms" =~ ^[0-9]+$ && "$max_per_ip" =~ ^[0-9]+$ ]] || { error "数量上限必须是整数。"; return 1; }
    if [[ -n "$sni" ]] && ! is_valid_sni "$sni"; then error "SNI 无效。"; return 1; fi
    write_json "$out" \
        port "__INT__:${port}" listen "$listen" token "$token" \
        max_realms "__INT__:${max_realms}" max_per_ip "__INT__:${max_per_ip}" \
        cert_mode "$cert_mode" sni "$sni" domain "$domain" \
        cert_src "$src_crt" key_src "$src_key" certificate "" private_key "" skip_cert_verify "__FALSE__"
}

prompt_modify() {
    local state=$1 input
    read -r -p "新 token (回车保持不变): " input
    if [[ -n "$input" ]]; then
        json_set "$state" token str "$input"
    fi
}

make_sample_state() {
    local out=$1 port="${SAMPLE_PORT:-18090}"
    write_json "$out" \
        port "__INT__:${port}" listen "0.0.0.0" token "realmToken1" \
        max_realms "__INT__:65536" max_per_ip "__INT__:4" \
        cert_mode "none" sni "" domain "" cert_src "" key_src "" \
        certificate "" private_key "" skip_cert_verify "__FALSE__"
}


main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        usage
        exit 0
    fi
    if [[ "${1:-}" == "install" ]]; then
        local arg
        for arg in "$@"; do
            if [[ "$arg" == "--quiet" || "$arg" == "-q" ]]; then
                is_quiet=true
            fi
        done
    fi
    pre_check
    if [[ $# -gt 0 && "$1" == "install" ]]; then
        shift
        if [[ $# -gt 0 ]]; then
            install_noninteractive "$@"
        else
            install_node
        fi
    else
        main_menu
    fi
}

main "$@"
