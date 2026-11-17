#!/bin/bash
# ==============================================================================
# Mihomo 服务端全协议入站统一安装与管理脚本 (install_mihomo.sh)
# 支持交互式选择任意协议安装，也支持命令行参数一键部署与节点生命周期管理。
# ==============================================================================

set -uo pipefail

readonly SELF_CMD_PATH="/usr/bin/mihomo-inbounds"
mihomo_config_dir="/usr/local/etc/mihomo"
mihomo_config_path="${mihomo_config_dir}/config.yaml"
mihomo_binary_path="/usr/local/bin/mihomo"
address_file="/root/inbound_address.txt"

readonly red='\e[91m'
readonly green='\e[92m'
readonly yellow='\e[93m'
readonly magenta='\e[95m'
readonly cyan='\e[96m'
readonly none='\e[0m'

is_quiet=false
INIT_SYSTEM=""
OS_ID=""

error()   { echo -e "\n${red}[✖] $1${none}\n" >&2; }
warn()    { [[ "$is_quiet" == false ]] && echo -e "\n${magenta}[⚠] $1${none}\n" >&2; return 0; }
info()    { [[ "$is_quiet" == false ]] && echo -e "\n${yellow}[!] $1${none}\n"; return 0; }
success() { [[ "$is_quiet" == false ]] && echo -e "\n${green}[✔] $1${none}\n"; return 0; }

emit_quiet_result() {
    if { true >&3; } 2>/dev/null; then
        printf '%s\n' "$1" >&3
    else
        printf '%s\n' "$1"
    fi
}

press_any_key_to_continue() {
    echo ""
    read -r -n 1 -s -p "按任意键继续..." || true
}

# --- 帮助信息 ---

usage() {
    local topic="${1:-}"
    if [[ -n "$topic" ]]; then
        proto_help "$topic"
        return $?
    fi
    cat <<EOF
Mihomo 服务端入站统一安装与管理脚本

用法:
  $(basename "$0")                                   进入交互式管理主菜单
  $(basename "$0") <协议>                            直接进入该协议的互动安装向导
  $(basename "$0") <协议> -y [参数...]               使用默认或指定参数非交互一键安装
  $(basename "$0") <协议> --port <端口> [参数...]    带参数直接安装 (无需进菜单)
  $(basename "$0") <协议> --help                     查看该协议支持的全部命令行参数

管理子命令:
  $(basename "$0") list                              列出当前已安装的 Mihomo 入站节点
  $(basename "$0") info [<端口>] [-q]                查看指定端口节点的分享链接/客户端配置
  $(basename "$0") delete <端口> [-y]                删除指定端口的 Mihomo 入站节点
  $(basename "$0") address <IP|域名|auto>            设置 NAT/DDNS 连接地址 (auto 恢复自动获取)
  $(basename "$0") update                            更新 Mihomo 核心与 GeoIP/GeoSite
  $(basename "$0") restart                           重启 Mihomo 服务
  $(basename "$0") uninstall [-y]                    备份并卸载 Mihomo

支持的 <协议> 标识:
  主流协议:
    reality          VLESS-Reality (Vision, 默认 443)
    ss               Shadowsocks 2022 / AEAD (默认 2022)
    vless-enc        VLESS Encryption ML-KEM-768 抗量子 (默认 40000)
    anytls           AnyTLS JLS 握手伪装 / TLS (默认 8443, 需 >= 1.19.29)
    tuic             TUIC v5 UDP/QUIC (默认 443)
    hysteria2 | hy2  Hysteria2 UDP/QUIC (默认 443)
    trojan           Trojan TLS / WS (默认 443, 需 >= 1.19.3)
    vmess            VMess TCP / WS / TLS (默认 16823)

  进阶与混淆协议:
    shadowquic       ShadowQUIC UDP + JLS (默认 443, 需 >= 1.19.29)
    mieru            Mieru TCP / UDP (默认 2999, 需 >= 1.19.17)
    sudoku           Sudoku UUID 共享密钥 (默认 443, 需 >= 1.19.17)
    trusttunnel      TrustTunnel HTTP/2 + HTTP/3 (默认 443, 需 >= 1.19.25)

  基础代理与转发服务:
    http             带认证 HTTP 代理 (默认 8080)
    socks            带认证 SOCKS5 代理 (默认 1080)
    mixed            HTTP + SOCKS5 混合入站 (默认 10810)
    tunnel           Mihomo 内部 TCP/UDP 端口转发 (默认 10816, 需 --target)
    hy2-realm        Hysteria2 realm-opts 汇合服务器 (默认 2080, 需 >= 1.19.25)

通用安装参数:
  --port <端口>            监听端口 (不传则用协议默认端口)
  --listen-host <IP>       监听地址 (默认 0.0.0.0)
  --address <IP|域名|auto> 安装前先设置外部连接地址 (NAT/DDNS)
  -y, --yes                全默认参数直接安装，不进入互动问答
  -q, --quiet              安静模式：stdout 仅输出分享链接或客户端配置
  -h, --help               显示帮助

示例:
  sudo ./$(basename "$0")
  sudo ./$(basename "$0") reality
  sudo ./$(basename "$0") reality -y -q
  sudo ./$(basename "$0") reality --port 8443 --sni www.apple.com --address my.ddns.net
  sudo ./$(basename "$0") ss --method 2022-blake3-aes-256-gcm -q
  sudo ./$(basename "$0") hysteria2 --port 443 --obfs salamander
  sudo ./$(basename "$0") tunnel --port 10816 --target 10.0.0.2:443
EOF
}

normalize_proto_key() {
    case "${1,,}" in
        reality|vless-reality)            printf 'reality\n' ;;
        ss|ss2022|shadowsocks)            printf 'ss\n' ;;
        vless-enc|vless-encryption|vless-pq) printf 'vless-enc\n' ;;
        anytls)                           printf 'anytls\n' ;;
        tuic|tuic-v5|tuic5)               printf 'tuic\n' ;;
        hysteria2|hy2)                    printf 'hysteria2\n' ;;
        trojan)                           printf 'trojan\n' ;;
        vmess)                            printf 'vmess\n' ;;
        shadowquic)                       printf 'shadowquic\n' ;;
        mieru)                            printf 'mieru\n' ;;
        sudoku)                           printf 'sudoku\n' ;;
        trusttunnel)                      printf 'trusttunnel\n' ;;
        http)                             printf 'http\n' ;;
        socks|socks5)                     printf 'socks\n' ;;
        mixed)                            printf 'mixed\n' ;;
        tunnel)                           printf 'tunnel\n' ;;
        hy2-realm|hysteria2-realm)        printf 'hy2-realm\n' ;;
        *)                                return 1 ;;
    esac
}

proto_help() {
    local p
    p=$(normalize_proto_key "$1") || { error "未知协议: $1"; return 1; }
    case "$p" in
        reality)
            cat <<'EOF'
协议: reality (VLESS-Reality Vision)
默认端口: 443 | 传输: TCP
专属参数:
  --uuid <UUID>          用户 UUID (默认随机)
  --sni <域名>           伪装目标域名 (默认: hk.art.museum)
EOF
            ;;
        ss)
            cat <<'EOF'
协议: ss (Shadowsocks 2022 / AEAD)
默认端口: 2022 | 传输: TCP + UDP
专属参数:
  --method <加密方式>    默认 2022-blake3-aes-256-gcm
                         可选: 2022-blake3-aes-128-gcm, 2022-blake3-aes-256-gcm,
                               2022-blake3-chacha20-poly1305, aes-128-gcm,
                               aes-256-gcm, chacha20-ietf-poly1305
  --password <密码>      默认随机生成 (2022 系列须为对应长度密钥的 Base64)
EOF
            ;;
        vless-enc)
            cat <<'EOF'
协议: vless-enc (VLESS Encryption ML-KEM-768 抗量子)
默认端口: 40000 | 传输: TCP
专属参数:
  --uuid <UUID>          用户 UUID (默认随机)
EOF
            ;;
        anytls)
            cat <<'EOF'
协议: anytls (AnyTLS JLS / TLS, 需要 mihomo >= 1.19.29)
默认端口: 8443 | 传输: TCP
专属参数:
  --mode <jls|tls>          安全模式 (默认: jls)
  --dest <host:port>        JLS 回落目标 (默认: www.bing.com:443)
  --sni <域名>              JLS SNI (默认由 dest 推导) 或 TLS SNI
  --alpn <列表>             默认 h2,http/1.1
  --password <密码>         AnyTLS 密码 (默认随机)
  --jls-user <名称>         JLS 用户名 (默认随机)
  --jls-password <密码>     JLS 密码 (默认随机)
  --proxy <出站名>          回落流量出站 proxy (默认 DIRECT)
  --rate-limit <bit/s>      回落限速 (0 表示不限速)
  --padding-file <文件>     自定义 padding-scheme 文件
  --cert-mode <selfsign|file|acme> (tls 模式可用)
  --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
        tuic)
            cat <<'EOF'
协议: tuic (TUIC v5)
默认端口: 443 | 传输: UDP/QUIC
专属参数:
  --uuid <UUID>                   用户 UUID (默认随机)
  --password <密码>               8-128 位字母数字 (默认随机)
  --congestion <bbr|cubic|new_reno> 默认 bbr
  --alpn <列表>                   默认 h3
  --udp-relay-mode <native|quic>  客户端 UDP 中继模式 (默认 native)
  --sni <域名或IP>                默认 tuic.local
  --cert-mode <selfsign|file|acme> 默认 selfsign
  --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
        hysteria2)
            cat <<'EOF'
协议: hysteria2 (Hysteria2)
默认端口: 443 | 传输: UDP/QUIC
专属参数:
  --username <用户名>         仅用于入站规则标识 (默认 hy2user)
  --password <密码>           客户端认证密码 (默认随机)
  --obfs <salamander|none>    QUIC 混淆 (默认关闭)
  --obfs-password <密码>      salamander 混淆密码 (默认随机)
  --alpn <列表>               默认 h3
  --sni <域名或IP>            默认 hysteria2.local
  --cert-mode <selfsign|file|acme> 默认 selfsign
  --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
        trojan)
            cat <<'EOF'
协议: trojan (Trojan, 需要 mihomo >= 1.19.3)
默认端口: 443 | 传输: TCP
专属参数:
  --password <密码>           认证密码 (默认随机)
  --ws-path <路径>            WebSocket 路径 (留空为 TCP)
  --sni <域名或IP>            默认 trojan.local
  --cert-mode <selfsign|file|acme> 默认 selfsign
  --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
        vmess)
            cat <<'EOF'
协议: vmess (VMess, alterId=0)
默认端口: 16823 | 传输: TCP
专属参数:
  --uuid <UUID>               用户 UUID (默认随机)
  --security <none|tls>       默认 none
  --ws-path <路径>            WebSocket 路径 (留空为 TCP)
  --sni <域名或IP>            默认 vmess.local
  --cert-mode <selfsign|file|acme> (security=tls 时默认 selfsign)
  --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
        shadowquic)
            cat <<'EOF'
协议: shadowquic (ShadowQUIC, 需要 mihomo >= 1.19.29)
默认端口: 443 | 传输: UDP/QUIC
专属参数:
  --username <用户名>               默认随机
  --password <密码>                 默认随机
  --dest <host:port>                JLS 上游 (默认: www.bing.com:443)
  --sni <域名>                      默认由 dest 推导
  --alpn <列表>                     默认 h3
  --congestion <bbr|cubic|new_reno> 默认 bbr
  --zero-rtt <true|false>           默认 false
EOF
            ;;
        mieru)
            cat <<'EOF'
协议: mieru (Mieru, 需要 mihomo >= 1.19.17)
默认端口: 2999 | 传输: TCP 或 UDP
专属参数:
  --username <用户名>    默认随机
  --password <密码>      默认随机
  --transport <TCP|UDP>  默认 TCP
EOF
            ;;
        sudoku)
            cat <<'EOF'
协议: sudoku (Sudoku, 需要 mihomo >= 1.19.17)
默认端口: 443 | 传输: TCP
专属参数:
  --key <UUID>              共享密钥 UUID (默认随机)
  --aead <方法>             chacha20-poly1305 (默认) / aes-128-gcm / none
  --table <类型>            prefer_ascii (默认) / prefer_entropy / up_ascii_down_entropy / up_entropy_down_ascii
  --httpmask <legacy|off>   默认 legacy
  --padding-min <0-100>     默认 2
  --padding-max <0-100>     默认 7
EOF
            ;;
        trusttunnel)
            cat <<'EOF'
协议: trusttunnel (TrustTunnel, 需要 mihomo >= 1.19.25)
默认端口: 443 | 传输: TCP + UDP
专属参数:
  --username <用户名>               默认随机
  --password <密码>                 默认随机
  --congestion <bbr|cubic|new_reno> 默认 bbr
  --sni <域名或IP>                  默认 trusttunnel.local
  --cert-mode <selfsign|file|acme>  默认 selfsign
  --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
        http|socks|mixed)
            cat <<EOF
协议: ${p}
默认端口: $( [[ "$p" == "http" ]] && echo 8080 || ( [[ "$p" == "socks" ]] && echo 1080 || echo 10810 ) )
专属参数:
  --username <用户名>    认证用户名 (默认随机)
  --password <密码>      认证密码 (8-128 位字母数字，默认随机)
EOF
            ;;
        tunnel)
            cat <<'EOF'
协议: tunnel (Mihomo 端口转发，非代理节点)
默认端口: 10816 | 传输: 按 --network
专属参数:
  --target <host:port>   转发目标地址 (必填)
  --network <列表>       tcp / udp / tcp,udp (默认 tcp,udp)
EOF
            ;;
        hy2-realm)
            cat <<'EOF'
协议: hy2-realm (Hysteria2 realm-opts 汇合服务器，需要 mihomo >= 1.19.25)
默认端口: 2080 | 传输: TCP
专属参数:
  --token <令牌>              Bearer token (默认随机)
  --max-realms <数量>         默认 65536
  --max-realms-per-ip <数量>  默认 4
  --cert-mode <none|selfsign|file|acme> 默认 none
  --sni <域名或IP> / --cert <路径> / --key <路径> / --domain <域名>
EOF
            ;;
    esac
}

# --- 内嵌协议与 YAML 引擎 (Python) ---

