#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 DNAT 端口转发管理脚本 v1.0
# 适配环境：Debian/Ubuntu/Alpine (systemd / OpenRC)
# 依赖：iptables 或 nftables, curl, python3
# 功能：开启 IP 转发、添加/删除 DNAT 规则 (TCP+UDP)、查询规则、重放规则
# 特性：规则落盘重启不丢、支持 IPv4/IPv6 双栈、按标签精准删除绝不误伤
# ==============================================================================

# --- 全局设置 ---
set -uo pipefail
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
PLAIN='\033[0m'

# --- 仓库配置 (可用环境变量 MIHOMO_BASE_URL 覆盖) ---
BASE_URL="${MIHOMO_BASE_URL:-https://raw.githubusercontent.com/D3-3109/Install-Mihomo-Inbounds/main}"

# --- 本地路径 ---
RULES_FILE="/etc/dnat_rules.conf"       # 规则清单: 标签|协议|监听端口|目标地址|目标端口
SCRIPT_PATH="/usr/bin/mihomo-dnat"
RESTORE_SCRIPT="/usr/local/bin/dnat-restore"
SYSCTL_CONF="/etc/sysctl.d/99-dnat-forward.conf"

# --- 防火墙后端 (由 detect_backend 决定) ---
BACKEND=""
IPT4=""
IPT6=""

# --- 基础函数 ---
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

    local deps=("curl" "python3" "realpath" "sysctl")
    local missing=false dep
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || missing=true; done

    if [[ "$missing" == true ]]; then
        info "正在安装缺失依赖..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache curl python3 coreutils procps >/dev/null 2>&1 || die "安装依赖失败。"
        elif [[ "$OS_ID" =~ ^(debian|ubuntu|kali|raspbian)$ ]]; then
            apt-get update >/dev/null 2>&1 && apt-get install -y curl python3 coreutils procps >/dev/null 2>&1 || die "安装依赖失败。"
        else
            die "不支持自动安装依赖的系统: $OS_ID"
        fi
    fi
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || die "缺少必要命令: $dep"; done
}

# --- 校验函数 ---
is_valid_port()  { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
# 标签同时用作 nftables 链名片段，仅允许字母数字下划线
is_valid_label() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

is_valid_ip() {
    # 同时接受 IPv4 与 IPv6（域名请先解析成 IP 再填）
    python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$1" 2>/dev/null
}

is_ipv6() {
    python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version==6 else 1)' "$1" 2>/dev/null
}

is_ip_family_supported() {
    local ip="$1"
    is_ipv6 "$ip" || return 0
    if [[ "$BACKEND" == "nftables" ]]; then
        return 0
    fi
    if [[ -z "$IPT6" ]]; then
        warn "系统缺少 ip6tables，无法转发 IPv6 目标。"
        return 1
    fi
    if ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        warn "本机没有全局 IPv6 地址，无法转发 IPv6 目标: $ip"
        return 1
    fi
    return 0
}

# --- 后端检测：优先 iptables，其次 nftables ---
detect_backend() {
    if command -v iptables >/dev/null 2>&1; then
        BACKEND="iptables"
        IPT4="iptables"
        command -v ip6tables >/dev/null 2>&1 && IPT6="ip6tables" || IPT6=""
    elif command -v iptables-nft >/dev/null 2>&1; then
        BACKEND="iptables-nft"
        IPT4="iptables-nft"
        command -v ip6tables-nft >/dev/null 2>&1 && IPT6="ip6tables-nft" || IPT6=""
    elif command -v nft >/dev/null 2>&1; then
        BACKEND="nftables"
    else
        info "未检测到防火墙后端，正在安装 iptables..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache iptables >/dev/null 2>&1 || die "安装 iptables 失败。"
            command -v ip6tables >/dev/null 2>&1 || apk add --no-cache ip6tables >/dev/null 2>&1 || true
        else
            apt-get update >/dev/null 2>&1 && apt-get install -y iptables >/dev/null 2>&1 || die "安装 iptables 失败。"
        fi
        BACKEND="iptables"
        IPT4="iptables"
        command -v ip6tables >/dev/null 2>&1 && IPT6="ip6tables" || IPT6=""
    fi
    info "防火墙后端: ${CYAN}${BACKEND}${PLAIN}"
}

