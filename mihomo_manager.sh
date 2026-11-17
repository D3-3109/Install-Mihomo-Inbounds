#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 Mihomo 管理工具
# 统一管理 Mihomo 全协议入站、分流、配置还原、卸载及独立转发/Snell 服务
# ==============================================================================

set -uo pipefail
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
PLAIN='\033[0m'

GITHUB_USER="D3-3109"
GITHUB_REPO="Install-Mihomo-Inbounds"
GITHUB_BRANCH="main"
BASE_URL="${MIHOMO_BASE_URL:-https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}}"

MANAGER_PATH="/usr/bin/mihomo-manager"
WORK_DIR="/root"

die()  { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO] $*${PLAIN}"; }
warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }

check_root() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请以 root 身份运行此脚本。"
}

check_deps() {
    if ! command -v curl >/dev/null 2>&1; then
        info "正在安装 curl..."
        if [[ -f /etc/alpine-release ]]; then
            apk add --no-cache curl
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl
        else
            die "无法自动安装 curl，请先手动安装。"
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        info "正在安装 python3..."
        if [[ -f /etc/alpine-release ]]; then
            apk add --no-cache python3
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3
        else
            die "无法自动安装 python3，请先手动安装。"
        fi
    fi
    local required=(curl python3 bash install mktemp realpath) cmd
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令: $cmd"
    done
}

download_script() {
    local download_url="$1" target_file="$2" tmp_file
    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
    if ! curl -fsSL -o "$tmp_file" "$download_url"; then
        rm -f "$tmp_file"; return 1
    fi
    if ! bash -n "$tmp_file"; then
        warn "下载内容未通过 Bash 语法检查，拒绝覆盖 $target_file。"
        rm -f "$tmp_file"; return 1
    fi
    if ! chmod 0755 "$tmp_file" || ! mv -f "$tmp_file" "$target_file"; then
        rm -f "$tmp_file"; return 1
    fi
}

install_self() {
    local current_path
    current_path="$(realpath "$0")"
    if [[ "$current_path" != "$MANAGER_PATH" ]]; then
        info "正在安装管理脚本到 $MANAGER_PATH ..."
        cp "$current_path" "$MANAGER_PATH"
        chmod +x "$MANAGER_PATH"
        info "安装完成！以后可以直接在终端输入 ${CYAN}mihomo-manager${PLAIN} 唤醒此菜单。"
        sleep 1
        exec "$MANAGER_PATH" "$@"
    fi
}

pull_and_run() {
    local script_name="$1"
    local desc="${2:-运行脚本}"
    local target_file="${WORK_DIR}/${script_name}"
    local download_url="${BASE_URL}/${script_name}"

    info "正在拉取: $script_name ..."
    if download_script "$download_url" "$target_file"; then
        info "拉取成功，正在${desc}..."
        echo "----------------------------------------------------------------"
        if ! (cd "$WORK_DIR" && ./"$script_name"); then
            warn "$script_name 执行结束返回非零状态，请查看上方提示。"
        fi
        echo "----------------------------------------------------------------"
        read -n 1 -s -r -p "子脚本执行结束，按任意键返回主菜单..." || true
    else
        echo -e "${RED}[ERROR] 无法下载脚本: $script_name${PLAIN}"
        echo -e "${RED}请检查网络连接或 Github 仓库地址是否正确。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回主菜单..." || true
    fi
}

update_self() {
    info "正在检查更新..."
    if download_script "${BASE_URL}/mihomo_manager.sh" "$MANAGER_PATH"; then
        info "脚本更新成功！正在重新加载..."
        sleep 1
        exec "$MANAGER_PATH"
    else
        die "更新失败，请检查网络。"
    fi
}

show_menu() {
    clear || true
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}          Caesar 蜜汁 Mihomo 管理工具             ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 安装 / 管理 Mihomo 入站节点 (17 种协议合一)"
    echo -e "  ${YELLOW}2.${PLAIN} Mihomo 服务端分流配置 (Routing)"
    echo -e "  ${CYAN}3.${PLAIN} 还原 / 测试 Mihomo 配置 (Restore)"
    echo -e "  ${GREEN}4.${PLAIN} GeoIP / GeoSite 立即更新"
    echo -e "  ${RED}5.${PLAIN} 卸载 Mihomo 及相关文件"
    echo "-------------------------------------------------"
    echo -e "  ${GREEN}6.${PLAIN} 安装 / 管理 Realm 端口转发 (独立服务)"
    echo -e "  ${GREEN}7.${PLAIN} 安装 / 管理 DNAT 内核端口转发"
    echo -e "  ${GREEN}8.${PLAIN} 安装 / 管理 Snell v6 服务端 (独立服务)"
    echo -e "  ${GREEN}9.${PLAIN} 安装 / 管理 Snell v4/v5 服务端 (Legacy)"
    echo "-------------------------------------------------"
    echo -e "  ${CYAN}10.${PLAIN} 更新此管理脚本"
    echo -e "  ${CYAN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}=================================================${PLAIN}"

    read -rp " 请输入选项 [0-10]: " choice
    case "$choice" in
        1) pull_and_run "install_mihomo.sh" "打开 Mihomo 入站管理面板" ;;
        2) pull_and_run "mihomo_routing.sh" "进入分流配置工具" ;;
        3) pull_and_run "mihomo_restore.sh" "进入配置还原工具" ;;
        4) pull_and_run "update_geo.sh" "更新 GeoIP/GeoSite" ;;
        5) pull_and_run "uninstall_mihomo.sh" "执行卸载程序" ;;
        6) pull_and_run "install_realm.sh" "打开 Realm 转发向导" ;;
        7) pull_and_run "install_dnat.sh" "打开 DNAT 转发管理" ;;
        8) pull_and_run "install_snell.sh" "打开 Snell v6 管理面板" ;;
        9) pull_and_run "install_snell_legacy.sh" "打开 Snell v4/v5 管理面板" ;;
        10) update_self ;;
        0) echo -e "${GREEN}感谢使用此脚本，再见！${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择。${PLAIN}"; sleep 1 ;;
    esac
}

main() {
    check_root
    check_deps
    install_self "$@"
    while true; do
        show_menu
    done
}

main "$@"
