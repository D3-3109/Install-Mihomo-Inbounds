#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 Mihomo 配置还原工具
# 功能：从 URL、手动粘贴或本地备份归档还原，并提供测试功能
# ==============================================================================

# --- 全局设置 ---
set -uo pipefail
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
PLAIN='\033[0m'

# --- 路径配置 ---
SCRIPT_PATH="/usr/bin/mihomo-restore"
CONFIG_DIR="/usr/local/etc/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CLIENT_STATE_DIR="/root"
MIHOMO_BIN="/usr/local/bin/mihomo"

# --- Github 更新地址 ---
GITHUB_USER="D3-3109"
GITHUB_REPO="Install-Mihomo-Inbounds"
GITHUB_BRANCH="main"
UPDATE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}/mihomo_restore.sh"

# --- 基础函数 ---
die() { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO] $*${PLAIN}"; }
warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }

validate_config_file() {
    local candidate="$1" config_dir="${2:-$CONFIG_DIR}"
    if [[ ! -s "$candidate" ]]; then
        warn "配置文件为空。"
        return 1
    fi
    if ! grep -qE "^(mode:|listeners:|rules:|proxies:|log-level:)" "$candidate"; then
        warn "文件不具备常见的 Mihomo 顶级配置项。"
        return 1
    fi
    if [[ -x "$MIHOMO_BIN" ]]; then
        if ! "$MIHOMO_BIN" -t -d "$config_dir" -f "$candidate"; then
            warn "Mihomo 配置测试失败，拒绝覆盖正式配置。"
            return 1
        fi
    else
        warn "Mihomo 核心不存在，只完成了基础格式检查。"
    fi
}

install_config_file() {
    local candidate="$1"
    local backup_file=""
    local staged_file
    if [[ -f "$CONFIG_FILE" ]]; then
        backup_file=$(mktemp "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
        cp "$CONFIG_FILE" "$backup_file" || { rm -f "$backup_file"; return 1; }
        chmod 600 "$backup_file"
        info "检测到旧配置，已自动备份为: $backup_file"
    fi
    staged_file=$(mktemp "${CONFIG_DIR}/.config.restore.XXXXXX") || return 1
    if ! install -m 0600 "$candidate" "$staged_file" || ! mv -f "$staged_file" "$CONFIG_FILE"; then
        rm -f "$staged_file"
        return 1
    fi
}

download_script() {
    local url="$1" target="$2" tmp_file
    tmp_file="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    if ! curl -fsSL -o "$tmp_file" "$url" || ! bash -n "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    if ! chmod 0755 "$tmp_file" || ! mv -f "$tmp_file" "$target"; then
        rm -f "$tmp_file"
        return 1
    fi
}

# --- 权限与依赖检测 ---
pre_check() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请以 root 身份运行此脚本。"
    
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR"
    fi

    local deps=("curl" "nano" "bash" "install" "mktemp" "realpath")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing_deps[*]} ..."
        if [[ -f /etc/alpine-release ]]; then
            apk update && apk add --no-cache curl nano bash coreutils
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y curl nano bash coreutils
        else
            die "无法检测系统包管理器，请手动安装: ${missing_deps[*]}"
        fi
    fi
    local dep
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || die "缺少必要命令: $dep"; done
}

# --- 自我安装 ---
install_self() {
    local current_path
    current_path="$(realpath "$0")"
    
    if [[ "$current_path" != "$SCRIPT_PATH" ]]; then
        info "正在安装脚本到 $SCRIPT_PATH ..."
        cp "$current_path" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        info "安装完成！以后可以在终端直接输入 ${CYAN}mihomo-restore${PLAIN} 使用。"
        sleep 1
        exec "$SCRIPT_PATH" "$@"
    fi
}

