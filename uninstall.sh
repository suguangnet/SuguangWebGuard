#!/bin/bash
# SuguangWebGuard 卸载脚本
# 用法: ./uninstall.sh [--keep-logs] [--yes]
#
# 卸载顺序很关键：先停服务，再解锁站点文件，最后才删程序目录。
# 顺序颠倒的话，程序删掉后就没有工具去解除文件的 immutable 属性了。
set -u
PREFIX=/www/SuguangWebGuard
LOGDIR=$PREFIX/logs
TS=$(date +%Y%m%d%H%M%S)
KEEP_QUAR=""      # 隔离区若非空，保留到这里
KEEP_LOG_DIR=""   # --keep-logs 时日志移到这里
KEEP_LOGS=0; ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-logs) KEEP_LOGS=1;;
    --yes|-y) ASSUME_YES=1;;
    -h|--help)
      echo "用法: ./uninstall.sh [--keep-logs] [--yes]"
      echo "  --keep-logs  保留日志（移动到 ${PREFIX}-logs-<时间戳>）"
      echo "  --yes, -y    不交互确认"
      exit 0;;
    *) echo "未知参数: $1（--help 查看用法）"; exit 1;;
  esac; shift
done
[ "$(id -u)" = "0" ] || { echo "必须用 root 运行"; exit 1; }

echo "=============================================="
echo " SuguangWebGuard 网站防篡改系统 · 卸载"
echo " 速光网络软件开发  https://suguang.cc"
echo "=============================================="
echo
echo "将执行："
echo "  1. 停止并移除 suguang-webguard-watch 与 suguang-webguard-web 服务"
echo "  2. 移除 cron / logrotate 配置"
echo "  3. 解除所有受保护站点文件的 immutable 属性（关键步骤）"
echo "  4. 删除 $PREFIX（含配置、AIDE 基线、Web 密码）"
if [ "$KEEP_LOGS" = "1" ]; then
  echo "  5. 日志移到 ${PREFIX}-logs-${TS} 保留"
else
  echo "  5. 删除日志（加 --keep-logs 可保留）"
fi
echo "  * 隔离区若非空会自动保留，不会连同 webshell 一起删掉"
echo
if [ "$ASSUME_YES" != "1" ]; then
  printf '确认卸载？[y/N] '; read -r a </dev/tty
  case "$a" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0;; esac
fi

# ---------- 1. 停服务 ----------
echo
echo ">>> [1/5] 停止并移除服务"
systemctl disable --now suguang-webguard-watch >/dev/null 2>&1
systemctl disable --now suguang-webguard-web   >/dev/null 2>&1
rm -f /etc/systemd/system/suguang-webguard-watch.service \
      /etc/systemd/system/suguang-webguard-web.service
systemctl daemon-reload 2>/dev/null
# 兜底：清掉可能残留的守护进程
pkill -f "$PREFIX/watch.sh"     2>/dev/null
pkill -f "$PREFIX/web/webui.py" 2>/dev/null
echo "  已移除 suguang-webguard-watch / suguang-webguard-web"

# ---------- 2. cron / logrotate ----------
echo ">>> [2/5] 移除 cron / logrotate 配置"
rm -f /etc/cron.d/suguang-webguard /etc/logrotate.d/suguang-webguard
echo "  已移除"

# ---------- 3. 解锁（最关键的一步）----------
echo ">>> [3/5] 解除站点文件的 immutable 属性"
UNLOCK_OK=1
if [ -x "$PREFIX/unlock.sh" ] && [ -f "$PREFIX/exclude.conf" ]; then
  SWG_FROM_UNINSTALL=1 "$PREFIX/unlock.sh" || UNLOCK_OK=0
elif [ -f "$PREFIX/exclude.conf" ]; then
  echo "  unlock.sh 缺失，直接依据 exclude.conf 解锁..."
  while read -r s; do
    [ -d "$s" ] || continue
    echo "  解锁 $s"
    find "$s" -type d -print0 2>/dev/null | xargs -0 -r chattr -a 2>/dev/null
    find "$s" -type f -print0 2>/dev/null | xargs -0 -r chattr -i 2>/dev/null
  done < <(grep -E '^\s*SITE=' "$PREFIX/exclude.conf" | sed 's/^\s*SITE=//')