proto_engine() {
    python3 - "$@" <<'PY'
import base64, binascii, json, os, re, stat, sys, tempfile, urllib.parse

# 17 种协议元数据: proto_key -> (prefix, state_id, default_port, min_ver, label, default_sni)
PROTOS = {
    "reality":     ("vless-reality-in-",   "vless_reality",    443,   "",        "VLESS-Reality",          "hk.art.museum"),
    "ss":          ("ss-in-",              "ss",               2022,  "",        "Shadowsocks",            "example.local"),
    "vless-enc":   ("vless-pq-in-",        "vless_encryption", 40000, "",        "VLESS Encryption (PQ)",  "example.local"),
    "anytls":      ("anytls-in-",          "anytls",           8443,  "1.19.29", "AnyTLS",                 "www.bing.com"),
    "tuic":        ("tuic-in-",            "tuic",             443,   "",        "TUIC v5",                "tuic.local"),
    "hysteria2":   ("hysteria2-in-",       "hysteria2",        443,   "",        "Hysteria2",              "hysteria2.local"),
    "trojan":      ("trojan-in-",          "trojan",           443,   "1.19.3",  "Trojan",                 "trojan.local"),
    "vmess":       ("vmess-in-",           "vmess",            16823, "",        "VMess",                  "vmess.local"),
    "shadowquic":  ("shadowquic-in-",      "shadowquic",       443,   "1.19.29", "ShadowQUIC",             "www.bing.com"),
    "mieru":       ("mieru-in-",           "mieru",            2999,  "1.19.17", "Mieru",                  "example.local"),
    "sudoku":      ("sudoku-in-",          "sudoku",           443,   "1.19.17", "Sudoku",                 "example.local"),
    "trusttunnel": ("trusttunnel-in-",     "trusttunnel",      443,   "1.19.25", "TrustTunnel",            "trusttunnel.local"),
    "http":        ("http-in-",            "http",             8080,  "",        "HTTP",                   "example.local"),
    "socks":       ("socks-in-",           "socks",            1080,  "",        "SOCKS5",                 "example.local"),
    "mixed":       ("mixed-in-",           "mixed",            10810, "",        "Mixed",                  "example.local"),
    "tunnel":      ("tunnel-in-",          "tunnel",           10816, "",        "Tunnel",                 "example.local"),
    "hy2-realm":   ("hysteria2-realm-in-", "hy2realm",         2080,  "1.19.25", "Hysteria2 Realm",        "realm.local"),
}

SS_KEY_LENS = {
    "2022-blake3-aes-128-gcm": 16,
    "2022-blake3-aes-256-gcm": 32,
    "2022-blake3-chacha20-poly1305": 32,
    "aes-128-gcm": 16,
    "aes-256-gcm": 32,
    "chacha20-ietf-poly1305": 32,
}

SUDOKU_TABLES = ("prefer_ascii", "prefer_entropy", "up_ascii_down_entropy", "up_entropy_down_ascii")
SUDOKU_AEADS = ("chacha20-poly1305", "aes-128-gcm", "none")

def q(v):
    return json.dumps(v, ensure_ascii=False)

def host_of(ip):
    return f"[{ip}]" if ":" in ip and not ip.startswith("[") else ip

def scalar(v):
    v = v.strip().split("#", 1)[0].strip()
    try:
        return str(json.loads(v))
    except Exception:
        return v.strip("\"'")

def user_ok(u):
    return isinstance(u, str) and 1 <= len(u) <= 64 and all(c.isalnum() or c in "._-" for c in u)

def pass_ok(p):
    return isinstance(p, str) and 8 <= len(p) <= 128 and p.isalnum()

def uuid_ok(u):
    return isinstance(u, str) and bool(re.fullmatch(r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}", u))

def ws_ok(path):
    path = (path or "").strip()
    return path == "" or (path.startswith("/") and " " not in path and len(path) <= 128)

def tls_check(st, required, default_cert_path=""):
    errs = []
    mode = st.get("cert_mode") or ("selfsign" if required else "none")
    if mode == "none":
        if required:
            errs.append("该协议必须配置 TLS 证书 (selfsign、file 或 acme)。")
        return errs
    if mode not in ("selfsign", "file", "acme"):
        errs.append("证书模式只能是 selfsign、file、acme 或 none。")
        return errs
    has_cert = bool(st.get("certificate")) or (bool(default_cert_path) and os.path.isfile(default_cert_path))
    if mode == "file" and not has_cert and (not st.get("cert_src") or not st.get("key_src")):
        errs.append("file 模式需要同时提供 --cert 和 --key。")
    if mode == "acme" and not has_cert and not st.get("domain"):
        errs.append("acme 模式需要提供 --domain。")
    return errs

def atomic_write(path, content):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".config.", dir=d, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        if os.path.exists(path):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        else:
            os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)

def list_listeners(cfg_path):
    if not os.path.isfile(cfg_path):
        return []
    # 按前缀长度降序匹配，避免 hysteria2-realm-in- 被 hysteria2-in- 抢先命中
    ordered = sorted(PROTOS.items(), key=lambda kv: len(kv[1][0]), reverse=True)
    in_l = False
    rows = []
    with open(cfg_path, encoding="utf-8") as f:
        for raw in f:
            if re.match(r"^[^\s#][^:]*:", raw):
                in_l = raw.split(":", 1)[0].strip() == "listeners"
                continue
            if not in_l:
                continue
            s = raw.strip()
            if s.startswith("- name:"):
                name = scalar(s.split(":", 1)[1])
                for pkey, meta in ordered:
                    prefix, _, _, _, label, _ = meta
                    if name.startswith(prefix) and name[len(prefix):].isdigit():
                        rows.append((int(name[len(prefix):]), pkey, label, name))
                        break
    return rows

def validate_proto(pkey, st):
    errs = []
    port = int(st.get("port") or 0)
    if not (1 <= port <= 65535):
        errs.append("端口必须在 1-65535 之间。")

    if pkey == "reality":
        if not uuid_ok(st.get("uuid", "")):
            errs.append("UUID 格式无效。")
        if not (st.get("sni") or "").strip():
            errs.append("SNI 域名不能为空。")
    elif pkey == "ss":
        m, pw = st.get("method") or "", st.get("password") or ""
        if m not in SS_KEY_LENS:
            errs.append(f"不支持的加密方式: {m}")
        elif not pw:
            errs.append("密码不能为空。")
        elif m.startswith("2022-"):
            want = SS_KEY_LENS[m]
            try:
                raw = base64.b64decode(pw, validate=True)
                if len(raw) != want:
                    errs.append(f"{m} 密码解码后须为 {want} 字节密钥 (可用 openssl rand -base64 {want} 生成)。")
            except (binascii.Error, ValueError):
                errs.append(f"{m} 密码必须是合法的 Base64 编码。")
    elif pkey == "vless-enc":
        if not uuid_ok(st.get("uuid", "")):
            errs.append("UUID 格式无效。")
    elif pkey == "anytls":
        mode = st.get("mode") or "jls"
        if mode not in ("jls", "tls"):
            errs.append("mode 只能是 jls 或 tls。")
        if not (st.get("password") or ""):
            errs.append("AnyTLS 密码不能为空。")
        if mode == "jls":
            if ":" not in (st.get("dest") or "").strip():
                errs.append("JLS dest 必须是 host:port。")
            if not (st.get("jls_user") or "") or not (st.get("jls_password") or ""):
                errs.append("JLS 用户名与密码不能为空。")
        else:
            errs.extend(tls_check(st, required=True))
        for item in [x.strip() for x in str(st.get("alpn") or "").split(",") if x.strip()]:
            if not re.fullmatch(r"[A-Za-z0-9/._-]+", item):
                errs.append(f"ALPN 取值非法: {item}")
    elif pkey == "tuic":
        if not uuid_ok(st.get("uuid", "")):
            errs.append("UUID 格式无效。")
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
        if (st.get("congestion") or "bbr") not in ("bbr", "cubic", "new_reno"):
            errs.append("拥塞控制只能是 bbr、cubic 或 new_reno。")
        if (st.get("udp_relay_mode") or "native") not in ("native", "quic"):
            errs.append("udp-relay-mode 只能是 native 或 quic。")
        if not str(st.get("alpn") or "").strip():
            errs.append("ALPN 不能为空。")
        errs.extend(tls_check(st, required=True, default_cert_path=f"/usr/local/etc/mihomo/certs/tuic-in-{port}.crt"))
    elif pkey == "hysteria2":
        if not user_ok(st.get("username", "")):
            errs.append("用户名无效。")
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
        obfs = (st.get("obfs") or "").strip()
        if obfs and obfs != "salamander":
            errs.append("obfs 只支持 salamander，留空表示关闭。")
        if obfs and not pass_ok(st.get("obfs_password", "")):
            errs.append("开启 salamander 时需要 8-128 位字母数字密码。")
        if not str(st.get("alpn") or "").strip():
            errs.append("ALPN 不能为空。")
        errs.extend(tls_check(st, required=True))
    elif pkey == "trojan":
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
        if not ws_ok(st.get("ws_path")):
            errs.append("ws-path 必须以 / 开头且不含空格。")
        errs.extend(tls_check(st, required=True))
    elif pkey == "vmess":
        if not uuid_ok(st.get("uuid", "")):
            errs.append("UUID 格式无效。")
        sec = st.get("security") or "none"
        if sec not in ("none", "tls"):
            errs.append("security 只能是 none 或 tls。")
        if not ws_ok(st.get("ws_path")):
            errs.append("ws-path 必须以 / 开头且不含空格。")
        if sec == "tls":
            errs.extend(tls_check(st, required=True))
        elif (st.get("cert_mode") or "none") != "none":
            errs.append("security=none 时不应配置证书。")
    elif pkey == "shadowquic":
        if not user_ok(st.get("username", "")):
            errs.append("用户名无效。")
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
        if ":" not in (st.get("dest") or "").strip():
            errs.append("JLS 上游必须是 host:port。")
        if (st.get("congestion") or "bbr") not in ("bbr", "cubic", "new_reno"):
            errs.append("拥塞控制只能是 bbr、cubic 或 new_reno。")
        if not str(st.get("alpn") or "").strip():
            errs.append("ALPN 不能为空。")
    elif pkey == "mieru":
        if not user_ok(st.get("username", "")):
            errs.append("用户名无效。")
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
        if (st.get("transport") or "") not in ("TCP", "UDP"):
            errs.append("transport 只能是 TCP 或 UDP。")
    elif pkey == "sudoku":
        if not uuid_ok(st.get("key", "")):
            errs.append("key 必须是 UUID。")
        if st.get("aead") not in SUDOKU_AEADS:
            errs.append("aead 只能是 chacha20-poly1305、aes-128-gcm 或 none。")
        try:
            lo, hi = int(st.get("padding_min")), int(st.get("padding_max"))
            if not (0 <= lo <= 100 and 0 <= hi <= 100 and hi >= lo):
                errs.append("padding-min/max 必须在 0-100 且 max >= min。")
        except (TypeError, ValueError):
            errs.append("padding 必须是整数。")
        if st.get("table") not in SUDOKU_TABLES:
            errs.append("table-type 无效。")
        if st.get("httpmask") not in ("legacy", "off"):
            errs.append("httpmask 只能是 legacy 或 off。")
    elif pkey == "trusttunnel":
        if not user_ok(st.get("username", "")):
            errs.append("用户名无效。")
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
        if (st.get("congestion") or "bbr") not in ("bbr", "cubic", "new_reno"):
            errs.append("拥塞控制只能是 bbr、cubic 或 new_reno。")
        errs.extend(tls_check(st, required=True))
    elif pkey in ("http", "socks", "mixed"):
        if not user_ok(st.get("username", "")):
            errs.append("用户名只能是字母、数字、点、下划线或连字符。")
        if not pass_ok(st.get("password", "")):
            errs.append("密码须为 8-128 位字母或数字。")
    elif pkey == "tunnel":
        if ":" not in (st.get("target") or "").strip():
            errs.append("target 必须是 host:port。")
        nets = [x.strip() for x in str(st.get("network") or "").split(",") if x.strip()]
        if not nets or any(x not in ("tcp", "udp") for x in nets):
            errs.append("network 只能是 tcp、udp 或 tcp,udp。")
    elif pkey == "hy2-realm":
        tok = st.get("token") or ""
        if not (isinstance(tok, str) and 8 <= len(tok) <= 128 and tok.replace("-", "").replace("_", "").isalnum()):
            errs.append("token 须为 8-128 位字母、数字、下划线或连字符。")
        try:
            if int(st.get("max_realms")) < 0 or int(st.get("max_per_ip")) < 0:
                errs.append("数量上限不能为负数。")
        except (TypeError, ValueError):
            errs.append("max-realms / max-realms-per-ip 必须是整数。")
        errs.extend(tls_check(st, required=False))
    return errs

def kind_of(pkey, st):
    if pkey in ("ss", "socks", "mixed", "trusttunnel"):
        return "both"
    if pkey in ("tuic", "hysteria2", "shadowquic"):
        return "udp"
    if pkey == "mieru":
        return "udp" if st.get("transport") == "UDP" else "tcp"
    if pkey == "tunnel":
        nets = [x.strip() for x in str(st.get("network") or "").split(",") if x.strip()]
        return "both" if ("tcp" in nets and "udp" in nets) else (nets[0] if nets else "tcp")
    return "tcp"

def build_block(pkey, st):
    prefix = PROTOS[pkey][0]
    port = int(st["port"])
    listen = st.get("listen") or "0.0.0.0"
    head = lambda ltype: [
        f"  - name: {q(prefix + str(port))}",
        f"    type: {q(ltype)}",
        f"    port: {port}",
        f"    listen: {q(listen)}",
    ]
    alpn_list = lambda s: ["    alpn:"] + [f"      - {q(x.strip())}" for x in str(s or "").split(",") if x.strip()]
    certs = lambda: [f"    certificate: {q(st['certificate'])}", f"    private-key: {q(st['private_key'])}"] if st.get("certificate") else []

    if pkey == "reality":
        sni = st["sni"]
        sid = st.get("shortid") or "20220701"
        return head("vless") + [
            "    users:", f"      - uuid: {q(st['uuid'])}", "        flow: xtls-rprx-vision",
            "    reality-config:", f"      dest: {q(sni + ':443')}", f"      private-key: {q(st['private_key'])}",
            "      server-names:", f"        - {q(sni)}", "      short-id:", f"        - {q(sid)}",
        ]
    if pkey == "ss":
        return head("shadowsocks") + [f"    cipher: {q(st['method'])}", f"    password: {q(st['password'])}", "    udp: true"]
    if pkey == "vless-enc":
        return head("vless") + ["    users:", f"      - uuid: {q(st['uuid'])}", f"    decryption: {q(st['decryption'])}"]
    if pkey == "anytls":
        lines = head("anytls") + ["    users:", f"      {q('anytls')}: {q(st['password'])}"]
        if (st.get("mode") or "jls") == "jls":
            dest = st["dest"].strip()
            sni = (st.get("sni") or "").strip() or dest.rsplit(":", 1)[0].strip("[]")
            lines += [
                "    jls-config:", "      enable: true", "      users:",
                f"        - username: {q(st['jls_user'])}", f"          password: {q(st['jls_password'])}",
                f"      dest: {q(dest)}", f"      sni: {q(sni)}",
            ]
            items = [x.strip() for x in str(st.get("alpn") or "h2,http/1.1").split(",") if x.strip()]
            if items:
                lines.append("      alpn:")
                lines.extend(f"        - {q(x)}" for x in items)
            if st.get("proxy"):
                lines.append(f"      proxy: {q(st['proxy'])}")
            if int(st.get("rate_limit") or 0) > 0:
                lines.append(f"      rate-limit: {int(st['rate_limit'])}")
        else:
            lines += certs()
        pad = (st.get("padding_scheme") or "").rstrip("\n")
        if pad:
            lines.append("    padding-scheme: |")
            lines.extend("      " + p for p in pad.split("\n"))
        return lines
    if pkey == "tuic":
        crt = st.get("certificate") or f"/usr/local/etc/mihomo/certs/{prefix}{port}.crt"
        key = st.get("private_key") or f"/usr/local/etc/mihomo/certs/{prefix}{port}.key"
        return head("tuic") + [
            "    users:", f"      {q(st['uuid'])}: {q(st['password'])}",
            f"    certificate: {q(crt)}", f"    private-key: {q(key)}",
            f"    congestion-controller: {q(st.get('congestion') or 'bbr')}",
        ] + alpn_list(st.get("alpn") or "h3")
    if pkey == "hysteria2":
        lines = head("hysteria2") + ["    users:", f"      {q(st['username'])}: {q(st['password'])}"] + alpn_list(st.get("alpn") or "h3") + certs()
        obfs = (st.get("obfs") or "").strip()
        if obfs:
            lines += [f"    obfs: {q(obfs)}", f"    obfs-password: {q(st['obfs_password'])}"]
        return lines
    if pkey == "trojan":
        lines = head("trojan") + ["    users:", f"      - username: {q('trojan')}", f"        password: {q(st['password'])}"]
        if (st.get("ws_path") or "").strip():
            lines.append(f"    ws-path: {q(st['ws_path'].strip())}")
        return lines + certs()
    if pkey == "vmess":
        lines = head("vmess") + ["    users:", f"      - username: {q('vmess')}", f"        uuid: {q(st['uuid'])}", "        alterId: 0"]
        if (st.get("ws_path") or "").strip():
            lines.append(f"    ws-path: {q(st['ws_path'].strip())}")
        if (st.get("security") or "none") == "tls":
            lines += certs()
        return lines
    if pkey == "shadowquic":
        dest = st["dest"].strip()
        sni = (st.get("sni") or "").strip() or dest.rsplit(":", 1)[0].strip("[]")
        return head("shadowquic") + [
            "    users:", f"      - username: {q(st['username'])}", f"        password: {q(st['password'])}",
            "    jls-upstream:", f"      addr: {q(dest)}", f"      sni: {q(sni)}",
        ] + alpn_list(st.get("alpn") or "h3") + [
            f"    congestion-controller: {q(st.get('congestion') or 'bbr')}",
            "    zero-rtt: " + ("true" if st.get("zero_rtt") else "false"),
        ]
    if pkey == "mieru":
        return head("mieru") + [f"    transport: {q(st['transport'])}", "    users:", f"      {q(st['username'])}: {q(st['password'])}"]
    if pkey == "sudoku":
        mask = st.get("httpmask") or "legacy"
        lines = head("sudoku") + [
            f"    key: {q(st['key'])}", f"    aead-method: {q(st['aead'])}",
            f"    padding-min: {int(st['padding_min'])}", f"    padding-max: {int(st['padding_max'])}",
            f"    table-type: {q(st['table'])}", "    handshake-timeout: 5", "    enable-pure-downlink: false",
            "    httpmask:", "      disable: " + ("true" if mask == "off" else "false"),
        ]
        if mask != "off":
            lines.append(f"      mode: {q('legacy')}")
        return lines
    if pkey == "trusttunnel":
        return head("trusttunnel") + [
            "    users:", f"      - username: {q(st['username'])}", f"        password: {q(st['password'])}",
        ] + certs() + ['    network: ["tcp", "udp"]', f"    congestion-controller: {q(st.get('congestion') or 'bbr')}"]
    if pkey in ("http", "socks", "mixed"):
        lines = head(pkey)
        if pkey != "http":
            lines.append("    udp: true")
        return lines + ["    users:", f"      - username: {q(st['username'])}", f"        password: {q(st['password'])}"]
    if pkey == "tunnel":
        nets = [x.strip() for x in str(st.get("network") or "").split(",") if x.strip()]
        return head("tunnel") + ["    network: [" + ", ".join(q(x) for x in nets) + "]", f"    target: {q(st['target'].strip())}"]
    if pkey == "hy2-realm":
        lines = head("hysteria2-realm") + [
            f"    token: {q(st['token'])}", f"    max-realms: {int(st['max_realms'])}",
            f"    max-realms-per-ip: {int(st['max_per_ip'])}",
            f"    realm-name-pattern: {q(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')}",
        ]
        if (st.get("cert_mode") or "none") != "none" and st.get("certificate"):
            lines += certs() + ["    alpn:", '      - "h2"', '      - "http/1.1"']
        return lines
    raise ValueError(pkey)

def render_client(pkey, st, ip, name, quiet=False):
    port = int(st["port"])
    h = host_of(ip)
    uq = lambda v: urllib.parse.quote(str(v), safe="")
    yproxy = lambda pname, rows: "\n".join(["proxies:", f"  - name: {q(pname)}"] + rows)

    if pkey == "reality":
        sid = st.get("shortid") or "20220701"
        uri = (
            f"vless://{st['uuid']}@{h}:{port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality"
            f"&sni={uq(st['sni'])}&fp=chrome&pbk={uq(st['public_key'])}&sid={uq(sid)}&spx=%2F#{uq(name)}"
        )
        if quiet:
            return uri
        yaml = yproxy(name, [
            "    type: vless", f"    server: {q(ip)}", f"    port: {port}", f"    uuid: {q(st['uuid'])}",
            "    network: tcp", "    tls: true", "    udp: true", "    flow: xtls-rprx-vision",
            f"    servername: {q(st['sni'])}", "    client-fingerprint: chrome",
            "    reality-opts:", f"      public-key: {q(st['public_key'])}", f"      short-id: {q(sid)}",
        ])
        return f"# Share\n{uri}\n\n# Mihomo\n{yaml}"

    if pkey == "ss":
        b64 = base64.urlsafe_b64encode(f"{st['method']}:{st['password']}".encode()).decode().rstrip("=")
        uri = f"ss://{b64}@{h}:{port}#{uq(name)}"
        if quiet:
            return uri
        yaml = yproxy(name, [
            "    type: ss", f"    server: {q(ip)}", f"    port: {port}",
            f"    cipher: {q(st['method'])}", f"    password: {q(st['password'])}", "    udp: true",
        ])
        return f"# Share\n{uri}\n\n# Mihomo\n{yaml}"

    if pkey == "vless-enc":
        uri = f"vless://{st['uuid']}@{h}:{port}?encryption={uq(st['encryption'])}&type=tcp&security=none#{uq(name)}"
        if quiet:
            return uri
        yaml = yproxy(name, [
            "    type: vless", f"    server: {q(ip)}", f"    port: {port}", f"    uuid: {q(st['uuid'])}",
            "    network: tcp", "    udp: true", f"    encryption: {q(st['encryption'])}",
        ])
        return f"# Share\n{uri}\n\n# Mihomo\n{yaml}"

    if pkey == "anytls":
        mode = st.get("mode") or "jls"
        dest = (st.get("dest") or "").strip()
        sni = (st.get("sni") or "").strip() or (dest.rsplit(":", 1)[0].strip("[]") if mode == "jls" and dest else "")
        items = [x.strip() for x in str(st.get("alpn") or "h2,http/1.1").split(",") if x.strip()]
        rows = [
            "    type: anytls", f"    server: {q(ip)}", f"    port: {port}",
            f"    password: {q(st['password'])}", "    client-fingerprint: chrome", "    udp: true",
        ]
        if sni:
            rows.append(f"    sni: {q(sni)}")
        if items:
            rows.append("    alpn: [" + ", ".join(q(x) for x in items) + "]")
        if mode == "jls":
            rows += ["    jls-opts:", f"      username: {q(st['jls_user'])}", f"      password: {q(st['jls_password'])}"]
        elif st.get("skip_cert_verify"):
            rows.append("    skip-cert-verify: true")
        yaml = yproxy(f"AnyTLS-{mode.upper()}-{port}", rows)
        if quiet or mode == "jls":
            return yaml if quiet else f"# Mihomo (JLS 唯一可用导入方式)\n{yaml}"
        qp = {"sni": sni}
        if st.get("skip_cert_verify"):
            qp["insecure"] = "1"
        uri = f"anytls://{uq(st['password'])}@{h}:{port}?{urllib.parse.urlencode(qp)}#{uq(name)}"
        return f"# Share\n{uri}\n\n# Mihomo\n{yaml}"

    if pkey == "tuic":
        cc = st.get("congestion") or "bbr"
        um = st.get("udp_relay_mode") or "native"
        alpn = st.get("alpn") or "h3"
        items = [x.strip() for x in alpn.split(",") if x.strip()]
        sni = st.get("sni") or "tuic.local"
        skip = bool(st.get("skip_cert_verify"))
        safe = re.sub(r"\s+", " ", name.replace(",", " ").replace("=", " ")).strip() or f"tuic-v5-{port}"
        sp = [f"{safe} = tuic-v5", ip, str(port), f"uuid={st['uuid']}", f"password={st['password']}", f"sni={sni}", f"alpn={items[0] if items else 'h3'}"]
        if skip:
            sp.append("skip-cert-verify=true")
        surge = ", ".join(sp)
        qp = {"congestion_control": cc, "udp_relay_mode": um, "alpn": alpn, "sni": sni}
        if skip:
            qp["allow_insecure"] = "1"
        uri = f"tuic://{uq(st['uuid'])}:{uq(st['password'])}@{h}:{port}?{urllib.parse.urlencode(qp)}#{uq(safe)}"
        rows = [
            "    type: tuic", f"    server: {q(ip)}", f"    port: {port}",
            f"    uuid: {q(st['uuid'])}", f"    password: {q(st['password'])}",
            f"    congestion-controller: {q(cc)}", f"    udp-relay-mode: {q(um)}", "    alpn:",
        ] + [f"      - {q(x)}" for x in items] + [
            f"    sni: {q(sni)}", "    skip-cert-verify: " + ("true" if skip else "false"), "    udp: true",
        ]
        yaml = yproxy(safe, rows)
        return f"{surge}\n\n{uri}\n\n{yaml}" if quiet else f"# Surge\n{surge}\n\n# Share\n{uri}\n\n# Mihomo\n{yaml}"

    if pkey == "hysteria2":
        sni = st.get("sni") or ""
        skip = bool(st.get("skip_cert_verify"))
        items = [x.strip() for x in str(st.get("alpn") or "h3").split(",") if x.strip()]
        alpn = ",".join(items)
        qp = {"sni": sni, "alpn": alpn}
        if skip:
            qp["insecure"] = "1"
        obfs = (st.get("obfs") or "").strip()
        if obfs:
            qp["obfs"] = obfs
            qp["obfs-password"] = st.get("obfs_password") or ""
        uri = f"hysteria2://{uq(st['password'])}@{h}:{port}/?{urllib.parse.urlencode(qp)}#{uq(name)}"
        rows = [
            "    type: hysteria2", f"    server: {q(ip)}", f"    port: {port}",
            f"    password: {q(st['password'])}", f"    sni: {q(sni)}",
            "    skip-cert-verify: " + ("true" if skip else "false"), "    alpn:",
        ] + [f"      - {q(x)}" for x in items]
        if obfs:
            rows += [f"    obfs: {q(obfs)}", f"    obfs-password: {q(st.get('obfs_password') or '')}"]
        return f"# Share\n{uri}\n\n# Mihomo\n{yproxy(name, rows)}"

    if pkey == "trojan":
        ws = (st.get("ws_path") or "").strip()
        sni = st.get("sni") or ""
        skip = bool(st.get("skip_cert_verify"))
        qp = {"security": "tls", "sni": sni, "type": "ws" if ws else "tcp"}
        if skip:
            qp["allowInsecure"] = "1"
        if ws:
            qp["path"] = ws
        uri = f"trojan://{uq(st['password'])}@{h}:{port}?{urllib.parse.urlencode(qp)}#{uq(name)}"
        rows = [
            "    type: trojan", f"    server: {q(ip)}", f"    port: {port}",
            f"    password: {q(st['password'])}", f"    sni: {q(sni)}",
            "    skip-cert-verify: " + ("true" if skip else "false"), "    udp: true",
            f"    network: {q('ws' if ws else 'tcp')}",
        ]
        if ws:
            rows += ["    ws-opts:", f"      path: {q(ws)}"]
        return f"# Share\n{uri}\n\n# Mihomo\n{yproxy(name, rows)}"

    if pkey == "vmess":
        sec = st.get("security") or "none"
        ws = (st.get("ws_path") or "").strip()
        sni = st.get("sni") or ""
        skip = bool(st.get("skip_cert_verify"))
        payload = {
            "v": "2", "ps": name, "add": ip, "port": str(port), "id": st["uuid"], "aid": "0", "scy": "auto",
            "net": "ws" if ws else "tcp", "type": "none", "host": sni if sec == "tls" else "", "path": ws,
            "tls": "tls" if sec == "tls" else "", "sni": sni if sec == "tls" else "", "alpn": "",
            "fp": "chrome" if sec == "tls" else "",
        }
        if sec == "tls" and skip:
            payload["allowInsecure"] = "1"
        uri = "vmess://" + base64.b64encode(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()).decode()
        rows = [
            "    type: vmess", f"    server: {q(ip)}", f"    port: {port}", f"    uuid: {q(st['uuid'])}",
            "    alterId: 0", '    cipher: "auto"', "    udp: true",
            "    tls: " + ("true" if sec == "tls" else "false"), f"    network: {q('ws' if ws else 'tcp')}",
        ]
        if sec == "tls":
            rows.append("    skip-cert-verify: " + ("true" if skip else "false"))
            if sni:
                rows.append(f"    servername: {q(sni)}")
        if ws:
            rows += ["    ws-opts:", f"      path: {q(ws)}"]
        return f"# Share\n{uri}\n\n# Mihomo\n{yproxy(name, rows)}"

    if pkey == "shadowquic":
        dest = (st.get("dest") or "").strip()
        sni = (st.get("sni") or "").strip() or dest.rsplit(":", 1)[0].strip("[]")
        items = [x.strip() for x in str(st.get("alpn") or "h3").split(",") if x.strip()]
        rows = [
            "    type: shadowquic", f"    server: {q(ip)}", f"    port: {port}",
            f"    username: {q(st['username'])}", f"    password: {q(st['password'])}", f"    sni: {q(sni)}",
            f"    congestion-controller: {q(st.get('congestion') or 'bbr')}",
            "    zero-rtt: " + ("true" if st.get("zero_rtt") else "false"), "    alpn:",
        ] + [f"      - {q(x)}" for x in items]
        return f"# Mihomo\n{yproxy(name, rows)}\n\n# JLS 上游\n{dest}\nSNI: {sni}"

    if pkey == "mieru":
        rows = [
            "    type: mieru", f"    server: {q(ip)}", f"    port: {port}",
            f"    transport: {q(st['transport'])}", "    udp: true",
            f"    username: {q(st['username'])}", f"    password: {q(st['password'])}",
        ]
        return f"# Mihomo\n{yproxy(name, rows)}"

    if pkey == "sudoku":
        mask = st.get("httpmask") or "legacy"
        rows = [
            "    type: sudoku", f"    server: {q(ip)}", f"    port: {port}",
            f"    key: {q(st['key'])}", f"    aead-method: {q(st['aead'])}",
            f"    padding-min: {int(st['padding_min'])}", f"    padding-max: {int(st['padding_max'])}",
            f"    table-type: {q(st['table'])}", "    enable-pure-downlink: false",
            "    httpmask:", "      disable: " + ("true" if mask == "off" else "false"),
        ]
        if mask != "off":
            rows.append('      mode: "legacy"')
        return f"# Mihomo\n{yproxy(name, rows)}"

    if pkey == "trusttunnel":
        skip = bool(st.get("skip_cert_verify"))
        rows = [
            "    type: trusttunnel", f"    server: {q(ip)}", f"    port: {port}",
            f"    username: {q(st['username'])}", f"    password: {q(st['password'])}",
            f"    sni: {q(st.get('sni') or '')}", "    skip-cert-verify: " + ("true" if skip else "false"),
            "    udp: true", "    quic: true",
            f"    congestion-controller: {q(st.get('congestion') or 'bbr')}", '    client-fingerprint: "chrome"',
        ]
        return f"# Mihomo\n{yproxy(name, rows)}"

    if pkey in ("http", "socks", "mixed"):
        u, p = st["username"], st["password"]
        if pkey == "mixed":
            share = f"http://{uq(u)}:{uq(p)}@{h}:{port}\nsocks5://{uq(u)}:{uq(p)}@{h}:{port}"
            yaml = "\n".join([
                "proxies:",
                f"  - name: {q(name + '-http')}", '    type: "http"', f"    server: {q(ip)}", f"    port: {port}", f"    username: {q(u)}", f"    password: {q(p)}",
                f"  - name: {q(name + '-socks')}", '    type: "socks5"', f"    server: {q(ip)}", f"    port: {port}", f"    username: {q(u)}", f"    password: {q(p)}", "    udp: true",
            ])
            return f"# Share\n{share}\n\n# Mihomo\n{yaml}"
        scheme = "http" if pkey == "http" else "socks5"
        uri = f"{scheme}://{uq(u)}:{uq(p)}@{h}:{port}"
        rows = [f"    type: {q(scheme)}", f"    server: {q(ip)}", f"    port: {port}", f"    username: {q(u)}", f"    password: {q(p)}"]
        if pkey == "socks":
            rows.append("    udp: true")
        return f"# Share\n{uri}\n\n# Mihomo\n{yproxy(name, rows)}"

    if pkey == "tunnel":
        nets = ",".join(x.strip() for x in str(st.get("network") or "").split(",") if x.strip())
        return "\n".join([
            "# 端口转发，不是代理节点，没有分享链接",
            f"listen: {st.get('listen') or '0.0.0.0'}:{port}",
            f"network: {nets}",
            f"target: {st['target'].strip()}",
            "",
            f"外部连到 {ip}:{port} 的流量会被原样转到 {st['target'].strip()}。",
        ])

    if pkey == "hy2-realm":
        scheme = "https" if (st.get("cert_mode") or "none") != "none" else "http"
        url = f"{scheme}://{h}:{port}"
        return "\n".join([
            "# Hysteria2 realm-opts 汇合服务器配置",
            f"server-url: {url}",
            f"token: {st['token']}",
            "",
            "realm-opts:",
            "  enable: true",
            f"  server-url: {q(url)}",
            f"  token: {q(st['token'])}",
        ])
    raise ValueError(pkey)

def summary_of(pkey, st):
    if pkey == "reality":
        return f"UUID: {st['uuid']}\nSNI: {st['sni']}\n公钥: {st['public_key']}"
    if pkey == "ss":
        return f"加密: {st['method']}\n密码: {st['password']}"
    if pkey == "vless-enc":
        return f"UUID: {st['uuid']}\n加密串: {(st.get('encryption') or '')[:40]}..."
    if pkey == "anytls":
        m = st.get("mode") or "jls"
        base = f"模式: {m}\n密码: {st['password']}"
        return base + (f"\nJLS 用户: {st['jls_user']}\nJLS 密码: {st['jls_password']}\nJLS dest: {st['dest']}" if m == "jls" else f"\nSNI: {st.get('sni','')}")
    if pkey == "tuic":
        return f"UUID: {st['uuid']}\n密码: {st['password']}\n拥塞控制: {st.get('congestion','bbr')}\nSNI: {st.get('sni','')}"
    if pkey == "hysteria2":
        return f"密码: {st['password']}\n混淆: {st.get('obfs') or '关闭'}\nSNI: {st.get('sni','')}"
    if pkey == "trojan":
        return f"密码: {st['password']}\nSNI: {st.get('sni','')}\n传输: {st.get('ws_path') or 'tcp'}"
    if pkey == "vmess":
        return f"UUID: {st['uuid']}\n传输: {st.get('ws_path') or 'tcp'}\n安全: {st.get('security') or 'none'}"
    if pkey == "shadowquic":
        return f"用户名: {st['username']}\n密码: {st['password']}\nJLS 上游: {st['dest']}"
    if pkey == "mieru":
        return f"用户名: {st['username']}\n密码: {st['password']}\n传输: {st['transport']}"
    if pkey == "sudoku":
        return f"Key: {st['key']}\nAEAD: {st['aead']}\nHTTPMask: {st['httpmask']}"
    if pkey == "trusttunnel":
        return f"用户名: {st['username']}\n密码: {st['password']}\n拥塞控制: {st.get('congestion','bbr')}\nSNI: {st.get('sni','')}"
    if pkey in ("http", "socks", "mixed"):
        return f"用户名: {st['username']}\n密码: {st['password']}"
    if pkey == "tunnel":
        return f"转发目标: {st['target']}\n转发协议: {st['network']}"
    if pkey == "hy2-realm":
        return f"Token: {st['token']}\n证书: {st.get('cert_mode') or 'none'}"
    return ""

def notes_of(pkey, st):
    k = kind_of(pkey, st)
    fw = {"tcp": "TCP", "udp": "UDP", "both": "TCP 和 UDP"}[k]
    extra = ""
    if st.get("skip_cert_verify"):
        extra = " 当前使用自签证书，客户端需允许跳过证书校验。"
    return f"防火墙请放行 {fw} 端口 {int(st['port'])}。{extra}"

def recover_legacy(pkey, port_s, cfg_path, out_path):
    if not os.path.isfile(cfg_path):
        raise SystemExit(1)
    prefix = PROTOS[pkey][0]
    target = prefix + str(port_s)
    in_l = in_item = in_sn = in_sid = False
    listen = "0.0.0.0"
    uuid = domain = priv = method = pw = dec = ""
    sid = "20220701"
    with open(cfg_path, encoding="utf-8") as f:
        for raw in f:
            if re.match(r"^[^\s#][^:]*:", raw):
                in_l = raw.split(":", 1)[0].strip() == "listeners"
                in_item = False
                continue
            if not in_l:
                continue
            s = raw.strip()
            if s.startswith("- name:"):
                in_item = (scalar(s.split(":", 1)[1]) == target)
                in_sn = in_sid = False
                continue
            if not in_item:
                continue
            if s.startswith("listen:"):
                listen = scalar(s.split(":", 1)[1])
            elif s.startswith("- uuid:"):
                uuid = scalar(s.split(":", 1)[1])
            elif s.startswith("private-key:"):
                priv = scalar(s.split(":", 1)[1])
            elif s.startswith("cipher:"):
                method = scalar(s.split(":", 1)[1])
            elif s.startswith("password:"):
                pw = scalar(s.split(":", 1)[1])
            elif s.startswith("decryption:"):
                dec = scalar(s.split(":", 1)[1])
            elif s.startswith("server-names:"):
                in_sn, in_sid = True, False
            elif s.startswith("short-id:"):
                in_sid, in_sn = True, False
            elif in_sn and s.startswith("- "):
                domain, in_sn = scalar(s[2:]), False
            elif in_sid and s.startswith("- "):
                sid, in_sid = scalar(s[2:]), False

    if pkey == "reality":
        pub_path = f"/root/mihomo_reality_pubkey_{port_s}.txt"
        if not (uuid and domain and priv and os.path.isfile(pub_path)):
            raise SystemExit(1)
        pub = open(pub_path, encoding="utf-8").read().strip()
        if not pub:
            raise SystemExit(1)
        save_json(out_path, {"port": int(port_s), "listen": listen, "uuid": uuid, "sni": domain, "shortid": sid, "private_key": priv, "public_key": pub})
    elif pkey == "ss":
        if not (method and pw):
            raise SystemExit(1)
        save_json(out_path, {"port": int(port_s), "listen": listen, "method": method, "password": pw})
    elif pkey == "vless-enc":
        key_path = f"/root/mihomo_vless_encryption_client_key_{port_s}.txt"
        if not (uuid and dec and os.path.isfile(key_path)):
            raise SystemExit(1)
        enc = open(key_path, encoding="utf-8").read().strip()
        if not enc:
            raise SystemExit(1)
        save_json(out_path, {"port": int(port_s), "listen": listen, "uuid": uuid, "decryption": dec, "encryption": enc})
    else:
        raise SystemExit(1)

def append_yaml(cfg_path, blk_path):
    block = open(blk_path, encoding="utf-8").read().rstrip("\n")
    content = open(cfg_path, encoding="utf-8").read()
    if re.search(r"^listeners:\s*\[\]\s*(?:#.*)?$", content, re.MULTILINE):
        content = re.sub(r"^listeners:\s*\[\]\s*(?:#.*)?$", "listeners:\n" + block, content, count=1, flags=re.MULTILINE)
    elif re.search(r"^listeners:", content, re.MULTILINE):
        lines = content.split("\n")
        in_l, l_line, last_item, next_sec = False, -1, -1, -1
        for i, line in enumerate(lines):
            if re.match(r"^listeners:\s*(?:#.*)?$", line):
                in_l, l_line = True, i
                continue
            if in_l:
                if line and not line[0].isspace() and not line.startswith("#") and ":" in line:
                    next_sec = i
                    break
                if line.strip() and not line.lstrip().startswith("#"):
                    last_item = i
        insert_at = (last_item + 1) if last_item >= 0 else ((l_line + 1) if l_line >= 0 else (next_sec if next_sec >= 0 else len(lines)))
        lines.insert(insert_at, block)
        content = "\n".join(lines)
    else:
        content = content.rstrip("\n") + "\n\nlisteners:\n" + block + "\n"
    atomic_write(cfg_path, content)

def remove_yaml(cfg_path, prefix, port_s):
    target = prefix + str(port_s)
    lines = open(cfg_path, encoding="utf-8").readlines()
    out, in_l, skip, skip_indent, removed = [], False, False, -1, False
    for raw in lines:
        if re.match(r"^[^\s#][^:]*:", raw):
            skip = False
            in_l = raw.split(":", 1)[0].strip() == "listeners"
            out.append(raw)
            continue
        s = raw.strip()
        indent = len(raw) - len(raw.lstrip())
        if in_l and skip and indent <= skip_indent and re.match(r"^-(?:\s|$)", s):
            skip = False
        if in_l and s.startswith("- name:") and not skip and scalar(s.split(":", 1)[1]) == target:
            skip, skip_indent, removed = True, indent, True
            continue
        if not skip:
            out.append(raw)
    if not removed:
        raise SystemExit(2)

    final, in_l, l_idx, has_items = [], False, -1, False
    for raw in out:
        if re.match(r"^[^\s#][^:]*:", raw):
            if in_l and not has_items and l_idx >= 0:
                final[l_idx] = "listeners: []\n"
            in_l = raw.split(":", 1)[0].strip() == "listeners"
            has_items = False
            final.append(raw)
            l_idx = len(final) - 1 if in_l else -1
            continue
        if in_l:
            if raw.strip() and not raw.lstrip().startswith("#"):
                has_items = True
                final.append(raw)
            elif raw.lstrip().startswith("#"):
                final.append(raw)
            continue
        final.append(raw)
    if in_l and not has_items and l_idx >= 0:
        final[l_idx] = "listeners: []\n"
    atomic_write(cfg_path, "".join(final))

cmd = sys.argv[1]
if cmd == "meta":
    m = PROTOS[sys.argv[2]]
    print(f"{m[0]}|{m[1]}|{m[2]}|{m[3]}|{m[4]}|{m[5]}")
elif cmd == "list":
    for port, pkey, label, name in list_listeners(sys.argv[2]):
        print(f"{port}\t{pkey}\t{label}\t{name}")
elif cmd == "validate":
    errs = validate_proto(sys.argv[2], json.load(open(sys.argv[3], encoding="utf-8")))
    if errs:
        print("\n".join(errs))
        raise SystemExit(1)
elif cmd == "kind":
    print(kind_of(sys.argv[2], json.load(open(sys.argv[3], encoding="utf-8"))))
elif cmd == "build":
    lines = build_block(sys.argv[2], json.load(open(sys.argv[3], encoding="utf-8")))
    open(sys.argv[4], "w", encoding="utf-8").write("\n".join(lines) + "\n")
elif cmd == "render":
    st = json.load(open(sys.argv[3], encoding="utf-8"))
    quiet = (len(sys.argv) > 6 and sys.argv[6] == "quiet")
    print(render_client(sys.argv[2], st, sys.argv[4], sys.argv[5], quiet=quiet))
elif cmd == "summary":
    print(summary_of(sys.argv[2], json.load(open(sys.argv[3], encoding="utf-8"))))
elif cmd == "notes":
    print(notes_of(sys.argv[2], json.load(open(sys.argv[3], encoding="utf-8"))))
elif cmd == "recover":
    recover_legacy(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
elif cmd == "append":
    append_yaml(sys.argv[2], sys.argv[3])
elif cmd == "remove":
    remove_yaml(sys.argv[2], sys.argv[3], sys.argv[4])
else:
    raise SystemExit(f"unknown cmd: {cmd}")
PY
}

# --- JSON 状态与密钥辅助 ---

load_proto_meta() {
    local meta
    meta=$(proto_engine meta "$1") || return 1
    IFS='|' read -r P_PREFIX P_STATE_ID P_DEFAULT_PORT P_MIN_VER P_LABEL P_DEFAULT_SNI <<< "$meta"
}

state_get() {
    python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    val = json.load(f).get(sys.argv[2], "")
if isinstance(val, bool):
    print("true" if val else "false")
elif val is None:
    print("")
else:
    print(val)
PY
}

state_set() {
    python3 - "$@" <<'PY'
import json, os, sys
path, pairs = sys.argv[1], sys.argv[2:]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
for i in range(0, len(pairs), 3):
    k, kind, raw = pairs[i], pairs[i + 1], pairs[i + 2]
    data[k] = int(raw) if kind == "int" else ((raw.lower() == "true") if kind == "bool" else raw)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PY
}

generate_secret() {
    python3 - "${1:-24}" <<'PY'
import secrets, string, sys
alpha = string.ascii_letters + string.digits
print("".join(secrets.choice(alpha) for _ in range(int(sys.argv[1]))))
PY
}

generate_uuid() {
    python3 -c 'import uuid; print(uuid.uuid4())'
}

node_state_file() { printf '/root/mihomo_%s_node_%s.json' "$1" "$2"; }
node_link_file()  { printf '/root/mihomo_%s_link_%s.txt' "$1" "$2"; }

# --- 网络与校验工具 ---

get_public_ip() {
    local ip="" u
    local urls=("https://api.ipify.org" "https://ip.sb" "https://ifconfig.me" "https://api64.ipify.org")
    for u in "${urls[@]}"; do
        ip=$(curl -s4 --max-time 4 "$u" 2>/dev/null || true)
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s\n' "$ip"; return 0; }
    done
    for u in "${urls[@]}"; do
        ip=$(curl -s6 --max-time 4 "$u" 2>/dev/null || true)
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && { printf '%s\n' "$ip"; return 0; }
    done
    return 1
}

normalize_connection_address() {
    local value="${1#[}"
    value="${value%]}"
    python3 - "$value" <<'PY'
import ipaddress, re, sys
v = sys.argv[1].strip()
try:
    print(ipaddress.ip_address(v).compressed)
except ValueError:
    if len(v) > 253 or not re.fullmatch(r'(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', v):
        raise SystemExit(1)
    print(v.rstrip('.'))
PY
}

is_valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_valid_uuid()     { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_valid_listen_host() { python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null; }
is_valid_domain()   { [[ ${#1} -le 253 ]] && [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
is_valid_sni()      { is_valid_domain "$1" || is_valid_listen_host "$1"; }

is_valid_dest() {
    python3 - "$1" <<'PY' 2>/dev/null
import ipaddress, re, sys
raw = sys.argv[1].strip()
if not raw or any(c in raw for c in " \t\r\n/@?#") or ":" not in raw:
    raise SystemExit(1)
host, _, port_s = raw.rpartition(":")
if not port_s.isdigit() or not (1 <= int(port_s) <= 65535):
    raise SystemExit(1)
if host.startswith("[") or host.endswith("]"):
    if not (host.startswith("[") and host.endswith("]")) or ipaddress.ip_address(host[1:-1]).version != 6:
        raise SystemExit(1)
elif ":" in host:
    raise SystemExit(1)
else:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        domain_re = r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
        if host != "localhost" and not re.fullmatch(domain_re, host):
            raise SystemExit(1)
PY
}

is_valid_alpn_list() {
    local alpn=$1 item
    [[ -n "$alpn" ]] || return 1
    local -a items=()
    IFS=',' read -r -a items <<< "$alpn"
    [[ ${#items[@]} -gt 0 ]] || return 1
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ "$item" =~ ^[A-Za-z0-9/._-]+$ ]] || return 1
    done
}

# --- 端口占用与监听探测 ---

port_is_bound() {
    local port=$1 proto=$2
    if python3 - "$port" "$proto" <<'PY'
import sys
port, proto = int(sys.argv[1]), sys.argv[2]
want = f"{port:04X}"
files = ("/proc/net/tcp", "/proc/net/tcp6") if proto == "tcp" else ("/proc/net/udp", "/proc/net/udp6")
seen = False
for path in files:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            seen = True
            next(f, None)
            for line in f:
                cols = line.split()
                if len(cols) >= 4 and ":" in cols[1] and cols[1].rsplit(":", 1)[1].upper() == want:
                    if proto == "udp" or cols[3] == "0A":
                        raise SystemExit(0)
    except OSError:
        continue
raise SystemExit(1 if seen else 2)
PY
    then
        return 0
    elif [[ $? -eq 2 ]] && command -v ss >/dev/null 2>&1; then
        local flag="-tln"
        [[ "$proto" == "udp" ]] && flag="-uln"
        ss "$flag" 2>/dev/null | grep -Eq ":${port}([^0-9]|$)" && return 0
    fi
    return 1
}

is_listener_port_in_config() {
    local port=$1
    [[ -f "$mihomo_config_path" ]] || return 1
    awk -v target="$port" '
        BEGIN { in_l = 0; found = 0 }
        /^[^[:space:]#][^:]*:/ { key = $0; sub(/:.*/, "", key); in_l = (key == "listeners"); next }
        in_l && /^[[:space:]]+port:[[:space:]]*/ {
            v = $0; sub(/^[[:space:]]+port:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*/, "", v); gsub(/[[:space:]"\x27]/, "", v)
            if (v == target) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$mihomo_config_path" 2>/dev/null
}

is_port_in_use() {
    local port=$1 kind=${2:-tcp}
    case "$kind" in
        tcp)  port_is_bound "$port" tcp && return 0 ;;
        udp)  port_is_bound "$port" udp && return 0 ;;
        both) port_is_bound "$port" tcp && return 0; port_is_bound "$port" udp && return 0 ;;
    esac
    is_listener_port_in_config "$port"
}

wait_listen() {
    local port=$1 kind=$2 i
    for ((i = 0; i < 12; i++)); do
        case "$kind" in
            tcp)  port_is_bound "$port" tcp && return 0 ;;
            udp)  port_is_bound "$port" udp && return 0 ;;
            both) port_is_bound "$port" tcp && port_is_bound "$port" udp && return 0 ;;
        esac
        sleep 0.4
    done
    return 1
}

# --- 系统检测、核心安装与服务管理 ---

detect_system() {
    [[ -f /etc/os-release ]] && . /etc/os-release && OS_ID=${ID:-}
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi
}

ensure_pkg_cmd() {
    local cmd=$1 pkg=${2:-$1}
    command -v "$cmd" >/dev/null 2>&1 && return 0
    info "正在安装依赖: ${pkg} ..."
    if [[ "$OS_ID" == "alpine" ]]; then
        apk add --no-cache "$pkg" || return 1
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || return 1
    else
        error "缺少命令 $cmd，且当前系统不支持自动安装。"; return 1
    fi
}

check_system_compatibility() {
    [[ "$(uname -s)" == "Linux" ]] || { error "仅支持 Linux"; return 1; }
    detect_system
    local required=("awk" "grep" "sed" "curl" "python3" "openssl" "gzip" "base64" "install" "mktemp" "tar" "realpath")
    local missing=() cmd
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache bash curl python3 openssl gzip coreutils tar || return 1
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl python3 openssl gzip coreutils tar || return 1
        else
            error "当前系统不支持自动安装依赖: ${missing[*]}"; return 1
        fi
    fi
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { error "缺少必要命令: $cmd"; return 1; }
    done
}

pre_check() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { error "必须以 root 身份运行"; exit 1; }
    check_system_compatibility || exit 1
}

install_self_shortcut() {
    local src="${BASH_SOURCE[0]:-}"
    [[ -n "$src" && -f "$src" ]] || return 0
    local cur
    cur=$(realpath "$src" 2>/dev/null || true)
    if [[ -n "$cur" && "$cur" != "$SELF_CMD_PATH" ]]; then
        install -m 0755 "$cur" "$SELF_CMD_PATH" 2>/dev/null || true
    fi
}

service_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet mihomo
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo status >/dev/null 2>&1 && rc-service mihomo status 2>/dev/null | grep -qi started
    else
        return 1
    fi
}

service_restart() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart mihomo || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo restart || return 1
    else
        error "无法确定服务管理器，请手动重启 Mihomo。"; return 1
    fi
    sleep 1
    service_is_active
}

installed_mihomo_version() {
    [[ -x "$mihomo_binary_path" ]] || return 1
    "$mihomo_binary_path" -v 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

require_min_mihomo() {
    local min_ver=$1 label=$2
    [[ -n "$min_ver" ]] || return 0
    local cur
    cur=$(installed_mihomo_version 2>/dev/null || true)
    [[ -n "$cur" ]] || { error "无法识别当前 Mihomo 版本"; return 1; }
    if ! python3 -c '
import re, sys
p = lambda v: tuple(int(x) for x in re.findall(r"\d+", v)[:3])
sys.exit(0 if p(sys.argv[1]) >= p(sys.argv[2]) else 1)
' "$cur" "$min_ver"; then
        error "当前 Mihomo v${cur} 过低，${label} 需要 >= v${min_ver}。请先执行 update 更新核心。"
        return 1
    fi
}

install_mihomo_core() {
    info "开始安装 Mihomo 核心..."
    local arch machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)  arch="amd64-compatible" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7|armv7l)  arch="armv7" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac
    [[ "$arch" == "armv7" ]] && warn "ARMv7 支持处于 Alpha 阶段，请留意运行稳定性。"

    local tag tmpdir url_tag url_alt
    tag="$(curl -fsSL "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4 || true)"
    info "目标版本: ${tag:-latest}"

    tmpdir="$(mktemp -d)" || return 1
    url_tag="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/mihomo-linux-${arch}-${tag}.gz"
    url_alt="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${arch}.gz"

    if [[ -n "$tag" ]] && curl -fsSL "$url_tag" -o "$tmpdir/mihomo.gz"; then
        :
    elif curl -fsSL "$url_alt" -o "$tmpdir/mihomo.gz"; then
        :
    else
        rm -rf "$tmpdir"; error "下载 Mihomo 核心失败。"; return 1
    fi

    if ! gzip -d "$tmpdir/mihomo.gz" || ! chmod +x "$tmpdir/mihomo" || ! "$tmpdir/mihomo" -v >/dev/null 2>&1; then
        rm -rf "$tmpdir"; error "下载的 Mihomo 二进制无法执行，已取消安装。"; return 1
    fi
    install -m 0755 "$tmpdir/mihomo" "$mihomo_binary_path" || { rm -rf "$tmpdir"; return 1; }
    mkdir -p "$mihomo_config_dir" || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    success "Mihomo 核心安装完成。"
}

