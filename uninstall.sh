#!/bin/bash
# SuguangWebGuard 卸载脚本
# 用法: ./uninstall.sh [--keep-logs] [--yes]
set -u
PREFIX=/www/SuguangWebGuard
LOGDIR=/www/SuguangWebGuard/logs
KEEP_LOGS=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-logs) KEEP_LOGS=1;;
    --yes|-y) ASSUME_YES=1;;
    *) echo "未知参数: $1"; exit 1;;
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
echo "  3. 解锁所有受保护站点的文件（重要！）"
echo "  4. 删除 $PREFIX、Web 配置、AIDE 配置与基线库"
[ "$KEEP_LOGS" = "1" ] && echo "  5. 保留日志 $LOGDIR" || echo "  5. 删除日志 $LOGDIR"
echo
if [ "$ASSUME_YES" != "1" ]; then
  printf '确认卸载？[y/N] '; read -r a </dev/tty
  case "$a" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0;; esac
fi

echo
echo ">>> 停止服务"
systemctl disable --now suguang-webguard-watch >/dev/null 2>&1
systemctl disable --now suguang-webguard-web >/dev/null 2>&1
rm -f /etc/systemd/system/suguang-webguard-watch.service /etc/systemd/system/suguang-webguard-web.service
systemctl daemon-reload
echo "  已移除 suguang-webguard-watch / suguang-webguard-web"

echo ">>> 移除 cron / logrotate"
rm -f /etc/cron.d/suguang-webguard /etc/logrotate.d/suguang-webguard
echo "  已移除"

echo ">>> 解锁站点文件（这一步很关键，否则文件将永久锁死）"
if [ -x "$PREFIX/unlock.sh" ] && [ -f "$PREFIX/exclude.conf" ]; then
  "$PREFIX/unlock.sh" || echo "  警告: unlock.sh 执行异常，请手工检查"
else
  echo "  找不到 unlock.sh 或 exclude.conf，尝试从配置直接解锁..."
  if [ -f "$PREFIX/exclude.conf" ]; then
    grep -E '^\s*SITE=' "$PREFIX/exclude.conf" | sed 's/^\s*SITE=//' | while read -r s; do
      [ -d "$s" ] || continue
      echo "  解锁 $s"
      find "$s" -type d -print0 2>/dev/null | xargs -0 -r chattr -a 2>/dev/null
      find "$s" -type f -print0 2>/dev/null | xargs -0 -r chattr -i 2>/dev/null
    done
  else
    echo "  无配置可用！若仍有文件被锁，请手工执行："
    echo "    find /www/wwwroot/站点 -type f -print0 | xargs -0 chattr -i"
  fi
fi

echo ">>> 检查是否还有残留的 immutable 文件"
LEFT=0
if [ -f "$PREFIX/exclude.conf" ]; then
  while read -r s; do
    [ -d "$s" ] || continue
    n=$(find "$s" -type f -print0 2>/dev/null | xargs -0 -r lsattr -d 2>/dev/null | grep -c '^....i')
    [ "$n" -gt 0 ] && { echo "  警告: $s 仍有 $n 个文件带 i 属性"; LEFT=1; }
  done < <(grep -E '^\s*SITE=' "$PREFIX/exclude.conf" | sed 's/^\s*SITE=//')
fi
[ "$LEFT" = "0" ] && echo "  无残留，全部已解锁"

echo ">>> 删除程序文件"
if [ -d "$PREFIX/quarantine" ] && [ -n "$(ls -A "$PREFIX/quarantine" 2>/dev/null)" ]; then
  KEEP="/www/SuguangWebGuard-quarantine-$(date +%Y%m%d%H%M%S)"
  mv "$PREFIX/quarantine" "$KEEP"
  echo "  隔离区非空，已保留到 $KEEP"
fi
if [ "$KEEP_LOGS" = "1" ] && [ -d "$LOGDIR" ]; then
  KEEPLOG="/www/SuguangWebGuard-logs-$(date +%Y%m%d%H%M%S)"
  mv "$LOGDIR" "$KEEPLOG"
  echo "  日志已保留到 $KEEPLOG"
fi
rm -rf "$PREFIX"
rm -f /etc/cron.d/suguang-webguard /etc/logrotate.d/suguang-webguard

echo "  已删除（含 web.conf、日志、AIDE 基线、初始密码文件）"


echo
echo "卸载完成。"
echo "提示：Web 端口的防火墙/安全组放行规则需要你自行撤销。"
echo "aide 与 inotify-tools 两个软件包未卸载（可能有其他用途）。"
echo "如需卸载: yum remove -y aide inotify-tools"
