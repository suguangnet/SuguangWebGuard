#!/bin/bash
# 加锁：给受保护站点的所有已有文件设置 chattr +i，并退出维护模式
# 用法: lock.sh [站点路径]
. /www/SuguangWebGuard/common.sh
need_root
TARGETS=$( [ -n "$1" ] && echo "$1" || get_sites )
[ -z "$TARGETS" ] && { echo "exclude.conf 中没有配置任何 SITE"; exit 1; }

for site in $TARGETS; do
  [ -d "$site" ] || { echo "跳过（目录不存在）: $site"; continue; }
  echo "=== 加锁: $site ==="
  echo -n "  排除目录: "; get_excludes "$site" | tr '\n' ' '; echo
  build_prune "$site"
  n=$(find "$site" "${FIND_PRUNE[@]}" -type f -print 2>/dev/null | wc -l)
  find "$site" "${FIND_PRUNE[@]}" -type f -print0 2>/dev/null | xargs -0 -r chattr +i 2>/dev/null
  locked=$(count_locked "$site")
  echo "  应锁文件: $n 个    已锁: $locked 个"
  [ "$locked" -lt "$n" ] && echo "  ⚠ 有 $((n-locked)) 个文件未能加锁，请检查"
  echo "$(ts) LOCK $site files=$n locked=$locked" >> /www/SuguangWebGuard/logs/action.log
done

rm -f /www/SuguangWebGuard/.maintenance
echo "[维护模式] 已关闭：监控守护恢复自动隔离。"