install_geodata() {
    info "正在下载 GeoIP / GeoSite 数据文件..."
    mkdir -p "$mihomo_config_dir" || return 1
    local tmpdir
    tmpdir="$(mktemp -d "${mihomo_config_dir}/.geo-install.XXXXXX")" || return 1
    if ! curl -fsSL -o "$tmpdir/geoip.metadb" "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb" \
        || ! curl -fsSL -o "$tmpdir/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" \
        || [[ ! -s "$tmpdir/geoip.metadb" || ! -s "$tmpdir/geosite.dat" ]]; then
        rm -rf "$tmpdir"; error "Geo 数据文件下载失败，现有文件未被覆盖。"; return 1
    fi
    chmod 0644 "$tmpdir/geoip.metadb" "$tmpdir/geosite.dat"
    mv -f "$tmpdir/geoip.metadb" "${mihomo_config_dir}/geoip.metadb" && \
    mv -f "$tmpdir/geosite.dat" "${mihomo_config_dir}/geosite.dat" || { rm -rf "$tmpdir"; return 1; }
    rm -rf "$tmpdir"
    success "Geo 数据文件已就绪。"
}

ensure_core_for() {
    local min_ver=$1 label=$2
    [[ -x "$mihomo_binary_path" ]] || install_mihomo_core || return 1
    if [[ ! -s "${mihomo_config_dir}/geoip.metadb" || ! -s "${mihomo_config_dir}/geosite.dat" ]]; then
        install_geodata || return 1
    fi
    require_min_mihomo "$min_ver" "$label"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=Mihomo Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/mihomo -d /usr/local/etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
NoNewPrivileges=false
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now mihomo
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        install -d -m 0755 /var/log/mihomo || true
        cat > /etc/init.d/mihomo <<'EOF'
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
    after firewall
}
EOF
        chmod +x /etc/init.d/mihomo && rc-update add mihomo default && \
        (rc-service mihomo restart || rc-service mihomo start)
    else
        error "无法确定服务管理器 (需要 systemd 或 OpenRC)。"; return 1
    fi
}