else
  UNLOCK_OK=0
  echo "  !! 找不到 exclude.conf，无法自动确定受保护站点"
  echo "     若仍有文件被锁，请手工执行："
  echo "       find /www/wwwroot/你的站点 -type f -print0 | xargs -0 chattr -i"
  echo "       find /www/wwwroot/你的站点 -type d -print0 | xargs -0 chattr -a"
fi

# ---------- 4. 复查残留 ----------
echo ">>> [4/5] 复查是否还有残留的 immutable 文件"
LEFT_TOTAL=0
if [ -f "$PREFIX/exclude.conf" ]; then
  while read -r s; do
    [ -d "$s" ] || continue
    n=$(find "$s" -type f -print0 2>/dev/null | xargs -0 -r lsattr -d 2>/dev/null | grep -c '^....i')
    if [ "$n" -gt 0 ]; then
      echo "  !! $s 仍有 $n 个文件带 i 属性"
      LEFT_TOTAL=$((LEFT_TOTAL + n))
    fi
  done < <(grep -E '^\s*SITE=' "$PREFIX/exclude.conf" | sed 's/^\s*SITE=//')
fi
if [ "$LEFT_TOTAL" = "0" ] && [ "$UNLOCK_OK" = "1" ]; then
  echo "  无残留，全部已解锁"
elif [ "$LEFT_TOTAL" -gt 0 ]; then
  echo "  !! 共 $LEFT_TOTAL 个文件未能解锁，请手工处理后再继续"
fi

# ---------- 5. 删除程序目录 ----------
echo ">>> [5/5] 删除程序目录"
if [ -d "$PREFIX/quarantine" ] && [ -n "$(ls -A "$PREFIX/quarantine" 2>/dev/null)" ]; then
  KEEP_QUAR="${PREFIX}-quarantine-${TS}"
  mv "$PREFIX/quarantine" "$KEEP_QUAR" && chmod 700 "$KEEP_QUAR"
  echo "  隔离区非空，已保留到 $KEEP_QUAR"
fi
if [ "$KEEP_LOGS" = "1" ] && [ -d "$LOGDIR" ]; then
  KEEP_LOG_DIR="${PREFIX}-logs-${TS}"
  mv "$LOGDIR" "$KEEP_LOG_DIR" && chmod 700 "$KEEP_LOG_DIR"
  echo "  日志已保留到 $KEEP_LOG_DIR"
fi
rm -rf "$PREFIX"
if [ "$KEEP_LOGS" = "1" ]; then
  echo "  已删除程序、配置、AIDE 基线与 Web 密码（日志已另存）"
else
  echo "  已删除程序、配置、日志、AIDE 基线与 Web 密码"
fi

# ---------- 收尾 ----------
echo
echo "=============================================="
if [ "$LEFT_TOTAL" -gt 0 ]; then
  echo " 卸载完成，但有 $LEFT_TOTAL 个文件仍处于锁定状态，请手工解锁！"
else
  echo " 卸载完成"
fi
echo "=============================================="
if [ -n "$KEEP_QUAR" ] || [ -n "$KEEP_LOG_DIR" ]; then
  echo
  echo "已保留的内容（确认无用后可自行删除）："
  [ -n "$KEEP_QUAR" ]    && echo "  隔离文件: $KEEP_QUAR"
  [ -n "$KEEP_LOG_DIR" ] && echo "  历史日志: $KEEP_LOG_DIR"
fi
echo
echo "以下内容需要你自行处理："
echo "  - Web 管理端口的防火墙 / 云安全组放行规则"
echo "  - 依赖包未卸载（可能有其他程序在用）："
echo "      yum remove -y aide inotify-tools"
echo "  - python3 未卸载（系统其他组件可能依赖）"
