#!/bin/bash
# 解锁：移除 chattr +i，并进入维护模式（守护只告警不隔离）
# 用法: unlock.sh [站点路径]
. /www/SuguangWebGuard/common.sh
need_root
TARGETS=$( [ -n "$1" ] && echo "$1" || get_sites )
[ -z "$TARGETS" ] && { echo "exclude.conf 中没有配置任何 SITE"; exit 1; }

touch /www/SuguangWebGuard/.maintenance
# 基线快照随解锁一起作废：解锁后文件不再带 +i，隔离判据的前提已经不存在。
# 少了它，即使有人绕过维护模式手工启了守护，守护也会因为「找不到基线」
# 而停在纯告警模式，不会去搬文件。lock.sh 跑完会重新生成。
rm -f /www/SuguangWebGuard/.baseline
[ "${SWG_FROM_UNINSTALL:-0}" = "1" ] || echo "[维护模式] 已开启：监控守护在解锁期间只记录、不隔离文件。"

for site in $TARGETS; do
  [ -d "$site" ] || { echo "跳过（目录不存在）: $site"; continue; }
  echo "=== 解锁: $site ==="
  find "$site" -type d -print0 2>/dev/null | xargs -0 -r chattr -a 2>/dev/null
  find "$site" -type f -print0 2>/dev/null | xargs -0 -r chattr -i 2>/dev/null
  left=$(find "$site" -type f -print0 2>/dev/null | xargs -0 -r lsattr -d 2>/dev/null | grep -c '^....i')
  echo "  剩余 +i 文件: $left 个（应为 0）"
  echo "$(ts) UNLOCK $site left=$left" >> /www/SuguangWebGuard/logs/action.log
done
if [ "${SWG_FROM_UNINSTALL:-0}" != "1" ]; then
  echo
  echo "改完后务必运行: /www/SuguangWebGuard/lock.sh   （会自动退出维护模式）"
fi