init_mihomo_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then
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

validate_mihomo_config() {
    "$mihomo_binary_path" -t -d "$mihomo_config_dir" >/dev/null 2>&1
}

backup_config() {
    local suffix="${1:-bak}" bak
    bak=$(mktemp "${mihomo_config_path}.${suffix}.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$mihomo_config_path" "$bak" || { rm -f "$bak"; return 1; }
    chmod 600 "$bak"
    printf '%s\n' "$bak"
}

rollback_config() {
    cp "$1" "$mihomo_config_path" || true
    chmod 600 "$mihomo_config_path" || true
    service_restart >/dev/null 2>&1 || true
}

show_recent_log() {
    [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1 && \
        journalctl -u mihomo -n 40 --no-pager >&2 || true
}

# --- 证书、Reality 密钥与抗量子密钥准备 ---

install_cert_pair() {
    local src_crt=$1 src_key=$2 prefix=$3 port=$4
    [[ -f "$src_crt" && -f "$src_key" ]] || { error "证书或私钥不存在。"; return 1; }
    local dir="${mihomo_config_dir}/certs"
    mkdir -p "$dir" || return 1
    local crt="${dir}/${prefix}${port}.crt" key="${dir}/${prefix}${port}.key"
    cp "$src_crt" "$crt" && cp "$src_key" "$key" && chmod 600 "$crt" "$key" || return 1
    printf '%s\n%s\n' "$crt" "$key"
}

generate_self_signed() {
    local sni=$1 prefix=$2 port=$3
    local dir="${mihomo_config_dir}/certs" san
    mkdir -p "$dir" || return 1
    local crt="${dir}/${prefix}${port}.crt" key="${dir}/${prefix}${port}.key"
    if is_valid_listen_host "$sni"; then san="IP:${sni}"; else san="DNS:${sni}"; fi
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key" -out "$crt" -days 3650 -nodes \
        -subj "/CN=${sni}" -addext "subjectAltName=${san}" >/dev/null 2>&1; then
        rm -f "$crt" "$key"; error "生成自签证书失败。"; return 1
    fi
    chmod 600 "$crt" "$key"
    printf '%s\n%s\n' "$crt" "$key"
}

issue_acme_certificate() {
    local domain=$1 prefix=$2 port=$3 acme="/root/.acme.sh/acme.sh"
    if port_is_bound 80 tcp; then
        error "ACME HTTP-01 需要占用 TCP/80，该端口已有进程在监听。"; return 1
    fi
    if [[ ! -x "$acme" ]]; then
        info "正在安装 acme.sh ..."
        local inst
        inst=$(mktemp) || return 1
        if ! curl -fsSL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o "$inst" \
            || ! sh "$inst" --install-online --home /root/.acme.sh >/tmp/acme-install.log 2>&1; then
            rm -f "$inst"; error "安装 acme.sh 失败，详情见 /tmp/acme-install.log"; return 1
        fi
        rm -f "$inst"
    fi
    info "向 Let's Encrypt 申请 ${domain} 的证书 (standalone, TCP/80)..."
    if ! "$acme" --issue --standalone -d "$domain" --httpport 80 --keylength ec-256 --server letsencrypt >&2; then
        error "ACME 申请失败。请确认域名已解析到本机且公网 TCP/80 已放行。"; return 1
    fi
    local base="" d
    for d in "/root/.acme.sh/${domain}_ecc" "/root/.acme.sh/${domain}"; do
        [[ -f "${d}/fullchain.cer" ]] && base="$d" && break
    done
    [[ -n "$base" ]] || { error "未找到 fullchain.cer。"; return 1; }
    local key
    key=$(find "$base" -maxdepth 1 -type f -name '*.key' -print -quit)
    [[ -n "$key" && -f "$key" ]] || { error "未找到 ACME 私钥。"; return 1; }
    install_cert_pair "${base}/fullchain.cer" "$key" "$prefix" "$port"
}

prepare_tls() {
    local pkey=$1 state=$2
    load_proto_meta "$pkey" || return 1
    local mode existing_crt existing_key port sni domain src_crt src_key lines crt key skip
    mode=$(state_get "$state" cert_mode)
    [[ -z "$mode" || "$mode" == "none" ]] && return 0

    existing_crt=$(state_get "$state" certificate)
    existing_key=$(state_get "$state" private_key)
    if [[ -n "$existing_crt" && -n "$existing_key" && -f "$existing_crt" && -f "$existing_key" ]]; then
        return 0
    fi
    port=$(state_get "$state" port)
    sni=$(state_get "$state" sni)
    domain=$(state_get "$state" domain)
    src_crt=$(state_get "$state" cert_src)
    src_key=$(state_get "$state" key_src)
    [[ -z "$sni" && "$mode" == "acme" ]] && sni="$domain"
    [[ -z "$sni" ]] && sni="$P_DEFAULT_SNI"

    case "$mode" in
        selfsign) lines=$(generate_self_signed "$sni" "$P_PREFIX" "$port") || return 1; skip="true" ;;
        file)     lines=$(install_cert_pair "$src_crt" "$src_key" "$P_PREFIX" "$port") || return 1; skip="false" ;;
        acme)     lines=$(issue_acme_certificate "$domain" "$P_PREFIX" "$port") || return 1; skip="false" ;;
        *) error "未知证书模式: $mode"; return 1 ;;
    esac
    crt=$(printf '%s\n' "$lines" | sed -n '1p')
    key=$(printf '%s\n' "$lines" | sed -n '2p')
    state_set "$state" certificate str "$crt" private_key str "$key" sni str "$sni" skip_cert_verify bool "$skip"
}