# --- 功能 1: 从 URL 还原 ---
restore_from_url() {
    echo "================ 从 URL 还原配置 ================"
    echo "请输入 config.yaml 的直链下载地址 (例如: https://example.com/backup.yaml)"
    read -rp "地址: " url
    
    if [[ -z "$url" ]]; then
        warn "地址不能为空。"
        return
    fi

    info "正在下载配置文件..."
    local tmp_file
    tmp_file="$(mktemp)"
    
    if curl -fsSL -o "$tmp_file" "$url"; then
        if validate_config_file "$tmp_file" && install_config_file "$tmp_file"; then
            rm -f "$tmp_file"
            info "新配置文件已成功下载并保存到: $CONFIG_FILE"
        else
            warn "新配置校验或安装失败，原配置未被覆盖。"
            rm -f "$tmp_file"
        fi
    else
        rm -f "$tmp_file"
        die "下载失败，请检查 URL 或网络连接。"
    fi
    
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

# --- 功能 2: 手动粘贴 ---
restore_manual() {
    echo "================ 手动粘贴配置 ================"

    local tmp_file
    tmp_file="$(mktemp)" || { warn "无法创建临时文件。"; return; }
    if [[ -f "$CONFIG_FILE" ]]; then cp "$CONFIG_FILE" "$tmp_file"; fi

    info "即将打开 nano 编辑器..."
    info "请将您的 config.yaml 内容粘贴进去；保存后会先校验，再决定是否覆盖。"
    info "操作提示: 粘贴后按 Ctrl+O 保存 (回车确认)，然后 Ctrl+X 退出。"
    echo
    read -n 1 -s -r -p "按任意键开始编辑..." || true
    
    nano "$tmp_file"
    
    if validate_config_file "$tmp_file" && install_config_file "$tmp_file"; then
        info "编辑后的配置已通过检查并保存。"
    else
        warn "编辑内容为空、无效或安装失败，原配置未被覆盖。"
    fi
    rm -f "$tmp_file"
    
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

# --- 功能 3: 试运行测试 ---
test_config() {
    echo "================ 测试配置文件 ================"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "配置文件不存在: $CONFIG_FILE"
    fi
    
    if [[ ! -f "$MIHOMO_BIN" ]]; then
        die "Mihomo 核心未找到: $MIHOMO_BIN，无法测试。"
    fi

    info "正在执行: mihomo -t -d $CONFIG_DIR"
    echo "------------------------------------------------"
    
    local ret=0
    "$MIHOMO_BIN" -t -d "$CONFIG_DIR" || ret=$?
    
    echo "------------------------------------------------"
    if [[ $ret -eq 0 ]]; then
        echo -e "${GREEN}✔ 配置文件测试通过！Mihomo 可以正常启动。${PLAIN}"
        echo -e "提示: 如果需要立即应用，请手动重启 Mihomo (systemctl restart mihomo 或 rc-service mihomo restart)"
    else
        echo -e "${RED}✖ 配置文件有错误！请检查上方报错信息。${PLAIN}"
    fi
    
    echo
    echo "将在 30 秒后自动返回主菜单，或按任意键立即返回..."
    read -t 30 -n 1 -s -r || true
}

# --- 功能 4: 更新脚本 ---
update_script() {
    info "正在检查更新..."
    
    if download_script "$UPDATE_URL" "$SCRIPT_PATH"; then
        info "脚本更新成功！正在重新加载..."
        sleep 1
        exec "$SCRIPT_PATH"
    else
        die "更新失败，请检查网络或 Github 仓库地址。"
    fi
}

# 与统一卸载脚本使用相同的归档布局。
backup_mihomo_archive() (
    local cfg_dir="$1" state_dir="$2" archive="$3" tmp file
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
    if ! tar -czf "$archive" -C "$tmp" "${entries[@]}" || ! chmod 600 "$archive"; then
        rm -f -- "$archive"
        return 1
    fi
)

# --- 功能 5: 从本地归档还原 ---
restore_archive() (
    local archive="$1" tmp member backup previous="" file target failed=false
    [[ -f "$archive" ]] || { warn "归档文件不存在：$archive"; return 1; }
    umask 077
    tmp=$(mktemp -d) || { warn "无法创建临时目录。"; return 1; }
    trap 'rm -rf -- "$tmp"' EXIT
    if ! tar -tzf "$archive" > "$tmp/list"; then
        warn "无法读取 tar.gz 归档。"
        return 1
    fi
    while IFS= read -r member; do
        case "$member" in
            /*|../*|*/../*|*/..) warn "归档包含不安全的路径：$member"; return 1 ;;
        esac
    done < "$tmp/list"
    if ! tar -xzf "$archive" -C "$tmp" || [[ ! -d "$tmp/mihomo" || -L "$tmp/mihomo" ]]; then
        warn "归档解压失败，或不包含 mihomo/ 目录。"
        return 1
    fi
    if [[ ! -s "$tmp/mihomo/config.yaml" ]] || ! grep -qE '^(mode:|listeners:|rules:|proxies:|log-level:)' "$tmp/mihomo/config.yaml"; then
        warn "归档中的 config.yaml 为空或不具备常见的 Mihomo 顶级配置项。"
        return 1
    fi
    if [[ -e "$tmp/client-state" && ( ! -d "$tmp/client-state" || -L "$tmp/client-state" ) ]]; then
        warn "归档中的 client-state 不是普通目录。"
        return 1
    fi

    backup=$(mktemp "${CLIENT_STATE_DIR}/mihomo-restore-before-$(date +%Y%m%d-%H%M%S).XXXXXX.tar.gz") || return 1
    if ! backup_mihomo_archive "$CONFIG_DIR" "$CLIENT_STATE_DIR" "$backup"; then
        rm -f -- "$backup"
        warn "备份现有配置和客户端状态失败，未执行恢复。"
        return 1
    fi
    info "现有配置及客户端状态已备份：$backup"

    if [[ -d "$CONFIG_DIR" ]]; then
        previous=$(mktemp -d "${CONFIG_DIR}.previous.XXXXXX") || return 1
        rmdir "$previous" || return 1
        if ! mv -- "$CONFIG_DIR" "$previous"; then
            warn "无法暂存现有配置，未执行恢复。"
            return 1
        fi
    fi
    if ! cp -a "$tmp/mihomo" "$CONFIG_DIR" || ! validate_config_file "$CONFIG_FILE"; then
        rm -rf -- "$CONFIG_DIR"
        if [[ -n "$previous" ]] && ! mv -- "$previous" "$CONFIG_DIR"; then
            warn "原配置自动还原失败，请从 $backup 或 $previous 恢复。"
        else
            warn "归档配置安装或校验失败，已恢复原配置。"
        fi
        return 1
    fi
    [[ -n "$previous" ]] && rm -rf -- "$previous"

    if [[ -d "$tmp/client-state" ]]; then
        for file in "$tmp/client-state"/mihomo_ss_link_*.txt \
                    "$tmp/client-state"/mihomo_vless_reality_link_*.txt \
                    "$tmp/client-state"/mihomo_reality_pubkey_*.txt \
                    "$tmp/client-state"/mihomo_vless_encryption_link_*.txt \
                    "$tmp/client-state"/mihomo_vless_encryption_client_key_*.txt \
                    "$tmp/client-state"/mihomo_anytls_link_*.txt \
                    "$tmp/client-state"/mihomo_anytls_node_*.json \
                    "$tmp/client-state"/mihomo_anytls_proxies_*.yaml \
                    "$tmp/client-state"/mihomo_tuic_link_*.txt \
                    "$tmp/client-state"/mihomo_tuic_node_*.json \
                    "$tmp/client-state"/inbound_address.txt; do
            [[ -e "$file" || -L "$file" ]] || continue
            target="$CLIENT_STATE_DIR/${file##*/}"
            # 地址由 Realm/Snell 共用，迁移到另一台机器时优先保留现有设置。
            if [[ "${file##*/}" == "inbound_address.txt" && -e "$target" ]]; then
                info "保留当前连接地址：$target"
                continue
            fi
            if [[ ! -f "$file" || -L "$file" ]] || ! install -m 0600 -- "$file" "$target"; then
                warn "客户端状态恢复失败：${file##*/}"
                failed=true
            fi
        done
    else
        info "这是不含客户端状态的旧备份，现有客户端状态保持不变。"
    fi
    if $failed; then
        warn "配置已恢复，部分客户端状态未恢复；原有状态备份在 $backup。"
        return 1
    fi
    info "归档恢复完成。请按需手动重启 Mihomo（systemctl restart mihomo 或 rc-service mihomo restart）。"
)

restore_from_archive() {
    local archive
    echo "================ 从本地备份归档还原 ================"
    read -r -p "请输入本地 .tar.gz 路径: " archive
    if [[ -z "$archive" ]]; then
        warn "路径不能为空。"
        return
    fi
    restore_archive "$archive" || true
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}       Caesar 蜜汁 Mihomo 配置还原工具            ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 从 URL 下载 config.yaml"
    echo -e "  ${GREEN}2.${PLAIN} 手动粘贴 config.yaml (Nano)"
    echo -e "  ${YELLOW}3.${PLAIN} 试运行测试配置文件 (Debug)"
    echo -e "  ${CYAN}4.${PLAIN} 更新此还原脚本"
    echo -e "  ${GREEN}5.${PLAIN} 从本地 .tar.gz 备份还原"
    echo -e "  ${RED}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}=================================================${PLAIN}"
    
    read -rp " 请输入选项 [0-5]: " choice
    
    case "$choice" in
        1) restore_from_url ;;
        2) restore_manual ;;
        3) test_config ;;
        4) update_script ;;
        5) restore_from_archive ;;
        0) echo -e "${GREEN}感谢使用本脚本，再见！${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择。${PLAIN}"; sleep 1 ;;
    esac
}

# --- 主程序入口 ---
main() {
    pre_check
    install_self
    
    while true; do
        show_menu
    done
}

main "$@"
