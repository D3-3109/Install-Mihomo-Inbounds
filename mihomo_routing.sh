#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 Mihomo 服务端分流脚本 v2.0
# 适配环境：Debian/Ubuntu/Alpine
# 依赖：curl, python3, openssl
# 功能：安装Geo数据、添加Outbounds(代理)、添加Routing(规则)、查询配置
# 增强：支持 Socks5 / SS / VLESS，并支持 IN-NAME 链式路由分流
# ==============================================================================

set -uo pipefail
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/mihomo/config.yaml"
SCRIPT_PATH="/usr/bin/mihomo-routing"
MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_DIR="/usr/local/etc/mihomo"
BASE_URL="${MIHOMO_BASE_URL:-https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main}"

die()     { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; exit 1; }
info()    { echo -e "${GREEN}[INFO] $*${PLAIN}"; }
warn()    { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }
success() { echo -e "${GREEN}[SUCCESS] $*${PLAIN}"; }

pause() {
    echo
    read -n 1 -s -r -p "按任意键回到主菜单..." || true
    echo
}

# --- 权限与依赖检测 ---
pre_check() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请以 root 身份运行此脚本。"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID="${OS_ID,,}"
    else
        die "无法检测系统版本。"
    fi

    local deps=("curl" "python3" "openssl" "realpath" "crontab")
    local missing=false dep
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || missing=true; done

    if [[ "$missing" == true ]]; then
        info "正在安装缺失依赖..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache curl python3 openssl coreutils cronie >/dev/null 2>&1 || die "安装依赖失败。"
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl python3 openssl coreutils cron >/dev/null 2>&1 || die "安装依赖失败。"
        else
            die "不支持自动安装依赖的系统: $OS_ID"
        fi
    fi
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || die "缺少必要命令: $dep"; done
}