generate_reality_keypair() {
    local key_out priv="" pub=""
    if [[ -x "$mihomo_binary_path" ]]; then
        key_out=$("$mihomo_binary_path" generate reality-keypair 2>&1 || true)
        if printf '%s\n' "$key_out" | grep -qi 'private'; then
            priv=$(printf '%s\n' "$key_out" | grep -i 'private' | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')
            pub=$(printf '%s\n' "$key_out" | grep -i 'public' | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')
        fi
    fi
    if [[ -z "$priv" || -z "$pub" ]]; then
        local py_keys
        py_keys=$(python3 - <<'PY' 2>/dev/null || true
import base64, os, subprocess, tempfile
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    sk = X25519PrivateKey.generate()
    sk_raw = sk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
    pk_raw = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
except ImportError:
    fd, tmp = tempfile.mkstemp(suffix=".pem")
    os.close(fd)
    try:
        subprocess.run(["openssl", "genpkey", "-algorithm", "x25519", "-out", tmp], check=True, capture_output=True)
        r1 = subprocess.run(["openssl", "pkey", "-in", tmp, "-outform", "DER"], check=True, capture_output=True)
        r2 = subprocess.run(["openssl", "pkey", "-in", tmp, "-pubout", "-outform", "DER"], check=True, capture_output=True)
        sk_raw, pk_raw = r1.stdout[-32:], r2.stdout[-32:]
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
print(base64.urlsafe_b64encode(sk_raw).decode().rstrip("="))
print(base64.urlsafe_b64encode(pk_raw).decode().rstrip("="))
PY
)
        priv=$(printf '%s\n' "$py_keys" | sed -n '1p' | tr -d '[:space:]')
        pub=$(printf '%s\n' "$py_keys" | sed -n '2p' | tr -d '[:space:]')
    fi
    [[ -n "$priv" && -n "$pub" ]] || { error "生成 Reality x25519 密钥对失败。"; return 1; }
    printf '%s\n%s\n' "$priv" "$pub"
}

generate_vless_pq_tokens() {
    ensure_pkg_cmd unzip unzip || return 1
    info "正在生成 VLESS Encryption (ML-KEM-768) 抗量子密钥..."
    local tmpdir machine arch
    tmpdir="$(mktemp -d)" || return 1
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)  arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7|armv7l)  arch="arm32-v7a" ;;
        *) rm -rf "$tmpdir"; error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac
    if ! curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" -o "$tmpdir/xray.zip" \
        || ! unzip -qo "$tmpdir/xray.zip" -d "$tmpdir"; then
        rm -rf "$tmpdir"; error "下载或解压临时 Xray 核心失败。"; return 1
    fi
    chmod +x "$tmpdir/xray"
    local out dec enc
    out="$("$tmpdir/xray" vlessenc 2>&1 || true)"
    rm -rf "$tmpdir"
    dec="$(printf '%s\n' "$out" | awk '/Authentication: ML-KEM-768/ {p=1; next} p && /"decryption":/ {gsub(/^.*"decryption": *"/,""); gsub(/".*/,""); print; exit}')"
    enc="$(printf '%s\n' "$out" | awk '/Authentication: ML-KEM-768/ {p=1; next} p && /"encryption":/ {gsub(/^.*"encryption": *"/,""); gsub(/".*/,""); print; exit}')"
    [[ -n "$dec" && -n "$enc" ]] || { error "提取 ML-KEM-768 密钥串失败。"; return 1; }
    printf '%s\n%s\n' "${dec/.native./.random.}" "${enc/.native./.random.}"
}

read_padding_scheme() {
    local file=$1
    [[ -s "$file" ]] || { error "padding-scheme 文件不存在或为空: $file"; return 1; }
    python3 - "$file" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read()
if b"\r" in raw:
    print("padding-scheme 含 CRLF 换行，请转为 LF。", file=sys.stderr); raise SystemExit(1)
text = raw.decode("utf-8").rstrip("\n")
if not any(re.match(r"^stop=[0-9]+\s*$", line) for line in text.split("\n")):
    print("padding-scheme 缺少 stop=N 行。", file=sys.stderr); raise SystemExit(1)
print(text)
PY
}

prepare_proto_secrets() {
    local pkey=$1 state=$2
    if [[ "$pkey" == "reality" ]]; then
        if [[ -z "$(state_get "$state" private_key)" || -z "$(state_get "$state" public_key)" ]]; then
            info "正在生成 Reality 密钥对..."
            local keys
            keys=$(generate_reality_keypair) || return 1
            state_set "$state" \
                private_key str "$(printf '%s\n' "$keys" | sed -n '1p')" \
                public_key str "$(printf '%s\n' "$keys" | sed -n '2p')"
        fi
    elif [[ "$pkey" == "vless-enc" ]]; then
        if [[ -z "$(state_get "$state" decryption)" || -z "$(state_get "$state" encryption)" ]]; then
            local tokens
            tokens=$(generate_vless_pq_tokens) || return 1
            state_set "$state" \
                decryption str "$(printf '%s\n' "$tokens" | sed -n '1p')" \
                encryption str "$(printf '%s\n' "$tokens" | sed -n '2p')"
        fi
    elif [[ "$pkey" == "tuic" ]]; then
        local port
        port=$(state_get "$state" port)
        if [[ -z "$(state_get "$state" certificate)" ]]; then
            local crt="${mihomo_config_dir}/certs/tuic-in-${port}.crt"
            local key="${mihomo_config_dir}/certs/tuic-in-${port}.key"
            [[ -f "$crt" && -f "$key" ]] && state_set "$state" certificate str "$crt" private_key str "$key"
        fi
    elif [[ "$pkey" == "anytls" && -f "$mihomo_config_path" ]]; then
        python3 - "$state" "$mihomo_config_path" <<'PY'
import json, os, re, sys
st_path, cfg_path = sys.argv[1:]
st = json.load(open(st_path, encoding="utf-8"))
target = f"anytls-in-{int(st['port'])}"
def sc(v):
    v = v.strip()
    try: return str(json.loads(v))
    except Exception: return v.strip("\"'")
in_l = in_item = in_pad = False
pad_indent = -1
crt, key, pad = st.get("certificate") or "", st.get("private_key") or "", []
for raw in open(cfg_path, encoding="utf-8"):
    if re.match(r"^[^\s#][^:]*:", raw):
        in_l = raw.split(":", 1)[0].strip() == "listeners"
        in_item = in_pad = False; continue
    if not in_l: continue
    s, ind = raw.strip(), len(raw) - len(raw.lstrip())
    if s.startswith("- name:"):
        in_item = (sc(s.split(":", 1)[1]) == target); in_pad = False; continue
    if not in_item: continue
    if in_pad:
        if s and ind <= pad_indent: in_pad = False
        else: pad.append(raw[pad_indent + 2:].rstrip("\n")); continue
    if s.startswith("certificate:") and not crt: crt = sc(s.split(":", 1)[1])
    elif s.startswith("private-key:") and not key: key = sc(s.split(":", 1)[1])
    elif s.startswith("padding-scheme:"): in_pad, pad_indent = True, ind
changed = False
if st.get("mode") == "tls" and crt and key and not st.get("certificate"):
    st["cert_mode"], st["certificate"], st["private_key"], changed = "file", crt, key, True
if pad and "padding_scheme" not in st:
    st["padding_scheme"], changed = "\n".join(pad).rstrip("\n"), True
if changed:
    with open(st_path, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=2); f.write("\n")
    os.chmod(st_path, 0o600)
PY
    fi
}

save_aux_files() {
    local pkey=$1 port=$2 state=$3
    if [[ "$pkey" == "reality" ]]; then
        printf '%s\n' "$(state_get "$state" public_key)" > "/root/mihomo_reality_pubkey_${port}.txt"
        chmod 600 "/root/mihomo_reality_pubkey_${port}.txt"
    elif [[ "$pkey" == "vless-enc" ]]; then
        printf '%s\n' "$(state_get "$state" encryption)" > "/root/mihomo_vless_encryption_client_key_${port}.txt"
        chmod 600 "/root/mihomo_vless_encryption_client_key_${port}.txt"
    elif [[ "$pkey" == "anytls" ]]; then
        local ip
        if [[ -s "$address_file" ]]; then ip=$(cat "$address_file"); else ip=$(get_public_ip || true); fi
        if [[ -n "$ip" ]]; then
            proto_engine render anytls "$state" "$ip" "AnyTLS-${port}" quiet > "/root/mihomo_anytls_proxies_${port}.yaml" 2>/dev/null || true
            chmod 600 "/root/mihomo_anytls_proxies_${port}.yaml" 2>/dev/null || true
        fi
    fi
}

cleanup_aux_files() {
    local pkey=$1 port=$2
    load_proto_meta "$pkey" || return 0
    rm -f "${mihomo_config_dir}/certs/${P_PREFIX}${port}.crt" \
          "${mihomo_config_dir}/certs/${P_PREFIX}${port}.key" \
          "${mihomo_config_dir}/certs/${P_PREFIX}${port}-"* \
          "$(node_state_file "$P_STATE_ID" "$port")" \
          "$(node_link_file "$P_STATE_ID" "$port")" \
          "/root/mihomo_reality_pubkey_${port}.txt" \
          "/root/mihomo_vless_encryption_client_key_${port}.txt" \
          "/root/mihomo_anytls_proxies_${port}.yaml"
}

ensure_node_state() {
    local pkey=$1 port=$2 state_file
    load_proto_meta "$pkey" || return 1
    state_file=$(node_state_file "$P_STATE_ID" "$port")
    if [[ -f "$state_file" ]]; then
        printf '%s\n' "$state_file"
        return 0
    fi
    if proto_engine recover "$pkey" "$port" "$mihomo_config_path" "$state_file" 2>/dev/null && [[ -f "$state_file" ]]; then
        printf '%s\n' "$state_file"
        return 0
    fi
    return 1
}

# --- 节点安装 / 查看 / 修改 / 删除核心流水线 ---

apply_listener() {
    local pkey=$1 state=$2 replacing=${3:-false} old_kind=${4:-}
    load_proto_meta "$pkey" || return 1
    local port kind block_file config_backup
    port=$(state_get "$state" port)
    kind=$(proto_engine kind "$pkey" "$state")

    if [[ "$replacing" != "true" ]]; then
        if is_port_in_use "$port" "$kind"; then
            error "端口 $port 已被占用，或已有 listener 使用该端口。"; return 1
        fi
    elif [[ -n "$old_kind" && "$old_kind" != "$kind" ]]; then
        if [[ "$kind" == "udp" || ( "$kind" == "both" && "$old_kind" == "tcp" ) ]] && port_is_bound "$port" udp; then
            error "UDP 端口 $port 已被其他进程占用。"; return 1
        fi
        if [[ "$kind" == "tcp" || ( "$kind" == "both" && "$old_kind" == "udp" ) ]] && port_is_bound "$port" tcp; then
            error "TCP 端口 $port 已被其他进程占用。"; return 1
        fi
    fi

    ensure_core_for "$P_MIN_VER" "$P_LABEL" || return 1
    init_mihomo_config || return 1
    prepare_proto_secrets "$pkey" "$state" || return 1

    block_file=$(mktemp) || return 1
    if ! proto_engine build "$pkey" "$state" "$block_file"; then
        rm -f "$block_file"; error "构建 ${P_LABEL} listener 失败。"; return 1
    fi

    config_backup=$(backup_config "bak") || { rm -f "$block_file"; error "备份配置失败"; return 1; }
    if [[ "$replacing" == "true" ]] && ! proto_engine remove "$mihomo_config_path" "$P_PREFIX" "$port"; then
        rm -f "$block_file"; error "未找到要修改的节点，原配置未改动。"; return 1
    fi
    if ! proto_engine append "$mihomo_config_path" "$block_file"; then
        rm -f "$block_file"; rollback_config "$config_backup"
        error "写入配置失败，已恢复原配置。"; return 1
    fi
    rm -f "$block_file"
    chmod 600 "$mihomo_config_path"

    if ! validate_mihomo_config; then
        rollback_config "$config_backup"
        error "新配置未通过 Mihomo 检查，已恢复原配置。"; return 1
    fi
    if ! service_is_active; then
        setup_service || { rollback_config "$config_backup"; return 1; }
    elif ! service_restart; then
        show_recent_log; rollback_config "$config_backup"
        error "Mihomo 重启失败，已恢复原配置。"; return 1
    fi
    if ! wait_listen "$port" "$kind"; then
        show_recent_log; rollback_config "$config_backup"
        error "端口 ${port} (${kind}) 没有进入监听，已回滚该节点。"; return 1
    fi

    local dest
    dest=$(node_state_file "$P_STATE_ID" "$port")
    cp "$state" "$dest" && chmod 600 "$dest"
    save_aux_files "$pkey" "$port" "$dest"
    success "${P_LABEL} 节点 (端口 ${port}) 已启动。"
    view_port_node "$pkey" "$port"
}

install_from_state() {
    local pkey=$1 state=$2 errs port kind
    load_proto_meta "$pkey" || return 1
    if ! errs=$(proto_engine validate "$pkey" "$state"); then
        error "${errs:-参数无效}"; return 1
    fi
    port=$(state_get "$state" port)
    kind=$(proto_engine kind "$pkey" "$state")
    if is_port_in_use "$port" "$kind"; then
        error "端口 $port 已被占用，或已有 listener 使用该端口。"; return 1
    fi
    prepare_tls "$pkey" "$state" || return 1
    if ! apply_listener "$pkey" "$state" false; then
        if [[ "$(state_get "$state" cert_mode)" =~ ^(selfsign|file|acme)$ ]]; then
            rm -f "${mihomo_config_dir}/certs/${P_PREFIX}${port}.crt" \
                  "${mihomo_config_dir}/certs/${P_PREFIX}${port}.key"
        fi
        return 1
    fi
}

