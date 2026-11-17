#!/bin/bash
# update_geo.sh
# 用于自动更新 Mihomo 的 Geo 文件并重启服务
# 适配 Debian/Ubuntu (systemd) 和 Alpine (OpenRC)

set -euo pipefail

# --- 环境变量设置 ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- 配置路径 ---
GEO_DIR="/usr/local/etc/mihomo"
DOWNLOAD_URL_GEOIP="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb"
DOWNLOAD_URL_GEOSITE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# --- 日志函数 ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log "Error: 请以 root 身份运行"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    log "Error: 缺少 curl，无法下载 Geo 文件"
    exit 1
fi

# --- 1. 下载文件 ---
log "开始下载 Geo 文件..."
mkdir -p "$GEO_DIR"

tmp_dir="$(mktemp -d "${GEO_DIR}/.geo-update.XXXXXX")"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM

if curl -fsSL -o "$tmp_dir/geoip.metadb" "$DOWNLOAD_URL_GEOIP" && [[ -s "$tmp_dir/geoip.metadb" ]]; then
    log "geoip.metadb 下载成功"
else
    log "Error: geoip.metadb 下载失败"
    exit 1
fi

if curl -fsSL -o "$tmp_dir/geosite.dat" "$DOWNLOAD_URL_GEOSITE" && [[ -s "$tmp_dir/geosite.dat" ]]; then
    log "geosite.dat 下载成功"
else
    log "Error: geosite.dat 下载失败"
    exit 1
fi

# 两个文件都下载成功后才替换正式文件，避免留下半套新旧数据。
chmod 0644 "$tmp_dir/geoip.metadb" "$tmp_dir/geosite.dat"
mv -f "$tmp_dir/geoip.metadb" "$GEO_DIR/geoip.metadb"
mv -f "$tmp_dir/geosite.dat" "$GEO_DIR/geosite.dat"

# --- 2. 按需重启已运行的 Mihomo 服务 ---
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    if systemctl is-active --quiet mihomo || systemctl is-enabled --quiet mihomo 2>/dev/null; then
        log "正在重启 Mihomo 服务..."
        systemctl restart mihomo && systemctl is-active --quiet mihomo || {
            log "Error: Mihomo (systemd) 重启失败，请检查日志"
            exit 1
        }
        log "Mihomo (systemd) 重启成功"
    else
        log "Mihomo 服务尚未启用，仅完成 Geo 文件更新"
    fi
elif command -v rc-service >/dev/null 2>&1; then
    if [[ -f /etc/init.d/mihomo ]] && rc-service mihomo status 2>/dev/null | grep -qi "started"; then
        log "正在重启 Mihomo 服务..."
        rc-service mihomo restart && rc-service mihomo status 2>/dev/null | grep -qi "started" || {
            log "Error: Mihomo (OpenRC) 重启失败"
            exit 1
        }
        log "Mihomo (OpenRC) 重启成功"
    else
        log "Mihomo 服务未运行，仅完成 Geo 文件更新"
    fi
else
    log "未检测到服务管理器，仅完成 Geo 文件更新"
fi

log "更新流程结束"
