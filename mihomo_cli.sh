#!/bin/bash
# ==============================================================================
# Mihomo 非交互式一键搭建脚本 (Flag 模式)
# 通过命令行参数直接搭建节点，无需进入菜单。原有的交互式菜单脚本保持不变。
#
# 用法示例:
#   ./mihomo_cli.sh reality   --port 443 --sni hk.art.museum
#   ./mihomo_cli.sh ss        --port 2022 --method 2022-blake3-aes-256-gcm
#   ./mihomo_cli.sh vless-enc --port 40000
#   ./mihomo_cli.sh address   example.ddns.net     # 设置连接地址 (NAT/DDNS)
#   ./mihomo_cli.sh address   auto                 # 恢复自动获取公网 IP
# ==============================================================================

set -uo pipefail

# --- 仓库配置 (可用环境变量 MIHOMO_BASE_URL 覆盖) ---
BASE_URL="${MIHOMO_BASE_URL:-https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main}"
ADDRESS_FILE="/root/inbound_address.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; PLAIN='\033[0m'
QUIET=false

die()  { echo -e "${RED}[✖] $*${PLAIN}" >&2; exit 1; }
info() { [[ "$QUIET" == true ]] || echo -e "${YELLOW}[!] $*${PLAIN}" >&2; }
ok()   { [[ "$QUIET" == true ]] || echo -e "${GREEN}[✔] $*${PLAIN}" >&2; }