link_name_for() {
    local sid=$1 port=$2 ipinfo country org
    ipinfo=$(curl -sf --max-time 4 https://ipinfo.io 2>/dev/null || true)
    if [[ -n "$ipinfo" ]]; then
        country=$(printf '%s\n' "$ipinfo" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        org=$(printf '%s\n' "$ipinfo" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then
        printf '%s\n' "${country} - ${org}"
    else
        printf '%s\n' "${sid}-${port}"
    fi
}

view_port_node() {
    local pkey=$1 port=$2 state ip link_name rendered save_file
    load_proto_meta "$pkey" || return 1
    state=$(ensure_node_state "$pkey" "$port") || {
        error "缺少端口 ${port} (${P_LABEL}) 的状态参数，无法还原客户端配置。"; return 1
    }
    if [[ -s "$address_file" ]]; then ip=$(cat "$address_file"); else ip=$(get_public_ip || true); fi
    [[ -n "$ip" ]] || { error "无法确定连接地址。"; return 1; }
    link_name=$(link_name_for "$P_STATE_ID" "$port")
    rendered=$(proto_engine render "$pkey" "$state" "$ip" "$link_name") || { error "生成客户端配置失败。"; return 1; }
    save_file=$(node_link_file "$P_STATE_ID" "$port")
    printf '%s\n' "$rendered" > "$save_file" && chmod 600 "$save_file"

    if [[ "$is_quiet" == true ]]; then
        emit_quiet_result "$(proto_engine render "$pkey" "$state" "$ip" "$link_name" quiet)"
        return 0
    fi

    echo "----------------------------------------------------------------"
    echo -e "${green} --- ${P_LABEL} 节点 (端口 ${port}) --- ${none}"
    echo -e "${yellow} 地址: ${cyan}${ip}${none}"
    echo -e "${yellow} 端口: ${cyan}${port}${none}"
    proto_engine summary "$pkey" "$state" >&2 || true
    echo "----------------------------------------------------------------"
    echo -e "${green} 客户端配置 (已保存到 ${save_file}):${none}\n"
    printf '%s\n' "$rendered"
    echo "----------------------------------------------------------------"
    proto_engine notes "$pkey" "$state" || true
}

# --- 跨协议节点检索与选择 ---

select_any_installed_node() {
    local prompt=$1 auto_single=${2:-false} rows count
    rows=$(proto_engine list "$mihomo_config_path" 2>/dev/null || true)
    [[ -n "$rows" ]] || { error "当前没有已安装的 Mihomo 入站节点。"; return 1; }
    count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    if [[ "$auto_single" == "true" && "$count" -eq 1 ]]; then
        printf '%s\n' "$rows"
        return 0
    fi
    echo "当前已安装的 Mihomo 入站节点:" >&2
    local p pk lbl nm
    while IFS=$'\t' read -r p pk lbl nm; do
        [[ -n "$p" ]] && printf "  - 端口 %-6s [%s]\n" "$p" "$lbl" >&2
    done <<< "$rows"
    local input_p matched
    while true; do
        read -r -p "$prompt" input_p
        matched=$(printf '%s\n' "$rows" | awk -F'\t' -v t="$input_p" '$1 == t { print; exit }')
        if [[ -n "$matched" ]]; then
            printf '%s\n' "$matched"
            return 0
        fi
        error "未找到端口: $input_p"
    done
}

list_nodes_cmd() {
    local rows
    rows=$(proto_engine list "$mihomo_config_path" 2>/dev/null || true)
    if [[ -z "$rows" ]]; then
        echo "当前没有已安装的 Mihomo 入站节点。"
        return 0
    fi
    printf "  %-8s %-24s %s\n" "端口" "协议" "Listener 名称"
    echo "  ----------------------------------------------------------"
    local p pk lbl nm
    while IFS=$'\t' read -r p pk lbl nm; do
        [[ -n "$p" ]] && printf "  %-8s %-24s %s\n" "$p" "$lbl" "$nm"
    done <<< "$rows"
}

view_node_cmd() {
    local target_port="${1:-}" row p pk lbl nm
    if [[ -n "$target_port" ]]; then
        row=$(proto_engine list "$mihomo_config_path" 2>/dev/null | awk -F'\t' -v t="$target_port" '$1 == t { print; exit }')
        [[ -n "$row" ]] || { error "未找到端口 ${target_port} 的 Mihomo 入站节点。"; return 1; }
    else
        row=$(select_any_installed_node "请输入要查看的端口: " true) || return 1
    fi
    IFS=$'\t' read -r p pk lbl nm <<< "$row"
    view_port_node "$pk" "$p"
}

delete_node_cmd() {
    local target_port="${1:-}" assume_yes="${2:-false}" row p pk lbl nm confirm backup
    if [[ -n "$target_port" ]]; then
        row=$(proto_engine list "$mihomo_config_path" 2>/dev/null | awk -F'\t' -v t="$target_port" '$1 == t { print; exit }')
        [[ -n "$row" ]] || { error "未找到端口 ${target_port} 的节点。"; return 1; }
    else
        row=$(select_any_installed_node "请输入要删除的端口: " false) || return 0
    fi
    IFS=$'\t' read -r p pk lbl nm <<< "$row"
    load_proto_meta "$pk" || return 1

    if [[ "$assume_yes" != "true" ]]; then
        read -r -p "确定删除 ${P_LABEL} 节点 (端口 ${p})? 其他节点将保留。[y/N]: " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消。"; return 0; }
    fi

    backup=$(backup_config "bak.delete") || { error "备份配置失败"; return 1; }
    proto_engine remove "$mihomo_config_path" "$P_PREFIX" "$p" || { error "未找到该节点。"; return 1; }
    if ! validate_mihomo_config || ! service_restart; then
        rollback_config "$backup"
        error "删除后服务未能正常启动，已恢复原配置。"; return 1
    fi
    cleanup_aux_files "$pk" "$p"
    success "已删除 ${P_LABEL} 节点 (端口 ${p})。"
}

# --- 交互式输入向导 (按协议) ---

ask_port_for() {
    local default_p=$1 kind=$2 port
    while true; do
        read -r -p "$(echo -e "端口 [1-65535] (默认: ${cyan}${default_p}${none}): ")" port
        [[ -z "$port" ]] && port=$default_p
        is_valid_port "$port" || { error "端口无效"; continue; }
        is_port_in_use "$port" "$kind" && { error "端口 $port 已被占用"; continue; }
        printf '%s\n' "$port"
        return 0
    done
}

ask_listen_host() {
    local listen
    read -r -p "$(echo -e "监听地址 (默认: ${cyan}0.0.0.0${none}): ")" listen
    [[ -z "$listen" ]] && listen="0.0.0.0"
    is_valid_listen_host "$listen" || { error "监听地址必须是 IP。"; return 1; }
    printf '%s\n' "$listen"
}

ask_cert_mode_for() {
    local def_sni=$1 choice
    echo "证书来源:" >&2
    echo -e "  ${green}1.${none} 自签证书 (客户端开启 skip-cert-verify)" >&2
    echo -e "  ${cyan}2.${none} 已有证书 PEM 文件" >&2
    echo -e "  ${cyan}3.${none} ACME 自动签发 (acme.sh, 需域名解析到本机且空闲 TCP/80)" >&2
    read -r -p "请选择 [1-3] (默认 1): " choice
    CERT_MODE="selfsign"; CERT_SNI=""; CERT_DOMAIN=""; CERT_SRC=""; CERT_KEY=""
    case "${choice:-1}" in
        2)
            CERT_MODE="file"
            while true; do read -r -p "证书 PEM 路径: " CERT_SRC; [[ -f "$CERT_SRC" ]] && break; error "文件不存在: $CERT_SRC"; done
            while true; do read -r -p "私钥 PEM 路径: " CERT_KEY; [[ -f "$CERT_KEY" ]] && break; error "文件不存在: $CERT_KEY"; done
            read -r -p "$(echo -e "SNI / 证书域名 (默认: ${cyan}${def_sni}${none}): ")" CERT_SNI
            [[ -z "$CERT_SNI" ]] && CERT_SNI=$def_sni
            ;;
        3)
            CERT_MODE="acme"
            while true; do read -r -p "ACME 域名: " CERT_DOMAIN; is_valid_domain "$CERT_DOMAIN" && break; error "域名格式无效"; done
            CERT_SNI=$CERT_DOMAIN
            ;;
        *)
            read -r -p "$(echo -e "自签证书 SNI (默认: ${cyan}${def_sni}${none}): ")" CERT_SNI
            [[ -z "$CERT_SNI" ]] && CERT_SNI=$def_sni
            ;;
    esac
}

ss_key_len() {
    case "$1" in
        2022-blake3-aes-128-gcm|aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|aes-256-gcm|chacha20-ietf-poly1305) echo 32 ;;
        *) return 1 ;;
    esac
}

ask_ss_credentials() {
    local choice klen
    echo "加密方式:" >&2
    echo -e "  ${green}1.${none} 2022-blake3-aes-128-gcm" >&2
    echo -e "  ${green}2.${none} 2022-blake3-aes-256-gcm (默认)" >&2
    echo -e "  ${green}3.${none} 2022-blake3-chacha20-poly1305" >&2
    echo -e "  ${cyan}4.${none} aes-128-gcm" >&2
    echo -e "  ${cyan}5.${none} aes-256-gcm" >&2
    echo -e "  ${cyan}6.${none} chacha20-ietf-poly1305" >&2
    read -r -p "请选择 [1-6] (默认 2): " choice
    case "${choice:-2}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        4) SS_METHOD="aes-128-gcm" ;;
        5) SS_METHOD="aes-256-gcm" ;;
        6) SS_METHOD="chacha20-ietf-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-256-gcm" ;;
    esac
    klen=$(ss_key_len "$SS_METHOD")
    read -r -p "密码 (回车自动生成随机密钥): " SS_PASSWORD
    if [[ -z "$SS_PASSWORD" ]]; then
        SS_PASSWORD=$(openssl rand -base64 "$klen" | tr -d '\r\n')
        info "已生成随机密钥: ${SS_PASSWORD}"
    fi
}

prompt_state_for() {
    local pkey=$1 out=$2
    load_proto_meta "$pkey" || return 1
    echo -e "\n${cyan}=== 配置 ${P_LABEL} 入站节点 ===${none}" >&2

    local port listen choice
    case "$pkey" in
        reality)
            local uuid sni
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            read -r -p "UUID (回车随机生成): " uuid
            [[ -z "$uuid" ]] && { uuid=$(generate_uuid); info "已生成 UUID: ${uuid}"; }
            while true; do
                read -r -p "$(echo -e "SNI 伪装域名 (默认: ${cyan}${P_DEFAULT_SNI}${none}): ")" sni
                [[ -z "$sni" ]] && sni=$P_DEFAULT_SNI
                is_valid_domain "$sni" && break
                error "域名格式无效"
            done
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" sni str "$sni" shortid str "20220701" private_key str "" public_key str ""
            ;;
        ss)
            port=$(ask_port_for "$P_DEFAULT_PORT" "both") || return 1
            listen=$(ask_listen_host) || return 1
            ask_ss_credentials || return 1
            state_set "$out" port int "$port" listen str "$listen" method str "$SS_METHOD" password str "$SS_PASSWORD"
            ;;
        vless-enc)
            local uuid
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            read -r -p "UUID (回车随机生成): " uuid
            [[ -z "$uuid" ]] && { uuid=$(generate_uuid); info "已生成 UUID: ${uuid}"; }
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" decryption str "" encryption str ""
            ;;
        anytls)
            local pw mode="jls" jls_u="" jls_pw="" dest="" sni=""
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            pw=$(generate_secret 24); info "已生成密码: ${pw}"
            echo "安全模式:  1. JLS 握手伪装 (默认，免证书)   2. 标准 TLS" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            CERT_MODE="none"; CERT_SNI=""; CERT_DOMAIN=""; CERT_SRC=""; CERT_KEY=""
            if [[ "${choice:-1}" == "2" ]]; then
                mode="tls"
                ask_cert_mode_for "anytls.local" || return 1
                sni=$CERT_SNI
            else
                jls_u="jls$(generate_secret 6 | tr 'A-Z' 'a-z')"
                jls_pw=$(generate_secret 24)
                while true; do
                    read -r -p "$(echo -e "JLS 回落目标 host:port (默认: ${cyan}www.bing.com:443${none}): ")" dest
                    [[ -z "$dest" ]] && dest="www.bing.com:443"
                    is_valid_dest "$dest" && break
                    error "格式必须是合法的 host:port"
                done
                read -r -p "JLS SNI (回车从 dest 自动推导): " sni
                [[ -z "$sni" ]] && { sni="${dest%:*}"; sni="${sni#[}"; sni="${sni%]}"; }
            fi
            state_set "$out" port int "$port" listen str "$listen" mode str "$mode" password str "$pw" \
                jls_user str "$jls_u" jls_password str "$jls_pw" dest str "$dest" sni str "$sni" \
                alpn str "h2,http/1.1" proxy str "" rate_limit int 0 padding_scheme str "" \
                cert_mode str "$CERT_MODE" domain str "$CERT_DOMAIN" cert_src str "$CERT_SRC" key_src str "$CERT_KEY" \
                certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        tuic)
            local uuid pw cc="bbr" um="native"
            port=$(ask_port_for "$P_DEFAULT_PORT" "udp") || return 1
            listen=$(ask_listen_host) || return 1
            uuid=$(generate_uuid); pw=$(generate_secret 24)
            info "已生成 UUID: ${uuid}"; info "已生成密码: ${pw}"
            echo "拥塞控制:  1. bbr (默认)   2. cubic   3. new_reno" >&2
            read -r -p "请选择 [1-3] (默认 1): " choice
            case "${choice:-1}" in 2) cc="cubic" ;; 3) cc="new_reno" ;; esac
            echo "UDP 中继模式:  1. native (默认)   2. quic" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            [[ "${choice:-1}" == "2" ]] && um="quic"
            ask_cert_mode_for "$P_DEFAULT_SNI" || return 1
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" password str "$pw" \
                congestion str "$cc" alpn str "h3" udp_relay_mode str "$um" \
                cert_mode str "$CERT_MODE" sni str "$CERT_SNI" domain str "$CERT_DOMAIN" \
                cert_src str "$CERT_SRC" key_src str "$CERT_KEY" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        hysteria2)
            local pw obfs="" opw=""
            port=$(ask_port_for "$P_DEFAULT_PORT" "udp") || return 1
            listen=$(ask_listen_host) || return 1
            pw=$(generate_secret 24); info "已生成密码: ${pw}"
            echo "QUIC 混淆:  1. 关闭 (默认)   2. salamander" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            [[ "${choice:-1}" == "2" ]] && { obfs="salamander"; opw=$(generate_secret 24); info "已生成 obfs 密码: ${opw}"; }
            ask_cert_mode_for "$P_DEFAULT_SNI" || return 1
            state_set "$out" port int "$port" listen str "$listen" username str "hy2user" password str "$pw" \
                obfs str "$obfs" obfs_password str "$opw" alpn str "h3" \
                cert_mode str "$CERT_MODE" sni str "$CERT_SNI" domain str "$CERT_DOMAIN" \
                cert_src str "$CERT_SRC" key_src str "$CERT_KEY" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        trojan)
            local pw ws=""
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            pw=$(generate_secret 24); info "已生成密码: ${pw}"
            read -r -p "WebSocket 路径 (留空表示 TCP): " ws
            ask_cert_mode_for "$P_DEFAULT_SNI" || return 1
            state_set "$out" port int "$port" listen str "$listen" password str "$pw" ws_path str "$ws" \
                cert_mode str "$CERT_MODE" sni str "$CERT_SNI" domain str "$CERT_DOMAIN" \
                cert_src str "$CERT_SRC" key_src str "$CERT_KEY" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        vmess)
            local uuid sec="none" ws=""
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            uuid=$(generate_uuid); info "已生成 UUID: ${uuid}"
            echo "安全层:  1. 无 TLS (默认)   2. TLS" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            CERT_MODE="none"; CERT_SNI=""; CERT_DOMAIN=""; CERT_SRC=""; CERT_KEY=""
            [[ "${choice:-1}" == "2" ]] && { sec="tls"; ask_cert_mode_for "$P_DEFAULT_SNI" || return 1; }
            read -r -p "WebSocket 路径 (留空表示 TCP): " ws
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" security str "$sec" ws_path str "$ws" \
                cert_mode str "$CERT_MODE" sni str "$CERT_SNI" domain str "$CERT_DOMAIN" \
                cert_src str "$CERT_SRC" key_src str "$CERT_KEY" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        shadowquic)
            local u pw dest sni cc="bbr" zero="false"
            port=$(ask_port_for "$P_DEFAULT_PORT" "udp") || return 1
            listen=$(ask_listen_host) || return 1
            u="sq$(generate_secret 6)"; pw=$(generate_secret 24)
            info "已生成用户名: ${u}"; info "已生成密码: ${pw}"
            while true; do
                read -r -p "$(echo -e "JLS 上游 host:port (默认: ${cyan}www.bing.com:443${none}): ")" dest
                [[ -z "$dest" ]] && dest="www.bing.com:443"
                is_valid_dest "$dest" && break
                error "格式必须是合法的 host:port"
            done
            read -r -p "JLS SNI (回车从上游自动推导): " sni
            echo "拥塞控制:  1. bbr (默认)   2. cubic   3. new_reno" >&2
            read -r -p "请选择 [1-3] (默认 1): " choice
            case "${choice:-1}" in 2) cc="cubic" ;; 3) cc="new_reno" ;; esac
            read -r -p "开启 0-RTT? [y/N]: " choice
            [[ "$choice" =~ ^[yY]$ ]] && zero="true"
            state_set "$out" port int "$port" listen str "$listen" username str "$u" password str "$pw" \
                dest str "$dest" sni str "$sni" alpn str "h3" congestion str "$cc" zero_rtt bool "$zero"
            ;;
        mieru)
            local tr="TCP" kind="tcp" u pw
            echo "传输协议:  1. TCP (默认)   2. UDP" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            [[ "${choice:-1}" == "2" ]] && { tr="UDP"; kind="udp"; }
            port=$(ask_port_for "$P_DEFAULT_PORT" "$kind") || return 1
            listen=$(ask_listen_host) || return 1
            u="mieru$(generate_secret 4)"; pw=$(generate_secret 24)
            info "已生成用户名: ${u}"; info "已生成密码: ${pw}"
            state_set "$out" port int "$port" listen str "$listen" username str "$u" password str "$pw" transport str "$tr"
            ;;
        sudoku)
            local key aead="chacha20-poly1305" mask="legacy"
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            key=$(generate_uuid); info "已生成共享 UUID key: ${key}"
            echo "AEAD:  1. chacha20-poly1305 (默认)   2. aes-128-gcm   3. none" >&2
            read -r -p "请选择 [1-3] (默认 1): " choice
            case "${choice:-1}" in 2) aead="aes-128-gcm" ;; 3) aead="none" ;; esac
            echo "HTTPMask:  1. legacy (默认)   2. 关闭" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            [[ "${choice:-1}" == "2" ]] && mask="off"
            state_set "$out" port int "$port" listen str "$listen" key str "$key" aead str "$aead" \
                padding_min int 2 padding_max int 7 table str "prefer_ascii" httpmask str "$mask"
            ;;
        trusttunnel)
            local u pw cc="bbr"
            port=$(ask_port_for "$P_DEFAULT_PORT" "both") || return 1
            listen=$(ask_listen_host) || return 1
            u="tt$(generate_secret 6)"; pw=$(generate_secret 24)
            info "已生成用户名: ${u}"; info "已生成密码: ${pw}"
            echo "拥塞控制:  1. bbr (默认)   2. cubic   3. new_reno" >&2
            read -r -p "请选择 [1-3] (默认 1): " choice
            case "${choice:-1}" in 2) cc="cubic" ;; 3) cc="new_reno" ;; esac
            ask_cert_mode_for "$P_DEFAULT_SNI" || return 1
            state_set "$out" port int "$port" listen str "$listen" username str "$u" password str "$pw" \
                congestion str "$cc" cert_mode str "$CERT_MODE" sni str "$CERT_SNI" domain str "$CERT_DOMAIN" \
                cert_src str "$CERT_SRC" key_src str "$CERT_KEY" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        http|socks|mixed)
            local kind="both" u pw
            [[ "$pkey" == "http" ]] && kind="tcp"
            port=$(ask_port_for "$P_DEFAULT_PORT" "$kind") || return 1
            listen=$(ask_listen_host) || return 1
            u="u$(generate_secret 8)"; pw=$(generate_secret 24)
            info "已生成用户名: ${u}"; info "已生成密码: ${pw}"
            state_set "$out" port int "$port" listen str "$listen" username str "$u" password str "$pw"
            ;;
        tunnel)
            local net="tcp,udp" kind="both" target
            echo "转发协议:  1. TCP + UDP (默认)   2. 仅 TCP   3. 仅 UDP" >&2
            read -r -p "请选择 [1-3] (默认 1): " choice
            case "${choice:-1}" in 2) net="tcp"; kind="tcp" ;; 3) net="udp"; kind="udp" ;; esac
            port=$(ask_port_for "$P_DEFAULT_PORT" "$kind") || return 1
            listen=$(ask_listen_host) || return 1
            while true; do
                read -r -p "转发目标 host:port : " target
                is_valid_dest "$target" && break
                error "格式必须是合法的 host:port"
            done
            state_set "$out" port int "$port" listen str "$listen" target str "$target" network str "$net"
            ;;
        hy2-realm)
            local tok
            port=$(ask_port_for "$P_DEFAULT_PORT" "tcp") || return 1
            listen=$(ask_listen_host) || return 1
            tok=$(generate_secret 24); info "已生成 Bearer token: ${tok}"
            echo "传输模式:  1. 明文 HTTP (默认)   2. HTTPS (TLS)" >&2
            read -r -p "请选择 [1-2] (默认 1): " choice
            CERT_MODE="none"; CERT_SNI=""; CERT_DOMAIN=""; CERT_SRC=""; CERT_KEY=""
            [[ "${choice:-1}" == "2" ]] && { ask_cert_mode_for "$P_DEFAULT_SNI" || return 1; }
            state_set "$out" port int "$port" listen str "$listen" token str "$tok" \
                max_realms int 65536 max_per_ip int 4 \
                cert_mode str "$CERT_MODE" sni str "$CERT_SNI" domain str "$CERT_DOMAIN" \
                cert_src str "$CERT_SRC" key_src str "$CERT_KEY" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
    esac
}

