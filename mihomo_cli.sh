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

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[96m'; PLAIN='\033[0m'
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

  anytls      搭建 AnyTLS 节点 (默认 JLS 握手伪装, 需要 mihomo >= 1.19.29)
                --port <端口>       默认 8443
                --mode <jls|tls>    默认 jls; jls 无需证书, tls 需 --cert/--key
                --dest <host:port>  JLS 回落目标, 默认 www.bing.com:443
                --sni <域名>        JLS SNI, 默认由 dest 推导
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

通用参数 (用于 reality / ss / vless-enc / anytls / realm):
  --address <地址|auto>  搭建前先设置连接地址；auto 为自动获取公网 IP，不传则沿用当前设置
  -q, --quiet        安静模式，成功时只输出分享链接，便于脚本调用
  -h, --help         显示本帮助

示例:
  $(basename "$0") reality --port 8443 --sni www.example.com --address my.ddns.net
  $(basename "$0") ss --method 2022-blake3-aes-128-gcm -q
  $(basename "$0") anytls --port 8443 --dest www.apple.com:443 -q
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
cleanup() { [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

resolve_script() {
    local name="$1"
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$name" ]]; then
        printf '%s\n' "$SCRIPT_DIR/$name"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载 $name"
    [[ -n "$TMP_DIR" ]] || TMP_DIR="$(mktemp -d)" || die "无法创建临时目录"
    local target="$TMP_DIR/$name"
    info "正在下载 $name ..."
    curl -fsSL -o "$target" "${BASE_URL}/${name}" || die "下载 $name 失败，请检查网络。"
    bash -n "$target" || die "$name 未通过 Bash 语法检查，已中止。"
    chmod 0755 "$target"
    printf '%s\n' "$target"
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

    local script_path
    script_path=$(resolve_script "$script_name")
    # 子脚本 install 模式下带参数即走非交互流程；始终带上 --port 以避免进入交互
    local has_port=false a
    for a in "${args[@]+"${args[@]}"}"; do [[ "$a" == "--port" ]] && has_port=true; done
    [[ "$has_port" == true ]] || args=("--port" "$DEFAULT_PORT" "${args[@]+"${args[@]}"}")

    bash "$script_path" install "${args[@]}"
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