usage() {
    cat <<EOF
Mihomo 非交互式一键搭建脚本

用法:
  $(basename "$0") <命令> [参数...]

命令:
  reality     搭建 VLESS-Reality (Vision) 节点
                --port <端口>       默认 443
                --uuid <UUID>       默认随机生成
                --sni <域名>        默认 hk.art.museum

  ss          搭建 Shadowsocks (2022 / 传统) 节点
                --port <端口>       默认 2022
                --method <加密>     默认 2022-blake3-aes-256-gcm
                                    可选: 2022-blake3-aes-128-gcm, 2022-blake3-aes-256-gcm,
                                          2022-blake3-chacha20-poly1305, aes-128-gcm,
                                          aes-256-gcm, chacha20-ietf-poly1305
                --password <密码>   默认随机生成 (2022 系列须为对应长度密钥的 Base64)

  vless-enc   搭建 VLESS Encryption (ML-KEM-768 抗量子) 节点
                --port <端口>       默认 40000
                --uuid <UUID>       默认随机生成

  http        搭建 HTTP 代理入站 (必须带用户名)
                --port <端口>       默认 8080
                --username <名称>   默认随机
                --password <密码>   默认随机

  socks       搭建 SOCKS5 代理入站 (同时监听 UDP)
                --port <端口>       默认 1080
                --username <名称>   默认随机
                --password <密码>   默认随机

  mixed       搭建 HTTP+SOCKS 混合入站
                --port <端口>       默认 10810
                --username <名称>   默认随机
                --password <密码>   默认随机

  tunnel      在 mihomo 里做端口转发 (不是代理节点)
                --port <端口>       默认 10816
                --target <host:port> 转发目标, 必填
                --network <列表>    默认 tcp,udp

  vmess       搭建 VMess 入站 (alterId 固定 0)
                --port <端口>       默认 16823
                --uuid <UUID>       默认随机
                --security <none|tls> 默认 none
                --ws-path <路径>    留空为 TCP
                --cert-mode <selfsign|file|acme>

  trojan      搭建 Trojan 入站 (TLS, 默认自签证书)
                --port <端口>       默认 443
                --password <密码>   默认随机
                --ws-path <路径>
                --cert-mode <selfsign|file|acme>

  hysteria2|hy2
              搭建 Hysteria2 入站 (UDP/QUIC, 不写带宽则用 BBR)
                --port <端口>       默认 443
                --username <名称>   只用于入站规则, 默认 hy2user
                --password <密码>   客户端认证用这个
                --obfs <salamander|none>
                --cert-mode <selfsign|file|acme>

  shadowquic  搭建 ShadowQUIC 入站 (需要 mihomo >= 1.19.29)
                --port <端口>       默认 443
                --dest <host:port>  JLS 上游, 默认 www.bing.com:443
                --zero-rtt <true|false>

  mieru       搭建 Mieru 入站 (需要 mihomo >= 1.19.17)
                --port <端口>       默认 2999
                --transport <TCP|UDP> 默认 TCP

  sudoku      搭建 Sudoku 入站 (需要 mihomo >= 1.19.17)
                --port <端口>       默认 443
                --key <UUID>        客户端填同一个, 默认随机

  trusttunnel 搭建 TrustTunnel 入站 (HTTP/2+HTTP/3, 需要 mihomo >= 1.19.25)
                --port <端口>       默认 443
                --congestion <bbr|cubic|new_reno>
                --cert-mode <selfsign|file|acme>

  hy2-realm|hysteria2-realm
              搭建 Hysteria2 realm 汇合服务 (不是代理节点)
                --port <端口>       默认 2080
                --token <令牌>      默认随机
                --cert-mode <none|selfsign|file|acme> 默认 none

  tuic        搭建 TUIC v5 节点 (Mihomo listener, 走 UDP/QUIC)
                --port <端口>       默认 443
                --uuid <UUID>       默认随机生成
                --password <密码>   默认随机生成, 8-128 位字母数字
                --congestion <算法> 默认 bbr, 可选 cubic / new_reno
                --alpn <列表>       默认 h3
                --udp-relay-mode <模式> 客户端 UDP 中继, 默认 native, 可选 quic
                --sni <域名或IP>    默认 tuic.local
                --cert-mode <模式>  selfsign (默认) / file / acme
                --cert <路径>       file 模式的证书 PEM
                --key <路径>        file 模式的私钥 PEM
                --domain <域名>     acme 模式必填, 同时作为 SNI
                --listen-host <IP>  默认 0.0.0.0

  anytls      搭建 AnyTLS 节点 (默认 JLS 握手伪装, 需要 mihomo >= 1.19.29)
                --port <端口>       默认 8443
                --mode <jls|tls>    默认 jls; jls 无需证书, tls 需 --cert/--key
                --dest <host:port>  JLS 回落目标, 默认 www.bing.com:443
                --sni <域名>        JLS SNI (默认由 dest 推导)，或 TLS 证书域名
                --alpn <列表>       默认 h2,http/1.1
                --password <密码>   AnyTLS 密码, 默认随机生成
                --jls-user <名称>   JLS 用户名, 默认随机生成
                --jls-password <密码> JLS 密码, 默认随机生成
                --proxy <出站名>    回落流量走哪个 proxy, 默认 DIRECT
                --rate-limit <bit/s> 回落转发限速, 0 表示不限速
                --padding-file <文件> 自定义 padding-scheme (默认用内核内置方案)
                --cert <路径>       tls 模式的证书 PEM
                --key <路径>        tls 模式的私钥 PEM

  address <地址|auto>
              设置分享链接使用的连接地址 (NAT/DDNS)，auto 表示恢复自动获取公网 IP

  realm       搭建 Realm 端口转发 (独立服务, 与 mihomo 并行)
                --port <端口>       本机监听端口, 默认 8443
                --remote <host:port> 转发目标, 必填
                --listen-host <地址> 监听地址, 默认 0.0.0.0
                --no-udp            只转发 TCP (默认 TCP+UDP 都转)
                --no-tcp            只转发 UDP
                --comment <备注>    写入配置文件的注释, 默认 realm-<port>

通用参数 (用于上面的搭建命令):
  --address <地址|auto>  搭建前先设置连接地址；auto 为自动获取公网 IP，不传则沿用当前设置
  -q, --quiet        安静模式：stdout 仅输出链接、客户端 YAML, 或 Tunnel / Realm 的转发信息
  -h, --help         显示本帮助

示例:
  $(basename "$0") reality --port 8443 --sni www.example.com --address my.ddns.net
  $(basename "$0") ss --method 2022-blake3-aes-128-gcm -q
  $(basename "$0") anytls --port 8443 --dest www.apple.com:443 -q
  $(basename "$0") tuic --port 443 --congestion bbr -q
EOF
}