# --- CLI 参数构建状态 JSON ---

flags_state_for() {
    local pkey=$1 out=$2; shift 2
    load_proto_meta "$pkey" || return 1

    local port="" listen="0.0.0.0" uuid="" username="" password="" sni=""
    local method="2022-blake3-aes-256-gcm" mode="jls" dest="www.bing.com:443"
    local jls_user="" jls_pw="" proxy="" rate_limit="0" padding_file="" padding_scheme=""
    local congestion="bbr" alpn="" udp_mode="native" obfs="" obfs_pw=""
    local security="none" ws="" zero="false" transport="TCP"
    local key="" aead="chacha20-poly1305" table="prefer_ascii" mask="legacy" lo="2" hi="7"
    local target="" network="tcp,udp" token="" max_realms="65536" max_per_ip="4"
    local cert_mode="" src_crt="" src_key="" domain="" addr_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) shift ;;
            -q|--quiet) is_quiet=true; shift ;;
            -h|--help) proto_help "$pkey"; exit 0 ;;
            --port|--listen-host|--address|--uuid|--username|--password|--sni|--method|--mode|--dest|--jls-user|--jls-password|--proxy|--rate-limit|--padding-file|--congestion|--alpn|--udp-relay-mode|--obfs|--obfs-password|--security|--ws-path|--zero-rtt|--transport|--key|--aead|--table|--httpmask|--padding-min|--padding-max|--target|--network|--token|--max-realms|--max-realms-per-ip|--cert-mode|--cert|--key-file|--domain)
                [[ $# -ge 2 ]] || { error "参数 $1 缺少值"; return 1; }
                case "$1" in
                    --port) port="$2" ;; --listen-host) listen="$2" ;; --address) addr_override="$2" ;;
                    --uuid) uuid="$2" ;; --username) username="$2" ;; --password) password="$2" ;;
                    --sni) sni="$2" ;; --method) method="$2" ;; --mode) mode="$2" ;;
                    --dest) dest="$2" ;; --jls-user) jls_user="$2" ;; --jls-password) jls_pw="$2" ;;
                    --proxy) proxy="$2" ;; --rate-limit) rate_limit="$2" ;; --padding-file) padding_file="$2" ;;
                    --congestion) congestion="$2" ;; --alpn) alpn="$2" ;; --udp-relay-mode) udp_mode="$2" ;;
                    --obfs) obfs="$2" ;; --obfs-password) obfs_pw="$2" ;; --security) security="$2" ;;
                    --ws-path) ws="$2" ;; --zero-rtt) zero="$2" ;; --transport) transport="${2^^}" ;;
                    --key) key="$2" ;; --aead) aead="$2" ;; --table) table="$2" ;; --httpmask) mask="$2" ;;
                    --padding-min) lo="$2" ;; --padding-max) hi="$2" ;; --target) target="$2" ;;
                    --network) network="$2" ;; --token) token="$2" ;; --max-realms) max_realms="$2" ;;
                    --max-realms-per-ip) max_per_ip="$2" ;; --cert-mode) cert_mode="$2" ;;
                    --cert) src_crt="$2" ;; --key-file) src_key="$2" ;; --domain) domain="$2" ;;
                esac
                shift 2 ;;
            *)
                error "未知参数: $1 (可用 $(basename "$0") $pkey --help 查看支持参数)"
                return 1 ;;
        esac
    done

    # 对 TLS 协议兼容原 --key <私钥路径> (仅 sudoku 的 --key 表示 UUID)
    if [[ "$pkey" != "sudoku" && -n "$key" && -z "$src_key" ]]; then
        src_key="$key"
        key=""
    fi

    [[ -n "$addr_override" ]] && { set_address_cmd "$addr_override" || return 1; }

    [[ -z "$port" ]] && port=$P_DEFAULT_PORT
    is_valid_port "$port" || { error "端口无效: $port"; return 1; }
    is_valid_listen_host "$listen" || { error "监听地址必须是 IP: $listen"; return 1; }

    resolve_tls_defaults() {
        local def_mode=$1
        if [[ -z "$cert_mode" ]]; then
            if [[ -n "$src_crt" || -n "$src_key" ]]; then cert_mode="file"
            elif [[ -n "$domain" ]]; then cert_mode="acme"
            else cert_mode="$def_mode"; fi
        fi
        [[ -z "$sni" && "$cert_mode" == "acme" ]] && sni="$domain"
        [[ -z "$sni" && "$cert_mode" != "none" ]] && sni="$P_DEFAULT_SNI"
        if [[ -n "$sni" ]] && ! is_valid_sni "$sni"; then
            error "SNI 无效: $sni"; return 1
        fi
    }

    case "$pkey" in
        reality)
            [[ -z "$uuid" ]] && uuid=$(generate_uuid)
            [[ -z "$sni" ]] && sni=$P_DEFAULT_SNI
            is_valid_domain "$sni" || { error "Reality SNI 必须是合法域名: $sni"; return 1; }
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" sni str "$sni" shortid str "20220701" private_key str "" public_key str ""
            ;;
        ss)
            local klen
            klen=$(ss_key_len "$method") || { error "不支持的加密方式: $method"; return 1; }
            [[ -z "$password" ]] && password=$(openssl rand -base64 "$klen" | tr -d '\r\n')
            state_set "$out" port int "$port" listen str "$listen" method str "$method" password str "$password"
            ;;
        vless-enc)
            [[ -z "$uuid" ]] && uuid=$(generate_uuid)
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" decryption str "" encryption str ""
            ;;
        anytls)
            [[ -z "$password" ]] && password=$(generate_secret 24)
            [[ -z "$alpn" ]] && alpn="h2,http/1.1"
            is_valid_alpn_list "$alpn" || { error "ALPN 无效。"; return 1; }
            [[ "$rate_limit" =~ ^[0-9]+$ ]] || { error "--rate-limit 必须是非负整数。"; return 1; }
            [[ -n "$padding_file" ]] && { padding_scheme=$(read_padding_scheme "$padding_file") || return 1; }
            if [[ "$mode" == "jls" ]]; then
                is_valid_dest "$dest" || { error "JLS dest 必须是合法的 host:port。"; return 1; }
                [[ -z "$jls_user" ]] && jls_user="jls$(generate_secret 6 | tr 'A-Z' 'a-z')"
                [[ -z "$jls_pw" ]] && jls_pw=$(generate_secret 24)
                [[ -z "$sni" ]] && { sni="${dest%:*}"; sni="${sni#[}"; sni="${sni%]}"; }
                cert_mode="none"
            elif [[ "$mode" == "tls" ]]; then
                resolve_tls_defaults "file" || return 1
            else
                error "--mode 只能是 jls 或 tls。"; return 1
            fi
            state_set "$out" port int "$port" listen str "$listen" mode str "$mode" password str "$password" \
                jls_user str "$jls_user" jls_password str "$jls_pw" dest str "$dest" sni str "$sni" \
                alpn str "$alpn" proxy str "$proxy" rate_limit int "$rate_limit" padding_scheme str "$padding_scheme" \
                cert_mode str "$cert_mode" domain str "$domain" cert_src str "$src_crt" key_src str "$src_key" \
                certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        tuic)
            [[ -z "$uuid" ]] && uuid=$(generate_uuid)
            [[ -z "$password" ]] && password=$(generate_secret 24)
            [[ -z "$alpn" ]] && alpn="h3"
            is_valid_alpn_list "$alpn" || { error "ALPN 无效。"; return 1; }
            resolve_tls_defaults "selfsign" || return 1
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" password str "$password" \
                congestion str "$congestion" alpn str "$alpn" udp_relay_mode str "$udp_mode" \
                cert_mode str "$cert_mode" sni str "$sni" domain str "$domain" \
                cert_src str "$src_crt" key_src str "$src_key" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        hysteria2)
            [[ -z "$username" ]] && username="hy2user"
            [[ -z "$password" ]] && password=$(generate_secret 24)
            [[ -z "$alpn" ]] && alpn="h3"
            [[ "$obfs" == "none" ]] && obfs=""
            [[ "$obfs" == "salamander" && -z "$obfs_pw" ]] && obfs_pw=$(generate_secret 24)
            is_valid_alpn_list "$alpn" || { error "ALPN 无效。"; return 1; }
            resolve_tls_defaults "selfsign" || return 1
            state_set "$out" port int "$port" listen str "$listen" username str "$username" password str "$password" \
                obfs str "$obfs" obfs_password str "$obfs_pw" alpn str "$alpn" \
                cert_mode str "$cert_mode" sni str "$sni" domain str "$domain" \
                cert_src str "$src_crt" key_src str "$src_key" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        trojan)
            [[ -z "$password" ]] && password=$(generate_secret 24)
            resolve_tls_defaults "selfsign" || return 1
            state_set "$out" port int "$port" listen str "$listen" password str "$password" ws_path str "$ws" \
                cert_mode str "$cert_mode" sni str "$sni" domain str "$domain" \
                cert_src str "$src_crt" key_src str "$src_key" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        vmess)
            [[ -z "$uuid" ]] && uuid=$(generate_uuid)
            if [[ "$security" == "tls" ]]; then
                resolve_tls_defaults "selfsign" || return 1
            else
                cert_mode="none"
            fi
            state_set "$out" port int "$port" listen str "$listen" uuid str "$uuid" security str "$security" ws_path str "$ws" \
                cert_mode str "$cert_mode" sni str "$sni" domain str "$domain" \
                cert_src str "$src_crt" key_src str "$src_key" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        shadowquic)
            [[ -z "$username" ]] && username="sq$(generate_secret 6)"
            [[ -z "$password" ]] && password=$(generate_secret 24)
            [[ -z "$alpn" ]] && alpn="h3"
            is_valid_dest "$dest" || { error "JLS 上游必须是合法的 host:port。"; return 1; }
            is_valid_alpn_list "$alpn" || { error "ALPN 无效。"; return 1; }
            [[ -n "$sni" ]] && ! is_valid_sni "$sni" && { error "SNI 无效。"; return 1; }
            [[ "$zero" == "true" || "$zero" == "false" ]] || { error "--zero-rtt 只能是 true 或 false。"; return 1; }
            state_set "$out" port int "$port" listen str "$listen" username str "$username" password str "$password" \
                dest str "$dest" sni str "$sni" alpn str "$alpn" congestion str "$congestion" zero_rtt bool "$zero"
            ;;
        mieru)
            [[ -z "$username" ]] && username="mieru$(generate_secret 4)"
            [[ -z "$password" ]] && password=$(generate_secret 24)
            state_set "$out" port int "$port" listen str "$listen" username str "$username" password str "$password" transport str "$transport"
            ;;
        sudoku)
            [[ -z "$key" ]] && key=$(generate_uuid)
            [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || { error "padding 必须是整数。"; return 1; }
            state_set "$out" port int "$port" listen str "$listen" key str "$key" aead str "$aead" \
                padding_min int "$lo" padding_max int "$hi" table str "$table" httpmask str "$mask"
            ;;
        trusttunnel)
            [[ -z "$username" ]] && username="tt$(generate_secret 6)"
            [[ -z "$password" ]] && password=$(generate_secret 24)
            resolve_tls_defaults "selfsign" || return 1
            state_set "$out" port int "$port" listen str "$listen" username str "$username" password str "$password" \
                congestion str "$congestion" cert_mode str "$cert_mode" sni str "$sni" domain str "$domain" \
                cert_src str "$src_crt" key_src str "$src_key" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
        http|socks|mixed)
            [[ -z "$username" ]] && username="u$(generate_secret 8)"
            [[ -z "$password" ]] && password=$(generate_secret 24)
            state_set "$out" port int "$port" listen str "$listen" username str "$username" password str "$password"
            ;;
        tunnel)
            [[ -n "$target" ]] || { error "tunnel 必须提供 --target host:port。"; return 1; }
            is_valid_dest "$target" || { error "target 必须是合法的 host:port。"; return 1; }
            state_set "$out" port int "$port" listen str "$listen" target str "$target" network str "$network"
            ;;
        hy2-realm)
            [[ -z "$token" ]] && token=$(generate_secret 24)
            [[ "$max_realms" =~ ^[0-9]+$ && "$max_per_ip" =~ ^[0-9]+$ ]] || { error "数量上限必须是整数。"; return 1; }
            resolve_tls_defaults "none" || return 1
            state_set "$out" port int "$port" listen str "$listen" token str "$token" \
                max_realms int "$max_realms" max_per_ip int "$max_per_ip" \
                cert_mode str "$cert_mode" sni str "$sni" domain str "$domain" \
                cert_src str "$src_crt" key_src str "$src_key" certificate str "" private_key str "" skip_cert_verify bool false
            ;;
    esac
}

# --- 节点交互修改向导 ---

prompt_modify_for() {
    local pkey=$1 state=$2 input
    case "$pkey" in
        reality)
            read -r -p "新 UUID (回车保持不变, 输入 - 随机重置): " input
            [[ "$input" == "-" ]] && state_set "$state" uuid str "$(generate_uuid)"
            [[ -n "$input" && "$input" != "-" ]] && { is_valid_uuid "$input" || { error "UUID 无效"; return 1; }; state_set "$state" uuid str "$input"; }
            read -r -p "新 SNI 域名 (回车保持不变): " input
            [[ -n "$input" ]] && { is_valid_domain "$input" || { error "域名无效"; return 1; }; state_set "$state" sni str "$input"; }
            read -r -p "重新生成 Reality 密钥对? [y/N]: " input
            [[ "$input" =~ ^[yY]$ ]] && state_set "$state" private_key str "" public_key str ""
            ;;
        ss)
            ask_ss_credentials || return 1
            state_set "$state" method str "$SS_METHOD" password str "$SS_PASSWORD"
            ;;
        vless-enc)
            info "修改将重新生成 ML-KEM-768 密钥对。"
            read -r -p "新 UUID (回车保持不变, 输入 - 随机重置): " input
            [[ "$input" == "-" ]] && state_set "$state" uuid str "$(generate_uuid)"
            [[ -n "$input" && "$input" != "-" ]] && { is_valid_uuid "$input" || { error "UUID 无效"; return 1; }; state_set "$state" uuid str "$input"; }
            state_set "$state" decryption str "" encryption str ""
            ;;
        anytls|shadowquic)
            local old_dest old_host sni
            old_dest=$(state_get "$state" dest)
            sni=$(state_get "$state" sni)
            old_host="${old_dest%:*}"; old_host="${old_host#[}"; old_host="${old_host%]}"
            read -r -p "新密码 (回车保持不变, 输入 - 随机重置): " input
            [[ "$input" == "-" ]] && state_set "$state" password str "$(generate_secret 24)"
            [[ -n "$input" && "$input" != "-" ]] && state_set "$state" password str "$input"
            if [[ "$pkey" == "shadowquic" || "$(state_get "$state" mode)" == "jls" ]]; then
                local cur_dest="$old_dest"
                read -r -p "$(echo -e "JLS 目标/上游 (当前: ${cyan}${old_dest}${none}, 回车保持不变): ")" input
                if [[ -n "$input" ]]; then
                    is_valid_dest "$input" || { error "必须是合法的 host:port"; return 1; }
                    cur_dest="$input"
                    state_set "$state" dest str "$cur_dest"
                    if [[ -z "$sni" || "$sni" == "$old_host" ]]; then
                        sni="${cur_dest%:*}"; sni="${sni#[}"; sni="${sni%]}"
                        [[ "$pkey" == "shadowquic" ]] && sni=""
                        state_set "$state" sni str "$sni"
                    fi
                fi
                read -r -p "$(echo -e "JLS SNI (当前: ${cyan}${sni:-自动推导}${none}, 输入 - 自动推导, 回车保持不变): ")" input
                if [[ "$input" == "-" ]]; then
                    sni=""
                    [[ "$pkey" == "anytls" ]] && { sni="${cur_dest%:*}"; sni="${sni#[}"; sni="${sni%]}"; }
                    state_set "$state" sni str "$sni"
                elif [[ -n "$input" ]]; then
                    is_valid_sni "$input" || { error "SNI 无效"; return 1; }
                    state_set "$state" sni str "$input"
                fi
            fi
            ;;
        tuic|trusttunnel)
            read -r -p "新密码 (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" password str "$input"
            read -r -p "拥塞控制 [bbr/cubic/new_reno] (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" congestion str "$input"
            ;;
        hysteria2)
            read -r -p "新密码 (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" password str "$input"
            read -r -p "obfs [none/salamander] (回车保持不变): " input
            if [[ "$input" == "salamander" ]]; then
                local opw
                opw=$(state_get "$state" obfs_password)
                [[ -z "$opw" ]] && opw=$(generate_secret 24)
                state_set "$state" obfs str "salamander" obfs_password str "$opw"
            elif [[ "$input" == "none" || "$input" == "-" ]]; then
                state_set "$state" obfs str ""
            fi
            ;;
        trojan|vmess)
            if [[ "$pkey" == "trojan" ]]; then
                read -r -p "新密码 (回车保持不变): " input
                [[ -n "$input" ]] && state_set "$state" password str "$input"
            else
                read -r -p "新 UUID (回车保持不变): " input
                [[ -n "$input" ]] && { is_valid_uuid "$input" || { error "UUID 无效"; return 1; }; state_set "$state" uuid str "$input"; }
            fi
            read -r -p "WebSocket 路径 (输入 - 改回 TCP, 回车保持不变): " input
            [[ "$input" == "-" ]] && state_set "$state" ws_path str ""
            [[ -n "$input" && "$input" != "-" ]] && state_set "$state" ws_path str "$input"
            ;;
        mieru)
            read -r -p "新密码 (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" password str "$input"
            read -r -p "传输 [TCP/UDP] (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" transport str "${input^^}"
            ;;
        sudoku)
            read -r -p "重新生成共享 UUID key? [y/N]: " input
            [[ "$input" =~ ^[yY]$ ]] && state_set "$state" key str "$(generate_uuid)"
            ;;
        http|socks|mixed)
            read -r -p "新密码 (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" password str "$input"
            ;;
        tunnel)
            read -r -p "新的转发目标 host:port (回车保持不变): " input
            [[ -n "$input" ]] && { is_valid_dest "$input" || { error "target 无效"; return 1; }; state_set "$state" target str "$input"; }
            ;;
        hy2-realm)
            read -r -p "新 Bearer token (回车保持不变): " input
            [[ -n "$input" ]] && state_set "$state" token str "$input"
            ;;
    esac
    return 0
}