# --- 工具封装 ---
ipt_tool_for() {
    # 依据目标地址族选择 iptables / ip6tables
    if is_ipv6 "$1"; then
        [[ -n "$IPT6" ]] || die "系统缺少 ip6tables，无法操作 IPv6 规则。"
        printf '%s\n' "$IPT6"
    else
        printf '%s\n' "$IPT4"
    fi
}

format_dnat_target() {
    # DNAT 目标表示: v4 -> addr:port, v6 -> [addr]:port
    if is_ipv6 "$1"; then
        printf '[%s]:%s\n' "$1" "$2"
    else
        printf '%s:%s\n' "$1" "$2"
    fi
}

expand_protos() {
    # 输出空格分隔的协议列表，便于 read -a 拆分
    case "$1" in
        tcp)  printf 'tcp' ;;
        udp)  printf 'udp' ;;
        both) printf 'tcp udp' ;;
        *)    return 1 ;;
    esac
}

# --- IP 转发开启/关闭 ---
enable_ip_forward() {
    local changed=""
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" != "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        changed="IPv4"
    fi
    if [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)" != "1" ]]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
        changed="${changed:+$changed }IPv6"
    fi
    mkdir -p /etc/sysctl.d
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > "$SYSCTL_CONF"
    if [[ -n "$changed" ]]; then
        success "已开启 IP 转发 (${changed})"
    else
        info "IP 转发已处于开启状态。"
    fi
}

disable_ip_forward() {
    if [[ "$(rules_count)" -ne 0 ]]; then
        warn "仍存在 DNAT 规则，请先删除全部规则后再关闭 IP 转发。"
        return 1
    fi
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
    [[ -f "$SYSCTL_CONF" ]] && printf 'net.ipv4.ip_forward = 0\nnet.ipv6.conf.all.forwarding = 0\n' > "$SYSCTL_CONF"
    success "已关闭 IP 转发。"
}

# --- 规则清单读写 ---
save_rule() {
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RULES_FILE"
    chmod 600 "$RULES_FILE"
}

rules_count() {
    [[ -f "$RULES_FILE" ]] || { echo 0; return; }
    local n
    n=$(grep -cE '^[^#[:space:]]' "$RULES_FILE" 2>/dev/null || true)
    echo "${n:-0}"
}

rule_label_exists() {
    [[ -f "$RULES_FILE" ]] || return 1
    awk -F'|' -v l="$1" '$1 == l { found=1 } END { exit(found?0:1) }' "$RULES_FILE"
}

lport_exists() {
    [[ -f "$RULES_FILE" ]] || return 1
    awk -F'|' -v p="$1" '$3 == p { found=1 } END { exit(found?0:1) }' "$RULES_FILE"
}

port_in_use() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -Htuln 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | grep -qx "$1"
}

