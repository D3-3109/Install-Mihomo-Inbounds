#!/usr/bin/env bash
# uninstall_mihomo.sh
# 更稳健的 Mihomo 卸载脚本：systemd/OpenRC 全面清理
set -uo pipefail  # 去掉 -e，避免提前退出

PURGE=false
ASSUME_YES=false
CONFIG_REMOVED=false
CONFIG_BACKUP=""
REMOVE_CLIENT_STATE=false
CONFIG_DIR="/usr/local/etc/mihomo"
CLIENT_STATE_DIR="/root"
GEO_UPDATER="/root/update_geo.sh"

die()  { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=true ;;
    --yes|-y) ASSUME_YES=true ;;
    *) die "未知参数: $arg（支持 --yes 和 --purge）" ;;
  esac
done

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "请以 root 身份运行（使用 sudo）"
  fi
}

confirm_uninstall() {
  $ASSUME_YES && return 0
  if [[ ! -t 0 ]]; then
    die "非交互环境必须显式传入 --yes 才会执行卸载。"
  fi
  local answer
  read -r -p "确定卸载 Mihomo 并删除其程序与配置吗？[y/N]: " answer
  [[ "$answer" =~ ^[yY]$ ]] || { info "已取消卸载。"; exit 0; }
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID,,}"
  else
    OS_ID="unknown"
  fi
  case "$OS_ID" in
    debian|ubuntu) OS_FAMILY="debian" ;;
    alpine)        OS_FAMILY="alpine" ;;
    *)             OS_FAMILY="other" ;;
  esac
  info "系统：${PRETTY_NAME:-$OS_ID}"
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

collect_mihomo_units() {
  if ! has_systemd; then
    return 0
  fi

  # 1) unit-files
  systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '.*mihomo.*\.service$' || true

  # 2) list-units
  systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '.*mihomo.*\.service$' || true

  # 3) 兜底
  for f in /etc/systemd/system/*mihomo*.service /lib/systemd/system/*mihomo*.service /usr/lib/systemd/system/*mihomo*.service; do
    [[ -f "$f" ]] && basename "$f"
  done
}

stop_disable_systemd_units() {
  has_systemd || { warn "未检测到已注册的 Mihomo 服务（systemd）。"; return 0; }

  mapfile -t units < <(collect_mihomo_units | awk 'NF && !seen[$0]++')
  if ((${#units[@]}==0)); then
    warn "未检测到已注册的 Mihomo 服务（systemd）。"
    return 0
  fi

  info "检测到以下 systemd 单元将被停止并禁用："
  for u in "${units[@]}"; do echo "  - $u"; done

  for u in "${units[@]}"; do
    systemctl stop "$u" --no-block 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    systemctl reset-failed "$u" 2>/dev/null || true
  done

  for wants in /etc/systemd/system/*/*mihomo*.service; do
    [[ -L "$wants" || -f "$wants" ]] && { info "移除残留链接/文件：$wants"; rm -f "$wants" || true; }
  done
}