modify_node_cmd() {
    local row p pk lbl nm src tmp errs old_kind rc
    row=$(select_any_installed_node "请输入要修改的端口: " false) || return 0
    IFS=$'\t' read -r p pk lbl nm <<< "$row"
    src=$(ensure_node_state "$pk" "$p") || { error "读不到原参数文件，请删除后重建该节点。"; return 1; }
    tmp=$(mktemp) || return 1
    cp "$src" "$tmp" && chmod 600 "$tmp"
    old_kind=$(proto_engine kind "$pk" "$tmp")
    if ! prompt_modify_for "$pk" "$tmp" || ! errs=$(proto_engine validate "$pk" "$tmp"); then
        [[ -n "${errs:-}" ]] && error "$errs"
        rm -f "$tmp"; return 1
    fi
    info "正在重写端口 ${p} (${lbl}) 的配置并重启 Mihomo..."
    apply_listener "$pk" "$tmp" true "$old_kind"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# --- 系统级操作 (连接地址 / 更新 / 重启 / 日志 / 备份卸载) ---

set_address_cmd() {
    local addr="${1:-}" norm
    if [[ "$addr" == "auto" ]]; then
        rm -f "$address_file"
        success "已恢复为自动获取公网 IP。"
        return 0
    elif [[ -n "$addr" ]]; then
        norm=$(normalize_connection_address "$addr") || { error "连接地址无效: $addr (请填纯 IP 或域名)"; return 1; }
        printf '%s\n' "$norm" > "$address_file" && chmod 600 "$address_file"
        success "连接地址已设置为: $norm"
        return 0
    fi

    echo -e "\n=================================================\n         自定义连接地址 (NAT/DDNS 模式)\n================================================="
    if [[ -s "$address_file" ]]; then
        echo -e "当前已设置: ${cyan}$(cat "$address_file")${none}"
    else
        echo -e "当前状态: ${yellow}自动获取公网 IP${none}"
    fi
    read -r -p "请输入新的连接地址 (留空恢复自动获取): " addr
    if [[ -z "$addr" ]]; then
        rm -f "$address_file"
        success "已恢复为自动获取公网 IP。"
        return 0
    fi
    norm=$(normalize_connection_address "$addr") || { error "连接地址无效，请填纯 IP 或域名。"; return 1; }
    printf '%s\n' "$norm" > "$address_file" && chmod 600 "$address_file"
    success "连接地址已更新为: $norm"
}

update_mihomo_cmd() {
    [[ -f "$mihomo_binary_path" ]] || { error "Mihomo 未安装"; return 1; }
    local cur latest
    cur=$(installed_mihomo_version 2>/dev/null || echo "未知")
    latest=$(curl -fsSL "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" 2>/dev/null | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4 || true)
    [[ -n "$latest" ]] && info "当前版本: ${cyan}v${cur}${none}，最新版本: ${cyan}${latest}${none}"
    install_mihomo_core || return 1
    install_geodata || return 1
    service_restart || return 1
    success "Mihomo 核心与 Geo 数据已更新。"
}

restart_mihomo_cmd() {
    [[ -f "$mihomo_binary_path" ]] || { error "Mihomo 未安装"; return 1; }
    info "正在重启 Mihomo..."
    service_restart || { error "重启失败"; return 1; }
    success "Mihomo 已重启。"
}

view_mihomo_log_cmd() {
    [[ -f "$mihomo_binary_path" ]] || { error "Mihomo 未安装"; return 1; }
    info "显示日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u mihomo -f --no-pager || true
    elif [[ -d /var/log/mihomo ]]; then
        tail -n 100 -F /var/log/mihomo/*.log 2>/dev/null || true
    else
        error "当前环境没有 journalctl。OpenRC 请查看 /var/log/messages。"
    fi
    trap - SIGINT
    press_any_key_to_continue
}

backup_config_archive() (
    local cfg_dir="${1:-$mihomo_config_dir}" state_dir="${2:-/root}" archive tmp file
    local -a entries=(client-state)
    umask 077
    archive=$(mktemp "${state_dir}/mihomo-config-backup-$(date +%Y%m%d-%H%M%S).XXXXXX.tar.gz") || return 1
    tmp=$(mktemp -d) || { rm -f -- "$archive"; return 1; }
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/client-state" || return 1
    if [[ -d "$cfg_dir" ]]; then
        mkdir -p "$tmp/mihomo" || return 1
        cp -a "$cfg_dir/." "$tmp/mihomo/" || return 1
        entries=(mihomo client-state)
    fi
    for file in \
        "$state_dir"/mihomo_*_link_*.txt \
        "$state_dir"/mihomo_*_node_*.json \
        "$state_dir"/mihomo_*_proxies_*.yaml \
        "$state_dir"/mihomo_reality_pubkey_*.txt \
        "$state_dir"/mihomo_vless_encryption_client_key_*.txt \
        "$state_dir"/inbound_address.txt; do
        [[ -f "$file" ]] || continue
        cp -pL -- "$file" "$tmp/client-state/" || return 1
    done
    if ! tar -czf "$archive" -C "$tmp" "${entries[@]}" || ! chmod 600 "$archive"; then
        rm -f -- "$archive"; return 1
    fi
    printf '%s\n' "$archive"
)

remove_geo_updater() {
    if command -v crontab >/dev/null 2>&1; then
        local cron_file filtered_file
        cron_file=$(mktemp) || return 0
        filtered_file=$(mktemp) || { rm -f "$cron_file"; return 0; }
        if crontab -l > "$cron_file" 2>/dev/null; then
            awk '$0 !~ /^[[:space:]]*#/ && $0 ~ /(^|[[:space:]])\/root\/update_geo[.]sh([[:space:]]|$)/ { next } { print }' \
                "$cron_file" > "$filtered_file" && ! cmp -s "$cron_file" "$filtered_file" && crontab "$filtered_file" || true
        fi
        rm -f "$cron_file" "$filtered_file"
    fi
    rm -f -- /root/update_geo.sh || true
}

uninstall_mihomo_cmd() {
    local assume_yes="${1:-false}" confirm config_archive
    [[ -f "$mihomo_binary_path" || -d "$mihomo_config_dir" ]] || { error "Mihomo 未安装"; return 1; }
    if [[ "$assume_yes" != "true" ]]; then
        read -r -p "确定卸载整个 Mihomo 及全部入站配置吗? (卸载前将自动打包备份) [y/N]: " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消。"; return 0; }
    fi
    config_archive=$(backup_config_archive "$mihomo_config_dir" /root) || { error "配置备份失败，已取消卸载。"; return 1; }
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mihomo || true; systemctl disable mihomo || true
        rm -f /etc/systemd/system/mihomo.service; systemctl daemon-reload || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo stop || true; rc-update del mihomo default || true
        rm -f /etc/init.d/mihomo
    fi
    rm -f "$mihomo_binary_path" "$SELF_CMD_PATH"
    rm -rf "$mihomo_config_dir"
    rm -f /root/mihomo_*_link_*.txt \
          /root/mihomo_*_node_*.json \
          /root/mihomo_*_proxies_*.yaml \
          /root/mihomo_reality_pubkey_*.txt \
          /root/mihomo_vless_encryption_client_key_*.txt
    remove_geo_updater
    success "Mihomo 已卸载。配置及状态备份: $config_archive"
}

# --- 协议安装入口 (交互与非交互) ---

install_proto_interactive() {
    local pkey=$1 state status
    state=$(mktemp) || return 1
    if ! prompt_state_for "$pkey" "$state"; then
        rm -f "$state"; return 1
    fi
    install_from_state "$pkey" "$state"
    status=$?
    rm -f "$state"
    return $status
}

install_proto_noninteractive() {
    local pkey=$1; shift
    local state
    state=$(mktemp) || exit 1
    if ! flags_state_for "$pkey" "$state" "$@" || ! install_from_state "$pkey" "$state"; then
        rm -f "$state"; exit 1
    fi
    rm -f "$state"
}

choose_protocol_wizard() {
    while true; do
        clear || true
        echo -e "${cyan}======================================================${none}"
        echo -e "${cyan}               选择要安装的 Mihomo 入站协议            ${none}"
        echo -e "${cyan}======================================================${none}"
        echo -e "  ${yellow}[主流协议]${none}"
        echo -e "   ${green}1.${none} VLESS-Reality (Vision)       ${green}5.${none} TUIC v5 (UDP/QUIC)"
        echo -e "   ${green}2.${none} Shadowsocks (2022 / AEAD)    ${green}6.${none} Hysteria2 (UDP/QUIC)"
        echo -e "   ${green}3.${none} VLESS Encryption (PQ 抗量子) ${green}7.${none} Trojan (TLS / WS)"
        echo -e "   ${green}4.${none} AnyTLS (JLS 伪装 / TLS)      ${green}8.${none} VMess (TCP / WS / TLS)"
        echo ""
        echo -e "  ${yellow}[进阶与混淆协议]${none}"
        echo -e "   ${green}9.${none} ShadowQUIC (UDP + JLS)      ${green}11.${none} Sudoku (UUID 共享密钥)"
        echo -e "  ${green}10.${none} Mieru (TCP / UDP)           ${green}12.${none} TrustTunnel (HTTP/2+3)"
        echo ""
        echo -e "  ${yellow}[基础代理与转发服务]${none}"
        echo -e "  ${green}13.${none} HTTP 代理 (带认证)          ${green}16.${none} Tunnel 端口转发"
        echo -e "  ${green}14.${none} SOCKS5 代理 (带认证+UDP)    ${green}17.${none} Hysteria2 Realm 汇合服务"
        echo -e "  ${green}15.${none} Mixed 混合代理 (HTTP+SOCKS)"
        echo "------------------------------------------------------"
        echo -e "   ${cyan}0.${none} 返回上一级"
        echo -e "${cyan}======================================================${none}"
        local c pkey=""
        read -r -p "请选择协议 [0-17]: " c
        case "$c" in
            1) pkey="reality" ;;     2) pkey="ss" ;;          3) pkey="vless-enc" ;;
            4) pkey="anytls" ;;      5) pkey="tuic" ;;        6) pkey="hysteria2" ;;
            7) pkey="trojan" ;;      8) pkey="vmess" ;;       9) pkey="shadowquic" ;;
            10) pkey="mieru" ;;      11) pkey="sudoku" ;;     12) pkey="trusttunnel" ;;
            13) pkey="http" ;;       14) pkey="socks" ;;      15) pkey="mixed" ;;
            16) pkey="tunnel" ;;     17) pkey="hy2-realm" ;;
            0) return 0 ;;
            *) error "无效选项"; sleep 1; continue ;;
        esac
        install_proto_interactive "$pkey"
        return $?
    done
}

# --- 交互主菜单 ---

show_status_banner() {
    if [[ ! -f "$mihomo_binary_path" ]]; then
        echo -e "  Mihomo 状态: ${red}未安装${none}"
        return
    fi
    local ver svc rows count
    ver=$(installed_mihomo_version 2>/dev/null || echo "未知")
    if service_is_active; then svc="${green}运行中${none}"; else svc="${yellow}未运行${none}"; fi
    rows=$(proto_engine list "$mihomo_config_path" 2>/dev/null || true)
    count=0
    [[ -n "$rows" ]] && count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    echo -e "  Mihomo 状态: ${green}已安装${none} | ${svc} | 版本: ${cyan}v${ver}${none} | 入站节点: ${cyan}${count}${none} 个"
    if [[ "$count" -gt 0 ]]; then
        local summary
        summary=$(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s/%s  ", $1, $3 }')
        echo -e "  已装端口:    ${cyan}${summary}${none}"
    fi
}

main_menu() {
    install_self_shortcut
    while true; do
        clear || true
        echo -e "${cyan}======================================================${none}"
        echo -e "${cyan}         Mihomo 入站节点统一安装与管理面板            ${none}"
        echo -e "${cyan}======================================================${none}"
        show_status_banner
        echo "------------------------------------------------------"
        printf "  ${green}%-3s${none} %s\n" "1." "安装 / 添加入站节点 (17 种协议自选)"
        printf "  ${green}%-3s${none} %s\n" "2." "查看节点链接 / 客户端配置"
        printf "  ${cyan}%-3s${none} %s\n"  "3." "修改已有节点配置"
        printf "  ${red}%-3s${none} %s\n"   "4." "删除指定入站节点"
        printf "  ${cyan}%-3s${none} %s\n"  "5." "列出全部已装入站节点"
        echo "------------------------------------------------------"
        printf "  ${cyan}%-3s${none} %s\n"  "6." "更新 Mihomo 核心与 Geo 数据"
        printf "  ${yellow}%-3s${none} %s\n" "7." "重启 Mihomo 服务"
        printf "  ${magenta}%-3s${none} %s\n" "8." "查看 Mihomo 实时日志"
        printf "  ${magenta}%-3s${none} %s\n" "9." "设置外部连接地址 (NAT / DDNS)"
        printf "  ${red}%-3s${none} %s\n"   "10." "卸载 Mihomo 及全部配置"
        echo "------------------------------------------------------"
        printf "  ${yellow}%-3s${none} %s\n" "0." "退出 (终端输入 mihomo-inbounds 可随时唤起)"
        echo -e "${cyan}======================================================${none}"
        local choice needs_pause=true
        read -r -p "请输入选项 [0-10]: " choice
        case "$choice" in
            1) choose_protocol_wizard ;;
            2) view_node_cmd "" ;;
            3) modify_node_cmd ;;
            4) delete_node_cmd "" false ;;
            5) list_nodes_cmd ;;
            6) update_mihomo_cmd ;;
            7) restart_mihomo_cmd ;;
            8) view_mihomo_log_cmd; needs_pause=false ;;
            9) set_address_cmd "" ;;
            10) uninstall_mihomo_cmd false ;;
            0) success "再见！"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        [[ "$needs_pause" == true ]] && press_any_key_to_continue
    done
}

# --- 主入口与命令行分发 ---

main() {
    if [[ $# -eq 0 ]]; then
        pre_check
        main_menu
        exit 0
    fi

    local sub="$1"; shift
    case "$sub" in
        -h|--help|help)
            usage "${1:-}"
            exit 0
            ;;
    esac

    # 预先识别 --help 与 --quiet，避免 pre_check 输出污染安静模式 stdout
    local arg want_help=false
    for arg in "$@"; do
        case "$arg" in
            -h|--help) want_help=true ;;
            -q|--quiet) is_quiet=true ;;
        esac
    done

    local pkey=""
    if pkey=$(normalize_proto_key "$sub" 2>/dev/null); then
        if [[ "$want_help" == true ]]; then
            proto_help "$pkey"
            exit 0
        fi
        [[ "$is_quiet" == true ]] && exec 3>&1 1>&2
        pre_check
        if [[ $# -eq 0 ]]; then
            # 仅传协议名、无额外参数：进入该协议的互动问答向导
            install_proto_interactive "$pkey"
        else
            install_proto_noninteractive "$pkey" "$@"
        fi
        exit $?
    fi

    [[ "$is_quiet" == true ]] && exec 3>&1 1>&2
    pre_check

    case "$sub" in
        list|ls)
            list_nodes_cmd
            ;;
        info|show|view)
            local p=""
            for arg in "$@"; do [[ "$arg" != "-q" && "$arg" != "--quiet" ]] && p="$arg"; done
            view_node_cmd "$p"
            ;;
        delete|del|rm)
            local p="" yes=false
            for arg in "$@"; do
                case "$arg" in -y|--yes) yes=true ;; *) p="$arg" ;; esac
            done
            delete_node_cmd "$p" "$yes"
            ;;
        address|addr)
            [[ $# -ge 1 ]] || { error "用法: $(basename "$0") address <IP|域名|auto>"; exit 1; }
            set_address_cmd "$1"
            ;;
        update)
            update_mihomo_cmd
            ;;
        restart)
            restart_mihomo_cmd
            ;;
        uninstall)
            local yes=false
            for arg in "$@"; do [[ "$arg" == "-y" || "$arg" == "--yes" ]] && yes=true; done
            uninstall_mihomo_cmd "$yes"
            ;;
        *)
            error "未知协议或子命令: $sub"
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