# --- 底层规则应用 (幂等，可重复执行) ---
# 用法: apply_rule <标签> <监听端口> <目标地址> <目标端口> <协议...>
apply_rule() {
    local label="$1" lport="$2" dest="$3" dport="$4"; shift 4
    local protos=("$@")
    local target tool pp nfproto fam_expr chain

    if [[ "$BACKEND" == "nftables" ]]; then
        target=$(format_dnat_target "$dest" "$dport")
        if is_ipv6 "$dest"; then
            nfproto="ipv6"; fam_expr="ip6 daddr ${dest}"
        else
            nfproto="ipv4"; fam_expr="ip daddr ${dest}"
        fi
        # 每条规则独立 chain，整体重建保证幂等
        nft list table inet dnat_mihomo >/dev/null 2>&1 || nft add table inet dnat_mihomo || die "创建 nftables 表失败。"
        for chain in "pre_${label}" "post_${label}"; do
            if nft list chain inet dnat_mihomo "$chain" >/dev/null 2>&1; then
                nft flush chain inet dnat_mihomo "$chain" || die "清空 nftables 链失败: $chain"
                nft delete chain inet dnat_mihomo "$chain" || die "删除 nftables 链失败: $chain"
            fi
        done
        nft add chain inet dnat_mihomo "pre_${label}" '{ type nat hook prerouting priority -100 ; }' || die "创建 PREROUTING 链失败 (内核可能低于 4.18，不支持 inet NAT)。"
        nft add chain inet dnat_mihomo "post_${label}" '{ type nat hook postrouting priority 100 ; }' || die "创建 POSTROUTING 链失败。"
        for pp in "${protos[@]}"; do
            nft add rule inet dnat_mihomo "pre_${label}" meta nfproto "${nfproto}" "${pp}" dport "${lport}" dnat to "${target}" || die "添加 nftables DNAT 规则失败。"
            # POSTROUTING masquerade 保证回程路由正确
            nft add rule inet dnat_mihomo "post_${label}" meta nfproto "${nfproto}" "${fam_expr}" "${pp}" dport "${dport}" masquerade || die "添加 nftables MASQUERADE 规则失败。"
        done
    else
        target=$(format_dnat_target "$dest" "$dport")
        tool=$(ipt_tool_for "$dest")
        for pp in "${protos[@]}"; do
            if ! "$tool" -t nat -C PREROUTING -p "$pp" --dport "$lport" -j DNAT --to-destination "$target" 2>/dev/null; then
                "$tool" -t nat -A PREROUTING -p "$pp" --dport "$lport" -j DNAT --to-destination "$target" || die "添加 iptables DNAT 规则失败。"
            fi
            if ! "$tool" -t nat -C POSTROUTING -d "$dest" -p "$pp" --dport "$dport" -j MASQUERADE 2>/dev/null; then
                "$tool" -t nat -A POSTROUTING -d "$dest" -p "$pp" --dport "$dport" -j MASQUERADE || die "添加 iptables MASQUERADE 规则失败。"
            fi
        done
    fi
}

# 用法: remove_kernel_rule <标签> <监听端口> <目标地址> <目标端口> <协议...>
remove_kernel_rule() {
    local label="$1" lport="$2" dest="$3" dport="$4"; shift 4
    local protos=("$@")
    local target tool pp chain

    if [[ "$BACKEND" == "nftables" ]]; then
        for chain in "pre_${label}" "post_${label}"; do
            if nft list chain inet dnat_mihomo "$chain" >/dev/null 2>&1; then
                nft flush chain inet dnat_mihomo "$chain" || { warn "清空 nftables 链失败: $chain"; return 1; }
                nft delete chain inet dnat_mihomo "$chain" || { warn "删除 nftables 链失败: $chain"; return 1; }
            fi
        done
    else
        target=$(format_dnat_target "$dest" "$dport")
        tool=$(ipt_tool_for "$dest")
        for pp in "${protos[@]}"; do
            while "$tool" -t nat -C PREROUTING -p "$pp" --dport "$lport" -j DNAT --to-destination "$target" 2>/dev/null; do
                "$tool" -t nat -D PREROUTING -p "$pp" --dport "$lport" -j DNAT --to-destination "$target" || return 1
            done
            # 其他规则可能共用同一目标和协议的 MASQUERADE
            if ! awk -F'|' -v l="$label" -v d="$dest" -v p="$dport" -v proto="$pp" \
                '$1 !~ /^[[:space:]]*(#|$)/ && $1 != l && $4 == d && $5 == p && ($2 == proto || $2 == "both") { found=1 } END { exit(found?0:1) }' "$RULES_FILE"; then
                while "$tool" -t nat -C POSTROUTING -d "$dest" -p "$pp" --dport "$dport" -j MASQUERADE 2>/dev/null; do
                    "$tool" -t nat -D POSTROUTING -d "$dest" -p "$pp" --dport "$dport" -j MASQUERADE || return 1
                done
            fi
        done
    fi
    return 0
}

# 检查规则当前是否在内核中生效
check_rule_live() {
    local label="$1" lport="$2" dest="$3" dport="$4" proto="$5"
    local target tool
    if [[ "$BACKEND" == "nftables" ]]; then
        nft list chain inet dnat_mihomo "pre_${label}" 2>/dev/null | grep -q "dport ${lport}"
    else
        target=$(format_dnat_target "$dest" "$dport")
        tool=$(ipt_tool_for "$dest")
        "$tool" -t nat -C PREROUTING -p "$proto" --dport "$lport" -j DNAT --to-destination "$target" 2>/dev/null
    fi
}