remove_systemd_files() {
  has_systemd || return 0
  local removed=false
  for f in /etc/systemd/system/*mihomo*.service /lib/systemd/system/*mihomo*.service /usr/lib/systemd/system/*mihomo*.service; do
    if [[ -f "$f" ]]; then
      info "删除 systemd 单元文件：$f"
      rm -f "$f" || true
      removed=true
    fi
  done
  $removed && systemctl daemon-reload || true
}

stop_disable_openrc() {
  if command -v rc-update >/dev/null 2>&1 && [[ -f /etc/init.d/mihomo ]]; then
    info "检测到 OpenRC 服务，停止并移出开机自启 ..."
    rc-service mihomo stop || true
    rc-update del mihomo default || true
  else
    warn "未检测到已注册的 Mihomo 服务（OpenRC）。"
  fi
}

remove_openrc_files() {
  [[ -f /etc/init.d/mihomo ]] && { info "删除 OpenRC 脚本 /etc/init.d/mihomo"; rm -f /etc/init.d/mihomo || true; }
  [[ -f /run/mihomo.pid ]] && rm -f /run/mihomo.pid || true
}

# 归档布局也可供各协议安装器的卸载备份复用。
# 参数：配置目录、客户端状态目录、归档路径。失败时调用方不得删除原文件。
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

backup_config() {
  local backup
  backup=$(mktemp "${CLIENT_STATE_DIR}/mihomo-config-backup-$(date +%Y%m%d-%H%M%S).XXXXXX.tar.gz") || {
    warn "无法创建备份文件，配置和客户端状态将保留。"
    return 1
  }
  info "备份配置及客户端状态到 $backup"
  if ! backup_mihomo_archive "$CONFIG_DIR" "$CLIENT_STATE_DIR" "$backup"; then
    rm -f -- "$backup"
    warn "备份失败，配置和客户端状态将保留。"
    return 1
  fi
  CONFIG_BACKUP="$backup"
  echo -e "\e[34m[NOTE]\e[0m 备份已保存：$backup"
}

remove_config() {
  if [[ -d "$CONFIG_DIR" ]]; then
    info "删除配置目录 $CONFIG_DIR"
    if ! rm -rf -- "$CONFIG_DIR"; then
      warn "配置目录删除失败，客户端状态将保留：$CONFIG_DIR"
      return 1
    fi
    CONFIG_REMOVED=true
  else
    warn "未找到配置目录：$CONFIG_DIR"
  fi
  REMOVE_CLIENT_STATE=true
}

remove_binary_and_misc() {
  local bin="/usr/local/bin/mihomo"
  [[ -f "$bin" ]] && { info "删除二进制文件 $bin"; rm -f "$bin" || true; } || warn "未找到二进制文件：$bin"

  for d in /usr/local/share/mihomo /usr/share/mihomo /var/lib/mihomo; do
    [[ -d "$d" ]] && { info "删除数据目录 $d"; rm -rf "$d" || true; }
  done

  for f in /var/log/mihomo.log /var/log/mihomo/mihomo.log; do
    [[ -f "$f" ]] && { info "删除日志文件 $f"; rm -f "$f" || true; }
  done
  [[ -d /var/log/mihomo ]] && { info "删除日志目录 /var/log/mihomo"; rm -rf /var/log/mihomo || true; }

  # 只有备份成功后才清理这些客户端文件；共享地址始终保留。
  if $REMOVE_CLIENT_STATE; then
    rm -f "$CLIENT_STATE_DIR"/mihomo_ss_link_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_vless_reality_link_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_reality_pubkey_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_vless_encryption_link_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_vless_encryption_client_key_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_anytls_link_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_anytls_proxies_*.yaml \
      "$CLIENT_STATE_DIR"/mihomo_anytls_node_*.json \
      "$CLIENT_STATE_DIR"/mihomo_tuic_link_*.txt \
      "$CLIENT_STATE_DIR"/mihomo_tuic_node_*.json 2>/dev/null || true
  fi
}

remove_geo_updater() {
  local cron_file filtered_file
  if command -v crontab >/dev/null 2>&1; then
    cron_file=$(mktemp) || { warn "无法创建临时文件，Geo 定时任务未清理。"; return 1; }
    filtered_file=$(mktemp) || { rm -f "$cron_file"; warn "无法创建临时文件，Geo 定时任务未清理。"; return 1; }
    if crontab -l > "$cron_file" 2>/dev/null; then
      # 匹配项目写入的绝对路径，不影响其他 update_geo.sh 或注释行。
      if ! awk '$0 !~ /^[[:space:]]*#/ && $0 ~ /(^|[[:space:]])\/root\/update_geo[.]sh([[:space:]]|$)/ { next } { print }' \
        "$cron_file" > "$filtered_file"; then
        rm -f "$cron_file" "$filtered_file"
        warn "无法筛选 crontab，Geo 定时任务未清理。"
        return 1
      fi
      if ! cmp -s "$cron_file" "$filtered_file"; then
        if ! crontab "$filtered_file"; then
          rm -f "$cron_file" "$filtered_file"
          warn "无法更新 crontab，Geo 更新脚本已保留。"
          return 1
        fi
        info "已移除 Mihomo Geo 更新的 crontab 行。"
      fi
    else
      rm -f "$cron_file" "$filtered_file"
      warn "未能读取 crontab；Geo 更新脚本已保留，请手动检查定时任务。"
      return 1
    fi
    rm -f "$cron_file" "$filtered_file"
  else
    warn "未找到 crontab 命令；如存在 Geo 定时任务，请手动检查。"
    return 1
  fi
  if [[ -e "$GEO_UPDATER" ]]; then
    rm -f -- "$GEO_UPDATER" || { warn "无法删除 Geo 更新脚本：$GEO_UPDATER"; return 1; }
    info "已删除 Geo 更新脚本：$GEO_UPDATER"
  fi
}

remove_user_group_if_purge() {
  $PURGE || { info "保留用户/组 mihomo（未使用 --purge）。"; return; }

  info "执行 --purge：尝试删除 mihomo 用户与组 ..."
  pkill -u mihomo 2>/dev/null || true

  if command -v deluser >/dev/null 2>&1; then
    deluser mihomo 2>/dev/null || true
  elif command -v userdel >/dev/null 2>&1; then
    userdel mihomo 2>/dev/null || true
  fi

  if command -v delgroup >/dev/null 2>&1; then
    delgroup mihomo 2>/dev/null || true
  elif command -v groupdel >/dev/null 2>&1; then
    groupdel mihomo 2>/dev/null || true
  fi
}

summary() {
  echo
  echo "====== 卸载完成 ======"
  echo "已停止并移除 systemd/OpenRC 服务，并删除 Mihomo 二进制。"
  if $CONFIG_REMOVED; then
    echo "配置已删除。"
  elif [[ -d "$CONFIG_DIR" ]]; then
    echo "配置仍保留在 $CONFIG_DIR（备份或删除未成功）。"
  else
    echo "未发现 Mihomo 配置目录。"
  fi
  [[ -n "$CONFIG_BACKUP" ]] && echo "配置及客户端状态备份：$CONFIG_BACKUP"
  echo "共享地址文件 /root/inbound_address.txt 已保留。"
  if $PURGE; then
    echo "已尝试删除 mihomo 用户与组。"
  else
    echo "保留了 mihomo 用户与组（如需同时删除，请加 --purge 重新执行）。"
  fi
  echo
  if has_systemd; then
    echo "检查残留："
    echo "  systemctl list-units --type=service --all | grep -i mihomo || true"
    echo "  systemctl list-unit-files | grep -i mihomo || true"
  fi
}

main() {
  require_root
  confirm_uninstall
  detect_os
  backup_config || die "备份失败，已取消卸载。"

  stop_disable_systemd_units
  remove_systemd_files
  stop_disable_openrc
  remove_openrc_files
  remove_config || true
  remove_binary_and_misc
  remove_geo_updater || true
  remove_user_group_if_purge
  has_systemd && systemctl daemon-reload || true

  summary
}

main "$@"