normalize_address() {
    local value="$1"
    value="${value#[}"; value="${value%]}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$value" <<'PY'
import ipaddress, re, sys
value = sys.argv[1].strip()
try:
    print(ipaddress.ip_address(value).compressed)
except ValueError:
    if len(value) > 253 or not re.fullmatch(r'(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value):
        raise SystemExit(1)
    print(value.rstrip('.'))
PY
    else
        # 无 python3 时的简易校验: IPv4 / IPv6 / 域名
        if [[ "$value" =~ ^[0-9A-Fa-f:.]+$ || "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
            printf '%s\n' "${value%.}"
        else
            return 1
        fi
    fi
}

set_address() {
    local addr="$1"
    if [[ -z "$addr" || "$addr" == "auto" ]]; then
        rm -f "$ADDRESS_FILE"
        ok "已恢复为自动获取公网 IP 模式。"
        return 0
    fi
    local normalized
    normalized=$(normalize_address "$addr") || die "连接地址无效: $addr (请输入纯 IP 或域名，不要包含协议和端口)"
    printf '%s\n' "$normalized" > "$ADDRESS_FILE"
    chmod 600 "$ADDRESS_FILE"
    ok "连接地址已设置为: $normalized"
}

# 优先使用同目录下的脚本，否则从仓库下载到临时目录
TMP_DIR=""
SCRIPT_PATH=""
cleanup() { [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

resolve_script() {
    local name="$1"
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$name" ]]; then
        SCRIPT_PATH="$SCRIPT_DIR/$name"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 $name"
    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)" || die "无法创建临时目录"
    SCRIPT_PATH="$TMP_DIR/$name"
    info "正在下载 $name ..."
    curl -fsSL -o "$SCRIPT_PATH" "${BASE_URL}/${name}" || die "下载 $name 失败，请检查网络。"
    bash -n "$SCRIPT_PATH" || die "$name 未通过 Bash 语法检查，已中止。"
    chmod 0755 "$SCRIPT_PATH"
}

run_installer() {
    local script_name="$1"; shift
    local address="" args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --address)
                [[ $# -ge 2 ]] || die "参数 --address 缺少值"
                address="$2"; shift 2 ;;
            -q|--quiet) QUIET=true; args+=("--quiet"); shift ;;
            -h|--help) usage; exit 0 ;;
            *) args+=("$1"); shift ;;
        esac
    done

    [[ -n "$address" ]] && set_address "$address"

    resolve_script "$script_name"
    # 子脚本 install 模式下带参数即走非交互流程；始终带上 --port 以避免进入交互
    local has_port=false a
    for a in "${args[@]+"${args[@]}"}"; do [[ "$a" == "--port" ]] && has_port=true; done
    [[ "$has_port" == true ]] || args=("--port" "$DEFAULT_PORT" "${args[@]+"${args[@]}"}")

    bash "$SCRIPT_PATH" install "${args[@]}"
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 1; }
    local cmd="$1"; shift

    case "$cmd" in
        -h|--help|help) usage; exit 0 ;;
    esac

    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请以 root 身份运行此脚本。"

    case "$cmd" in
        reality)
            DEFAULT_PORT=443
            run_installer "install_vless_reality.sh" "$@" ;;
        ss|ss2022|shadowsocks)
            DEFAULT_PORT=2022
            run_installer "install_ss2022.sh" "$@" ;;
        vless-enc|vless-encryption|vless-pq)
            DEFAULT_PORT=40000
            run_installer "install_vless_encryption.sh" "$@" ;;
        anytls)
            DEFAULT_PORT=8443
            run_installer "install_anytls.sh" "$@" ;;
        tuic|tuic-v5|tuic5)
            DEFAULT_PORT=443
            run_installer "install_tuic.sh" "$@" ;;
        http)
            DEFAULT_PORT=8080
            run_installer "install_http.sh" "$@" ;;
        socks|socks5)
            DEFAULT_PORT=1080
            run_installer "install_socks.sh" "$@" ;;
        mixed)
            DEFAULT_PORT=10810
            run_installer "install_mixed.sh" "$@" ;;
        tunnel)
            DEFAULT_PORT=10816
            run_installer "install_tunnel.sh" "$@" ;;
        vmess)
            DEFAULT_PORT=16823
            run_installer "install_vmess.sh" "$@" ;;
        trojan)
            DEFAULT_PORT=443
            run_installer "install_trojan.sh" "$@" ;;
        hysteria2|hy2)
            DEFAULT_PORT=443
            run_installer "install_hysteria2.sh" "$@" ;;
        shadowquic)
            DEFAULT_PORT=443
            run_installer "install_shadowquic.sh" "$@" ;;
        mieru)
            DEFAULT_PORT=2999
            run_installer "install_mieru.sh" "$@" ;;
        sudoku)
            DEFAULT_PORT=443
            run_installer "install_sudoku.sh" "$@" ;;
        trusttunnel)
            DEFAULT_PORT=443
            run_installer "install_trusttunnel.sh" "$@" ;;
        hy2-realm|hysteria2-realm)
            DEFAULT_PORT=2080
            run_installer "install_hysteria2_realm.sh" "$@" ;;
        realm)
            DEFAULT_PORT=8443
            run_installer "install_realm.sh" "$@" ;;
        address)
            [[ $# -ge 1 ]] || die "用法: $(basename "$0") address <地址|auto>"
            set_address "$1" ;;
        *)
            echo -e "${RED}未知命令: $cmd${PLAIN}" >&2
            usage; exit 1 ;;
    esac
}

main "$@"