# --- 开机恢复：生成恢复脚本 + 注册系统服务 ---
persist_rules() {
    local label proto lport dest dport tool target pp nfproto fam_expr
    local protos=()

    {
        echo '#!/bin/bash'
        echo '# 由 mihomo-dnat (install_dnat.sh) 生成，开机时重放 DNAT 规则'
        echo '# 请通过 mihomo-dnat 菜单管理，勿手动编辑'
        echo 'sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true'
        echo 'sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true'
        if [[ "$BACKEND" == "nftables" ]]; then
            echo 'nft list table inet dnat_mihomo >/dev/null 2>&1 || nft add table inet dnat_mihomo || exit 1'
        fi
    } > "$RESTORE_SCRIPT"

    while IFS='|' read -r label proto lport dest dport; do
        [[ -z "${label// }" || "$label" =~ ^[[:space:]]*# ]] && continue
        read -r -a protos <<< "$(expand_protos "$proto" 2>/dev/null)" || true
        [[ ${#protos[@]} -gt 0 ]] || continue

        if [[ "$BACKEND" == "nftables" ]]; then
            target=$(format_dnat_target "$dest" "$dport")
            if is_ipv6 "$dest"; then
                nfproto="ipv6"; fam_expr="ip6 daddr ${dest}"
            else
                nfproto="ipv4"; fam_expr="ip daddr ${dest}"
            fi
            echo "if nft list chain inet dnat_mihomo pre_${label} >/dev/null 2>&1; then nft flush chain inet dnat_mihomo pre_${label} || exit 1; else nft add chain inet dnat_mihomo pre_${label} '{ type nat hook prerouting priority -100 ; }' || exit 1; fi" >> "$RESTORE_SCRIPT"
            echo "if nft list chain inet dnat_mihomo post_${label} >/dev/null 2>&1; then nft flush chain inet dnat_mihomo post_${label} || exit 1; else nft add chain inet dnat_mihomo post_${label} '{ type nat hook postrouting priority 100 ; }' || exit 1; fi" >> "$RESTORE_SCRIPT"
            for pp in "${protos[@]}"; do
                echo "nft add rule inet dnat_mihomo pre_${label} meta nfproto ${nfproto} ${pp} dport ${lport} dnat to ${target} || exit 1" >> "$RESTORE_SCRIPT"
                echo "nft add rule inet dnat_mihomo post_${label} meta nfproto ${nfproto} ${fam_expr} ${pp} dport ${dport} masquerade || exit 1" >> "$RESTORE_SCRIPT"
            done
        else
            target=$(format_dnat_target "$dest" "$dport")
            tool=$(ipt_tool_for "$dest")
            for pp in "${protos[@]}"; do
                echo "${tool} -t nat -C PREROUTING -p ${pp} --dport ${lport} -j DNAT --to-destination ${target} 2>/dev/null || ${tool} -t nat -A PREROUTING -p ${pp} --dport ${lport} -j DNAT --to-destination ${target}" >> "$RESTORE_SCRIPT"
                echo "${tool} -t nat -C POSTROUTING -d ${dest} -p ${pp} --dport ${dport} -j MASQUERADE 2>/dev/null || ${tool} -t nat -A POSTROUTING -d ${dest} -p ${pp} --dport ${dport} -j MASQUERADE" >> "$RESTORE_SCRIPT"
            done
        fi
    done < "$RULES_FILE"

    echo 'exit 0' >> "$RESTORE_SCRIPT"
    chmod 700 "$RESTORE_SCRIPT"

    # 注册开机服务 (systemd / OpenRC)
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/dnat-mihomo.service <<EOF
[Unit]
Description=Mihomo DNAT rules restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RESTORE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable dnat-mihomo.service >/dev/null 2>&1 || true
    elif command -v rc-update >/dev/null 2>&1; then
        cat > /etc/init.d/dnat-mihomo <<EOF
#!/sbin/openrc-run
description="Mihomo DNAT rules restore"
command="${RESTORE_SCRIPT}"
EOF
        chmod +x /etc/init.d/dnat-mihomo
        rc-update add dnat-mihomo default >/dev/null 2>&1 || true
    else
        warn "未检测到 systemd/OpenRC，规则将不会开机自动恢复。"
    fi
}

unpersist_rules() {
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl disable dnat-mihomo.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/dnat-mihomo.service
        systemctl daemon-reload
    fi
    if [[ -f /etc/init.d/dnat-mihomo ]]; then
        rc-update del dnat-mihomo default >/dev/null 2>&1 || true
        rm -f /etc/init.d/dnat-mihomo
    fi
    rm -f "$RESTORE_SCRIPT"
}

sync_persist() {
    if [[ "$(rules_count)" -eq 0 ]]; then
        unpersist_rules
    else
        persist_rules
    fi
}

# --- 功能 1: 添加 DNAT 规则 ---
add_dnat_rule() {
    echo "================ 添加 DNAT 端口转发 ================"
    read -rp "请输入规则标签 (唯一标识, 如 relay_443): " label
    is_valid_label "$label" || die "标签无效：仅允许字母、数字和下划线。"
    rule_label_exists "$label" && die "标签已存在: $label"

    read -rp "请输入协议 (tcp/udp/both, 默认 both): " proto
    proto="${proto:-both}"
    [[ "$proto" =~ ^(tcp|udp|both)$ ]] || die "协议无效，仅支持 tcp / udp / both。"

    read -rp "请输入本机监听端口 (1-65535): " lport
    is_valid_port "$lport" || die "监听端口无效。"
    port_in_use "$lport" && warn "警告：端口 ${lport} 已被本机服务占用，转发可能不生效！"
    lport_exists "$lport" && warn "警告：端口 ${lport} 已被其他 DNAT 规则使用，两条规则同时命中时先添加者优先。"

    read -rp "请输入目标地址 (IPv4/IPv6，暂不支持域名): " dest
    is_valid_ip "$dest" || die "目标地址无效（请填写纯 IP，域名请先自行解析）。"
    is_ip_family_supported "$dest" || die "目标地址族不受支持。"

    read -rp "请输入目标端口 (1-65535): " dport
    is_valid_port "$dport" || die "目标端口无效。"

    echo "-------------------------------------------"
    echo "  标签:     $label"
    echo "  协议:     $proto"
    echo "  监听端口: $lport"
    echo "  目标:     ${dest}:${dport}"
    echo "-------------------------------------------"
    read -rp "确认添加? [y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消。"; return 0; }

    enable_ip_forward

    local protos=()
    read -r -a protos <<< "$(expand_protos "$proto")"
    apply_rule "$label" "$lport" "$dest" "$dport" "${protos[@]}"
    save_rule "$label" "$proto" "$lport" "$dest" "$dport"
    sync_persist

    # 获取本机公网 IP 用于提示（优先取 mihomo 连接地址设置）
    local tip_addr
    tip_addr=$(get_public_ip)
    echo
    success "DNAT 规则添加成功！"
    [[ -n "$tip_addr" ]] && echo -e "  客户端连接地址: ${CYAN}${tip_addr}:${lport}${PLAIN}"
    echo "  出流量已配置 MASQUERADE，回程路由正常；规则已落盘，重启不丢失。"
    pause
}

get_public_ip() {
    local addr_file="/root/inbound_address.txt"
    if [[ -f "$addr_file" ]]; then
        head -n1 "$addr_file" 2>/dev/null
        return
    fi
    local ip4 ip6
    ip4=$(ip -4 addr show scope global 2>/dev/null | grep -oE 'inet [0-9a-f.:]+' | head -n1 | awk '{print $2}' | cut -d/ -f1)
    [[ -n "$ip4" ]] && { echo "$ip4"; return; }
    ip6=$(ip -6 addr show scope global 2>/dev/null | grep -oE 'inet6 [0-9a-f:]+' | head -n1 | awk '{print $2}' | cut -d/ -f1)
    echo "$ip6"
}

# --- 功能 2: 删除 DNAT 规则 ---
delete_dnat_rule() {
    local count
    count=$(rules_count)
    [[ "$count" -eq 0 ]] && { warn "当前没有任何 DNAT 规则。"; pause; return 0; }

    echo "================ 当前 DNAT 规则 ================"
    list_rules_table
    echo "-----------------------------------------------"
    read -rp "请输入要删除的规则标签 (all=全部删除): " label

    local l p lp d dp tmp failed=0
    local protos=()

    if [[ "$label" == "all" ]]; then
        read -rp "确认删除全部 ${count} 条规则? [y/N]: " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消。"; return 0; }
        while IFS='|' read -r l p lp d dp; do
            [[ -z "${l// }" || "$l" =~ ^[[:space:]]*# ]] && continue
            read -r -a protos <<< "$(expand_protos "$p" 2>/dev/null)" || true
            if [[ ${#protos[@]} -eq 0 ]] || ! remove_kernel_rule "$l" "$lp" "$d" "$dp" "${protos[@]}"; then
                warn "删除 DNAT 规则失败，已保留清单记录: $l"
                failed=1
                continue
            fi
            tmp=$(mktemp) || die "无法创建临时文件"
            awk -F'|' -v l="$l" '$1 != l' "$RULES_FILE" > "$tmp"
            mv -f "$tmp" "$RULES_FILE"
            chmod 600 "$RULES_FILE"
        done < "$RULES_FILE"
        if [[ "$BACKEND" == "nftables" && "$failed" -eq 0 ]]; then
            if nft list table inet dnat_mihomo >/dev/null 2>&1 && ! nft delete table inet dnat_mihomo; then
                warn "删除 nftables 表失败: dnat_mihomo"
                failed=1
            fi
        fi
        sync_persist
        if [[ "$failed" -eq 0 ]]; then
            success "已删除全部 DNAT 规则。"
        else
            warn "部分 DNAT 规则或 nftables 表未能删除。"
        fi
        pause
        return "$failed"
    fi

    rule_label_exists "$label" || die "标签不存在: $label"

    local line
    line=$(awk -F'|' -v l="$label" '$1 == l {print; exit}' "$RULES_FILE")
    IFS='|' read -r l p lp d dp <<< "$line"
    echo "-------------------------------------------"
    echo "  标签:     $l"
    echo "  协议:     $p"
    echo "  监听端口: $lp"
    echo "  目标:     ${d}:${dp}"
    echo "-------------------------------------------"
    read -rp "确认删除? [y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || { info "已取消。"; return 0; }

    read -r -a protos <<< "$(expand_protos "$p" 2>/dev/null)" || true
    if [[ ${#protos[@]} -eq 0 ]] || ! remove_kernel_rule "$l" "$lp" "$d" "$dp" "${protos[@]}"; then
        warn "删除 DNAT 规则失败，已保留清单记录: $label"
        pause
        return 1
    fi

    # 从清单移除该行
    tmp=$(mktemp) || die "无法创建临时文件"
    awk -F'|' -v l="$label" '$1 != l' "$RULES_FILE" > "$tmp"
    mv -f "$tmp" "$RULES_FILE"
    chmod 600 "$RULES_FILE"

    sync_persist
    success "已删除 DNAT 规则: $label"
    pause
}

# --- 功能 3: 查询规则列表 (含内核生效状态) ---
list_rules_table() {
    if [[ ! -f "$RULES_FILE" ]] || ! grep -qE '^[^#[:space:]]' "$RULES_FILE"; then
        echo -e "  ${YELLOW}(无规则)${PLAIN}"
        return
    fi
    printf "  %-4s %-18s %-6s %-10s %-28s\n" "ID" "标签" "协议" "监听端口" "目标地址:端口"
    echo "  ------------------------------------------------------------------"
    local idx=0 label proto lport dest dport
    while IFS='|' read -r label proto lport dest dport; do
        [[ -z "${label// }" || "$label" =~ ^[[:space:]]*# ]] && continue
        idx=$((idx+1))
        printf "  %-4s %-18s %-6s %-10s %-28s\n" "$idx" "$label" "$proto" "$lport" "${dest}:${dport}"
    done < "$RULES_FILE"
}

query_rules() {
    echo "================ DNAT 转发规则列表 ================"
    list_rules_table
    echo
    if [[ "$(rules_count)" -gt 0 ]]; then
        info "内核生效状态检查:"
        local label proto lport dest dport pp state
        local protos=()
        while IFS='|' read -r label proto lport dest dport; do
            [[ -z "${label// }" || "$label" =~ ^[[:space:]]*# ]] && continue
            read -r -a protos <<< "$(expand_protos "$proto" 2>/dev/null)" || true
            [[ ${#protos[@]} -gt 0 ]] || continue
            for pp in "${protos[@]}"; do
                if check_rule_live "$label" "$lport" "$dest" "$dport" "$pp"; then
                    state="${GREEN}生效${PLAIN}"
                else
                    state="${RED}未生效${PLAIN}"
                fi
                echo -e "  ${label}/${pp}:${lport} -> ${dest}:${dport}  [${state}]"
            done
        done < "$RULES_FILE"
        echo -e "  (${YELLOW}未生效${PLAIN} 的规则可通过选项 4 \"重新应用全部规则\" 重放)"
    fi
    pause
}

# --- 功能 4: 重新应用全部规则 (Reload) ---
replay_rules() {
    local count
    count=$(rules_count)
    [[ "$count" -eq 0 ]] && { warn "当前没有任何 DNAT 规则。"; pause; return 0; }

    enable_ip_forward
    local label proto lport dest dport
    local protos=()
    while IFS='|' read -r label proto lport dest dport; do
        [[ -z "${label// }" || "$label" =~ ^[[:space:]]*# ]] && continue
        read -r -a protos <<< "$(expand_protos "$proto" 2>/dev/null)" || true
        [[ ${#protos[@]} -gt 0 ]] || continue
        apply_rule "$label" "$lport" "$dest" "$dport" "${protos[@]}"
    done < "$RULES_FILE"
    sync_persist
    success "已重新应用 ${count} 条 DNAT 规则。"
    pause
}

# --- 功能 5: 开启/关闭 IP 转发 ---
toggle_ip_forward() {
    echo "================ IP 转发开关 ================"
    local v4 v6
    v4=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
    v6=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "?")
    echo "  IPv4 转发: $v4"
    echo "  IPv6 转发: $v6"
    echo "-------------------------------------------"
    echo "  1. 开启 IP 转发 (v4+v6)"
    echo "  2. 关闭 IP 转发 (需先删光规则)"
    read -rp "选择 [1-2]: " c
    case "$c" in
        1) enable_ip_forward ;;
        2) disable_ip_forward || true ;;
        *) warn "无效输入。" ;;
    esac
    pause
}

# --- 功能 6: 更新脚本 ---
update_script() {
    info "正在拉取最新版本脚本..."
    local update_url="${BASE_URL}/install_dnat.sh"
    local tmp_file
    tmp_file="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")" || die "无法创建临时文件"
    if curl -fsSL "$update_url" -o "$tmp_file" && bash -n "$tmp_file" && chmod 0755 "$tmp_file" && mv -f "$tmp_file" "$SCRIPT_PATH"; then
        info "脚本更新成功，即将退出，请重新运行。"
        exit 0
    else
        rm -f "$tmp_file"
        die "脚本更新失败。"
    fi
}

# --- 自我安装 ---
install_self() {
    local current_path
    current_path="$(realpath "$0")"
    if [[ "$current_path" != "$SCRIPT_PATH" ]]; then
        info "正在安装脚本到 $SCRIPT_PATH ..."
        cp "$current_path" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        info "脚本安装完成，请在命令行直接输入 mihomo-dnat 使用。"
        sleep 1
        exec "$SCRIPT_PATH" "$@"
    fi
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "================================================="
    echo "       Caesar 蜜汁 DNAT 端口转发管理脚本 v1.0    "
    echo "================================================="
    echo
    echo "  1. 添加 DNAT 端口转发 (TCP+UDP)"
    echo "  2. 删除 DNAT 转发规则"
    echo "  3. 查询已有规则列表 (含内核状态)"
    echo "  4. 重新应用全部规则 (Reload)"
    echo "  5. 开启/关闭 IP 转发"
    echo "  6. 更新脚本"
    echo "  0. 退出脚本"
    echo "================================================="
    read -rp " 请输入选项 [0-6]: " num

    case "$num" in
        1) add_dnat_rule ;;
        2) delete_dnat_rule ;;
        3) query_rules ;;
        4) replay_rules ;;
        5) toggle_ip_forward ;;
        6) update_script ;;
        0) echo -e "${GREEN}感谢使用此脚本，再见！${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效输入。${PLAIN}"; sleep 1 ;;
    esac
}

# --- 主程序入口 ---
main() {
    pre_check
    detect_backend
    install_self "$@"

    while true; do
        show_menu
    done
}

main "$@"