is_valid_port()      { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_valid_uuid()      { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_safe_rule_field() { [[ -n "$1" && "$1" != *','* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }

yaml_quote() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

section_name_exists() {
    local section="$1" name="$2"
    [[ -f "$CONFIG_FILE" ]] || return 1
    python3 - "$CONFIG_FILE" "$section" "$name" <<'PY'
import json, re, sys
path, target_section, target_name = sys.argv[1:]
in_section = False
with open(path, encoding="utf-8") as f:
    for raw in f:
        if re.match(r"^[^\s#][^:]*:", raw):
            in_section = raw.split(":", 1)[0].strip() == target_section
            continue
        if not in_section:
            continue
        stripped = raw.strip()
        if not stripped.startswith("- name:"):
            continue
        value = stripped.split(":", 1)[1].strip()
        try:
            value = json.loads(value)
        except Exception:
            value = value.strip("\"'")
        if value == target_name:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

validate_config() {
    if [[ -x "$MIHOMO_BIN" ]]; then
        "$MIHOMO_BIN" -t -d "$MIHOMO_DIR"
    else
        warn "Mihomo 核心不存在，跳过配置语义检查。"
    fi
}

install_self() {
    local current_path
    current_path="$(realpath "$0")"
    if [[ "$current_path" != "$SCRIPT_PATH" ]]; then
        info "正在安装脚本到 $SCRIPT_PATH ..."
        cp "$current_path" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        info "脚本安装完成，可在命令行直接输入 mihomo-routing 使用。"
        sleep 1
        exec "$SCRIPT_PATH" "$@"
    fi
}

restart_mihomo() {
    info "正在重启 Mihomo 服务..."
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if ! systemctl restart mihomo || ! systemctl is-active --quiet mihomo; then
            warn "Mihomo 重启失败，请检查日志"
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if ! rc-service mihomo restart || ! rc-service mihomo status 2>/dev/null | grep -qi started; then
            warn "Mihomo 重启失败"
            return 1
        fi
    else
        warn "未检测到服务管理工具，请手动重启 Mihomo。"
        return 1
    fi
}

# --- 配置注入器 ---
run_insert_proxy() {
    local config=$1 snippet=$2 backup
    backup=$(mktemp "${config}.bak.routing.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$config" "$backup" || { rm -f "$backup"; return 1; }
    chmod 600 "$backup"
    if ! python3 - "$config" "$snippet" <<'PY'
import os, re, stat, sys, tempfile
config_path, yaml_snippet = sys.argv[1], sys.argv[2].rstrip("\n")

with open(config_path, "r", encoding="utf-8") as f:
    content = f.read()

empty = re.compile(r"^proxies:\s*\[\]\s*(?:#.*)?$", re.MULTILINE)
plain = re.compile(r"^proxies:\s*(?:#.*)?$", re.MULTILINE)
if empty.search(content):
    content = empty.sub(lambda _: "proxies:\n" + yaml_snippet, content, count=1)
elif not re.search(r"^proxies:", content, re.MULTILINE):
    content = content.rstrip("\n") + "\n\nproxies:\n" + yaml_snippet + "\n"
elif not plain.search(content):
    raise SystemExit("Unsupported inline proxies configuration")
else:
    lines = content.split("\n")
    in_p = False
    p_line = -1
    last_item = -1
    for i, line in enumerate(lines):
        if plain.match(line):
            in_p, p_line = True, i
            continue
        if in_p:
            if line and not line[0].isspace() and not line.startswith("#") and ":" in line:
                break
            if line.strip() and not line.lstrip().startswith("#"):
                last_item = i
    insert_at = (last_item + 1) if last_item >= 0 else (p_line + 1)
    lines.insert(insert_at, yaml_snippet)
    content = "\n".join(lines)

directory = os.path.dirname(config_path) or "."
fd, tmp = tempfile.mkstemp(prefix=".config.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    os.chmod(tmp, stat.S_IMODE(os.stat(config_path).st_mode))
    os.replace(tmp, config_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
    then
        warn "写入出站配置失败，原配置保留在 $backup"
        return 1
    fi
    if ! validate_config; then
        cp "$backup" "$config"
        warn "新配置未通过检查，已自动回滚。"
        return 1
    fi
    chmod 600 "$config"
}

run_insert_rule() {
    local config=$1 new_rule=$2 backup
    backup=$(mktemp "${config}.bak.routing.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$config" "$backup" || { rm -f "$backup"; return 1; }
    chmod 600 "$backup"
    if ! python3 - "$config" "$new_rule" <<'PY'
import json, os, re, stat, sys, tempfile
config_path = sys.argv[1]
new_rule = "  - " + json.dumps(sys.argv[2], ensure_ascii=False) + "\n"

with open(config_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

empty_rules_replaced = False
for idx, line in enumerate(lines):
    if re.match(r"^rules:\s*\[\]\s*(?:#.*)?$", line.rstrip("\n")):
        lines[idx:idx + 1] = ["rules:\n", new_rule]
        empty_rules_replaced = True
        break
else:
    if not any(re.match(r"^rules:\s*(?:#.*)?$", line.rstrip("\n")) for line in lines):
        lines.append("\nrules:\n")

if empty_rules_replaced:
    result = lines
else:
    result = []
    inserted = False
    in_rules = False
    for line in lines:
        if re.match(r"^rules:\s*(?:#.*)?$", line.rstrip("\n")):
            in_rules = True
            result.append(line)
            continue
        rule_text = line.strip().lstrip("-").strip().strip("\"'")
        if in_rules and rule_text.startswith("MATCH,"):
            if not inserted:
                result.append(new_rule)
                inserted = True
            result.append(line)
            continue
        if in_rules and not inserted:
            if not line.strip() or line.lstrip().startswith("#") or line[0].isspace():
                result.append(line)
            else:
                result.append(new_rule)
                inserted = True
                in_rules = False
                result.append(line)
        else:
            result.append(line)
    if in_rules and not inserted:
        result.append(new_rule)

directory = os.path.dirname(config_path) or "."
fd, tmp = tempfile.mkstemp(prefix=".config.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.writelines(result)
    os.chmod(tmp, stat.S_IMODE(os.stat(config_path).st_mode))
    os.replace(tmp, config_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
    then
        warn "写入路由规则失败，原配置保留在 $backup"
        return 1
    fi
    if ! validate_config; then
        cp "$backup" "$config"
        warn "新配置未通过检查，已自动回滚。"
        return 1
    fi
    chmod 600 "$config"
}

# 将 ss:// 或 vless:// 链接直接解析并渲染为 Mihomo proxy YAML 片段
build_outbound_from_link() {
    local tag=$1 expected_proto=$2 link=$3
    python3 - "$tag" "$expected_proto" "$link" <<'PY'
import base64, json, re, sys, urllib.parse

tag, expected, link = sys.argv[1], sys.argv[2], sys.argv[3].strip()
q = lambda v: json.dumps(v, ensure_ascii=False)

def b64decode(s):
    s = s.strip()
    if len(s) % 4:
        s += "=" * (4 - len(s) % 4)
    try:
        return base64.urlsafe_b64decode(s).decode("utf-8")
    except Exception:
        return base64.b64decode(s).decode("utf-8")

def parse_host_port(value):
    parsed = urllib.parse.urlsplit("//" + value)
    if not parsed.hostname or parsed.port is None or not (1 <= parsed.port <= 65535):
        raise ValueError("地址或端口无效")
    return parsed.hostname, parsed.port

ALLOWED_SS = {
    "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
}

try:
    if expected == "ss":
        if not link.startswith("ss://"):
            raise ValueError("链接必须以 ss:// 开头")
        body = link[5:].split("#", 1)[0].split("?", 1)[0]
        if "@" in body:
            up, hp = body.rsplit("@", 1)
            method = password = ""
            try:
                dec = b64decode(up)
                if ":" in dec and dec.isprintable():
                    method, password = dec.split(":", 1)
            except Exception:
                pass
            if not method:
                if ":" not in up:
                    raise ValueError("SS 用户信息格式无效")
                method, password = up.split(":", 1)
                password = urllib.parse.unquote(password)
            host, port = parse_host_port(hp)
        else:
            dec = b64decode(body)
            if "@" not in dec or ":" not in dec.rsplit("@", 1)[0]:
                raise ValueError("SS Base64 内容无效")
            mp, hp = dec.rsplit("@", 1)
            method, password = mp.split(":", 1)
            host, port = parse_host_port(hp)
        if method not in ALLOWED_SS:
            raise ValueError(f"不支持的 Shadowsocks 加密方式: {method}")
        if not password:
            raise ValueError("SS 密码为空")
        lines = [
            f"  - name: {q(tag)}",
            "    type: ss",
            f"    server: {q(host)}",
            f"    port: {port}",
            f"    cipher: {q(method)}",
            f"    password: {q(password)}",
            "    udp: true",
        ]
        print("\n".join(lines))
    elif expected == "vless":
        if not link.startswith("vless://"):
            raise ValueError("链接必须以 vless:// 开头")
        p = urllib.parse.urlparse(link)
        uuid = urllib.parse.unquote(p.username or "")
        host, port = p.hostname, p.port
        if not uuid or not re.fullmatch(r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}", uuid):
            raise ValueError("VLESS UUID 格式无效")
        if not host or port is None or not (1 <= port <= 65535):
            raise ValueError("VLESS 地址或端口无效")
        qs = urllib.parse.parse_qs(p.query)
        get1 = lambda k, d="": qs.get(k, [d])[0]
        net = get1("type", "tcp")
        if net not in ("tcp", "ws", "grpc"):
            raise ValueError(f"暂不支持导入 VLESS network: {net}")
        sec = get1("security", "none")
        enc = get1("encryption", "none")
        flow = get1("flow", "")
        sni = get1("sni", "")
        pbk = get1("pbk", "")
        sid = get1("sid", "")
        fp = get1("fp", "chrome") or "chrome"
        path = get1("path", "")
        ws_host = get1("host", "")
        svc = get1("serviceName", "")
        alpn = get1("alpn", "")
        insecure = get1("allowInsecure", get1("insecure", "0")).lower() in ("1", "true")

        lines = [
            f"  - name: {q(tag)}",
            "    type: vless",
            f"    server: {q(host)}",
            f"    port: {port}",
            f"    uuid: {q(uuid)}",
            f"    network: {q(net)}",
            "    udp: true",
        ]
        if flow and flow != "none":
            lines.append(f"    flow: {q(flow)}")
        if enc and enc != "none":
            lines.append(f"    encryption: {q(enc)}")
        if net == "ws" and (path or ws_host):
            lines.append("    ws-opts:")
            if path:
                lines.append(f"      path: {q(path)}")
            if ws_host:
                lines += ["      headers:", f"        Host: {q(ws_host)}"]
        elif net == "grpc" and svc:
            lines += ["    grpc-opts:", f"      grpc-service-name: {q(svc)}"]
        if alpn:
            items = [x.strip() for x in alpn.split(",") if x.strip()]
            if items:
                lines.append("    alpn:")
                lines.extend(f"      - {q(x)}" for x in items)
        if sec == "reality":
            if not sni or not pbk:
                raise ValueError("Reality 链接缺少 sni 或 pbk")
            lines += [
                "    tls: true",
                f"    servername: {q(sni)}",
                f"    client-fingerprint: {q(fp)}",
                "    reality-opts:",
                f"      public-key: {q(pbk)}",
            ]
            if sid:
                lines.append(f"      short-id: {q(sid)}")
        elif sec == "tls":
            lines.append("    tls: true")
            if sni:
                lines.append(f"    servername: {q(sni)}")
            if insecure:
                lines.append("    skip-cert-verify: true")
            lines.append(f"    client-fingerprint: {q(fp)}")
        print("\n".join(lines))
    else:
        raise ValueError("未知协议")
except Exception as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
}

# --- 功能 1: 安装 Geo 文件 ---
install_geo_assets() {
    local updater_script="/root/update_geo.sh"
    local updater_url="${BASE_URL}/update_geo.sh"

    info "正在拉取自动更新脚本 update_geo.sh ..."
    local tmp_updater
    tmp_updater=$(mktemp "${updater_script}.tmp.XXXXXX") || { warn "无法创建临时文件"; pause; return 1; }
    if curl -fsSL -o "$tmp_updater" "$updater_url" && bash -n "$tmp_updater" && chmod 0755 "$tmp_updater" && mv -f "$tmp_updater" "$updater_script"; then
        info "脚本下载成功: $updater_script"
    else
        rm -f "$tmp_updater"
        warn "无法从 Github 下载更新脚本。"
        pause
        return 1
    fi

    info "正在执行第一次 Geo 文件下载与安装..."
    if ! "$updater_script"; then
        warn "初始化下载或重启失败。"
        pause
        return 1
    fi

    info "设置 Crontab 定时任务 (每天凌晨 3:00 执行)..."
    local cron_job="0 3 * * * $updater_script >> /var/log/update_geo.log 2>&1"
    local tmp_cron
    tmp_cron=$(mktemp) || { warn "无法创建临时文件"; pause; return 1; }
    crontab -l 2>/dev/null > "$tmp_cron" || true
    sed -i '/update_geo\.sh/d' "$tmp_cron"
    echo "$cron_job" >> "$tmp_cron"
    crontab "$tmp_cron" || warn "写入 crontab 失败，请手动检查。"
    rm -f "$tmp_cron"

    if [[ "$OS_ID" == "alpine" ]] && command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default >/dev/null 2>&1 || true
        rc-service crond start >/dev/null 2>&1 || warn "Cron 服务启动失败，定时更新暂不会执行。"
    elif command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || warn "Cron 服务启动失败，请检查 cron/crond 状态。"
    else
        warn "未能确认 Cron 守护进程状态，请手动确认定时任务服务已启动。"
    fi

    success "Geo 文件自动更新已配置完成！日志保存在: /var/log/update_geo.log"
    pause
}

# --- 功能 2: 添加出站代理 ---
add_outbound() {
    if [[ ! -f "$CONFIG_FILE" ]]; then warn "配置文件不存在: $CONFIG_FILE"; pause; return 1; fi

    echo "================ 添加 Outbounds (出站节点) ================"
    local tag
    while true; do
        read -rp "请输入节点唯一名称 (Tag): " tag
        if ! is_safe_rule_field "$tag"; then
            echo -e "${RED}名称不能为空，也不能包含逗号或换行。${PLAIN}"
            continue
        fi
        if section_name_exists "proxies" "$tag"; then
            echo -e "${RED}名称 '$tag' 已存在，请使用其他名称。${PLAIN}"
        else
            break
        fi
    done

    echo "请选择节点类型:"
    echo "  1) Socks5"
    echo "  2) Shadowsocks (SS)"
    echo "  3) VLESS"
    read -rp "选择 (1-3): " type_choice

    local yaml_snippet=""
    case "$type_choice" in
        1)
            local addr port user pass q_tag q_addr q_user q_pass
            read -rp "地址 (Address): " addr
            read -rp "端口 (Port): " port
            read -rp "用户名 (User, 可留空): " user
            read -rp "密码 (Pass, 可留空): " pass
            [[ -n "$addr" ]] || { warn "地址不能为空"; pause; return 1; }
            is_valid_port "$port" || { warn "端口无效"; pause; return 1; }
            q_tag=$(yaml_quote "$tag"); q_addr=$(yaml_quote "$addr")
            q_user=$(yaml_quote "$user"); q_pass=$(yaml_quote "$pass")
            yaml_snippet=$(cat <<EOF
  - name: ${q_tag}
    type: socks5
    server: ${q_addr}
    port: ${port}
    udp: true
EOF
)
            [[ -n "$user" ]] && yaml_snippet+=$'\n'"    username: ${q_user}"
            [[ -n "$pass" ]] && yaml_snippet+=$'\n'"    password: ${q_pass}"
            ;;
        2)
            echo "添加方式: 1) 粘贴链接  2) 手动输入"
            read -rp "选择 (1/2): " ss_method_choice
            if [[ "$ss_method_choice" == "1" ]]; then
                local link
                read -rp "请输入 SS 分享链接: " link
                yaml_snippet=$(build_outbound_from_link "$tag" "ss" "$link") || { warn "SS 链接解析失败。"; pause; return 1; }
            else
                local addr port m_idx method pass q_tag q_addr q_method q_pass
                read -rp "地址 (Address): " addr
                read -rp "端口 (Port): " port
                echo "加密 (1-6): 1)aes-128-gcm 2)aes-256-gcm 3)chacha20-ietf 4)2022-blake3-aes-128 5)2022-blake3-aes-256 6)2022-blake3-chacha20"
                read -rp "选择: " m_idx
                local methods=("aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305" "2022-blake3-aes-128-gcm" "2022-blake3-aes-256-gcm" "2022-blake3-chacha20-poly1305")
                [[ "$m_idx" =~ ^[1-6]$ ]] || { warn "无效选择"; pause; return 1; }
                method="${methods[$((m_idx-1))]}"
                read -rp "密码: " pass
                [[ -n "$addr" && -n "$pass" ]] || { warn "地址和密码不能为空"; pause; return 1; }
                is_valid_port "$port" || { warn "端口无效"; pause; return 1; }
                q_tag=$(yaml_quote "$tag"); q_addr=$(yaml_quote "$addr")
                q_method=$(yaml_quote "$method"); q_pass=$(yaml_quote "$pass")
                yaml_snippet=$(cat <<EOF
  - name: ${q_tag}
    type: ss
    server: ${q_addr}
    port: ${port}
    cipher: ${q_method}
    password: ${q_pass}
    udp: true
EOF
)
            fi
            ;;
        3)
            local link
            read -rp "请输入 VLESS 分享链接: " link
            yaml_snippet=$(build_outbound_from_link "$tag" "vless" "$link") || { warn "VLESS 链接解析失败。"; pause; return 1; }
            ;;
        *)
            warn "无效选择"
            pause
            return 1
            ;;
    esac

    if ! run_insert_proxy "$CONFIG_FILE" "$yaml_snippet"; then
        pause; return 1
    fi
    info "已添加出站代理: $tag"
    restart_mihomo || warn "配置已写入，但 Mihomo 未能正常重启。"
    pause
}

# --- 功能 3: 添加 Routing 规则 ---
add_routing() {
    if [[ ! -f "$CONFIG_FILE" ]]; then warn "配置文件不存在: $CONFIG_FILE"; pause; return 1; fi

    echo "================ 添加分流规则 (Routing) ================"
    echo "请选择分流规则类型:"
    echo "  1) 指定入站名称 (IN-NAME)   <-- 纯链式代理转发专属"
    echo "  2) 域名后缀 (DOMAIN-SUFFIX)"
    echo "  3) 域名关键词 (DOMAIN-KEYWORD)"
    echo "  4) IP 段 (IP-CIDR)"
    echo "  5) 地理位置 (GEOIP)"
    echo "  6) 站点集合 (GEOSITE)"
    read -rp "选择 (1-6): " rule_type_choice

    local rule_prefix match_value
    case "$rule_type_choice" in
        1)
            rule_prefix="IN-NAME"
            echo "当前可用入站 (Listeners):"
            python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import json, re, sys
in_l = False
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if re.match(r"^[^\s#][^:]*:", line):
            in_l = line.split(":", 1)[0].strip() == "listeners"
            continue
        s = line.strip()
        if in_l and s.startswith("- name:"):
            v = s.split(":", 1)[1].strip()
            try:
                v = str(json.loads(v))
            except Exception:
                v = v.strip("\"'")
            print("  - " + v)
PY
            read -rp "请输入需要被转发的入站名称: " match_value
            ;;
        2) rule_prefix="DOMAIN-SUFFIX" ; read -rp "请输入匹配值 (如 google.com): " match_value ;;
        3) rule_prefix="DOMAIN-KEYWORD" ; read -rp "请输入关键词 (如 google): " match_value ;;
        4) rule_prefix="IP-CIDR" ; read -rp "请输入 IP 段 (如 8.8.8.8/32): " match_value ;;
        5) rule_prefix="GEOIP" ; read -rp "请输入 GEOIP (如 cn): " match_value ;;
        6) rule_prefix="GEOSITE" ; read -rp "请输入 GEOSITE (如 cn): " match_value ;;
        *) warn "无效选择"; pause; return 1 ;;
    esac

    if ! is_safe_rule_field "${match_value:-}"; then
        warn "匹配值不能为空，也不能包含逗号或换行。"
        pause
        return 1
    fi
    if [[ "$rule_prefix" == "IN-NAME" ]] && ! section_name_exists "listeners" "$match_value"; then
        warn "入站名称不存在: $match_value"
        pause
        return 1
    fi

    echo "当前可用目标出站 (Proxies/DIRECT/REJECT):"
    echo "  - DIRECT (直连)"
    echo "  - REJECT (拒绝)"
    python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import json, re, sys
in_p = False
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if re.match(r"^[^\s#][^:]*:", line):
            in_p = line.split(":", 1)[0].strip() == "proxies"
            continue
        s = line.strip()
        if in_p and s.startswith("- name:"):
            v = s.split(":", 1)[1].strip()
            try:
                v = str(json.loads(v))
            except Exception:
                v = v.strip("\"'")
            print("  - " + v)
PY

    local target
    read -rp "请输入最终指向的目标出站名称: " target
    if ! is_safe_rule_field "${target:-}"; then
        warn "目标出站名称无效。"
        pause
        return 1
    fi
    if [[ "$target" != "DIRECT" && "$target" != "REJECT" ]] && ! section_name_exists "proxies" "$target"; then
        warn "目标出站不存在: $target"
        pause
        return 1
    fi

    local rule="${rule_prefix},${match_value},${target}"
    if ! run_insert_rule "$CONFIG_FILE" "$rule"; then
        pause; return 1
    fi

    info "分流规则添加成功: $rule"
    restart_mihomo || warn "配置已写入，但 Mihomo 未能正常重启。"
    pause
}

# --- 功能 4/5/6: 查询配置 ---
query_listeners() {
    echo "================ Listeners (入站) 列表 ================"
    if [[ ! -f "$CONFIG_FILE" ]]; then echo "  (配置文件不存在)"; pause; return 0; fi
    python3 - "$CONFIG_FILE" <<'PY' || echo "  (无)"
import json, re, sys
def scalar(v):
    v = v.strip().split("#", 1)[0].strip()
    try:
        return str(json.loads(v))
    except Exception:
        return v.strip("\"'")

in_l, cur = False, {}
print(f"  {'Tag/名称':25s} {'Type/类型':15s} {'Port/端口'}")
print("  " + "-" * 50)
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if re.match(r"^[^\s#][^:]*:", line):
            if cur:
                print(f"  {cur.get('name','?'):25s} {cur.get('type','?'):15s} {cur.get('port','?')}")
                cur = {}
            in_l = line.split(":", 1)[0].strip() == "listeners"
            continue
        if not in_l:
            continue
        s = line.strip()
        indent = len(line) - len(line.lstrip())
        if s.startswith("- name:"):
            if cur:
                print(f"  {cur.get('name','?'):25s} {cur.get('type','?'):15s} {cur.get('port','?')}")
            cur = {"name": scalar(s.split(":", 1)[1]), "_indent": indent}
        elif cur and indent == cur["_indent"] + 2:
            if s.startswith("type:"):
                cur["type"] = scalar(s.split(":", 1)[1])
            elif s.startswith("port:"):
                cur["port"] = scalar(s.split(":", 1)[1])
if cur:
    print(f"  {cur.get('name','?'):25s} {cur.get('type','?'):15s} {cur.get('port','?')}")
PY
    pause
}

query_proxies() {
    echo "================ Proxies (出站代理) 列表 ================"
    if [[ ! -f "$CONFIG_FILE" ]]; then echo "  (配置文件不存在)"; pause; return 0; fi
    python3 - "$CONFIG_FILE" <<'PY' || echo "  (无)"
import json, re, sys
def scalar(v):
    v = v.strip().split("#", 1)[0].strip()
    try:
        return str(json.loads(v))
    except Exception:
        return v.strip("\"'")

in_p, cur = False, {}
print(f"  {'Tag/名称':20s} {'Type/类型':15s} {'Address/地址':25s} {'Port/端口'}")
print("  " + "-" * 75)
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if re.match(r"^[^\s#][^:]*:", line):
            if cur:
                print(f"  {cur.get('name','?'):20s} {cur.get('type','?'):15s} {cur.get('server','N/A'):25s} {cur.get('port','N/A')}")
                cur = {}
            in_p = line.split(":", 1)[0].strip() == "proxies"
            continue
        if not in_p:
            continue
        s = line.strip()
        indent = len(line) - len(line.lstrip())
        if s.startswith("- name:"):
            if cur:
                print(f"  {cur.get('name','?'):20s} {cur.get('type','?'):15s} {cur.get('server','N/A'):25s} {cur.get('port','N/A')}")
            cur = {"name": scalar(s.split(":", 1)[1]), "_indent": indent}
        elif cur and indent == cur["_indent"] + 2:
            if s.startswith("type:"):
                cur["type"] = scalar(s.split(":", 1)[1])
            elif s.startswith("server:"):
                cur["server"] = scalar(s.split(":", 1)[1])
            elif s.startswith("port:"):
                cur["port"] = scalar(s.split(":", 1)[1])
if cur:
    print(f"  {cur.get('name','?'):20s} {cur.get('type','?'):15s} {cur.get('server','N/A'):25s} {cur.get('port','N/A')}")
PY
    pause
}

query_rules() {
    echo "================ Rules (路由规则) ================"
    if [[ ! -f "$CONFIG_FILE" ]]; then echo "  (配置文件不存在)"; pause; return 0; fi
    python3 - "$CONFIG_FILE" <<'PY' || echo "  (无)"
import re, sys
in_r, idx = False, 0
print("  ID  | 规则 (Rule)")
print("  ------------------------------------------------")
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if re.match(r"^[^\s#][^:]*:", line):
            in_r = line.split(":", 1)[0].strip() == "rules"
            continue
        s = line.strip()
        if in_r and s.startswith("- "):
            idx += 1
            print(f"  {idx:3d} | {s[2:].strip().strip('\"').strip(chr(39))}")
PY
    pause
}

# --- 功能 7: 更新脚本 ---
update_script() {
    info "正在拉取最新版本脚本..."
    local update_url="${BASE_URL}/mihomo_routing.sh"
    local tmp_file
    tmp_file="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")" || die "无法创建临时文件"
    if curl -fsSL "$update_url" -o "$tmp_file" && bash -n "$tmp_file" && chmod 0755 "$tmp_file" && mv -f "$tmp_file" "$SCRIPT_PATH"; then
        info "脚本更新成功，正在重新加载..."
        sleep 1
        exec "$SCRIPT_PATH"
    else
        rm -f "$tmp_file"
        warn "脚本更新失败。"
        pause
    fi
}

# --- 主菜单 ---
show_menu() {
    clear || true
    echo "================================================="
    echo "       Caesar 蜜汁 Mihomo 服务端分流脚本 v2.0     "
    echo "================================================="
    echo
    echo "  1. 安装 Geo 文件 (配置每日自动更新)"
    echo "  2. 添加出站代理 (Socks5 / SS / VLESS)"
    echo "  3. 添加分流规则 (Routing)"
    echo "  4. 查询已有 Listeners (入站)"
    echo "  5. 查询已有 Proxies (出站)"
    echo "  6. 查询已有 Rules (规则)"
    echo "  7. 更新脚本"
    echo "  0. 退出脚本"
    echo "================================================="
    read -rp " 请输入选项 [0-7]: " num

    case "$num" in
        1) install_geo_assets ;;
        2) add_outbound ;;
        3) add_routing ;;
        4) query_listeners ;;
        5) query_proxies ;;
        6) query_rules ;;
        7) update_script ;;
        0) echo -e "${GREEN}感谢使用此脚本，再见！${PLAIN}"; exit 0 ;;
        *) warn "无效输入，请重新选择。"; sleep 1 ;;
    esac
}

main() {
    pre_check
    install_self "$@"
    while true; do
        show_menu
    done
}

main "$@"
