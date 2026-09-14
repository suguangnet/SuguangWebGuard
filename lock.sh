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

# 基线值统计的是【全部 SITE】的加锁总数，而不只是本次加锁的目标。
# lock.sh 允许只加锁单个站点，若按本次目标记数，基线值会缩水成一个站的量，
# 之后守护拿它当分母就失去意义了。
TOTAL_LOCKED=0
for s in $(get_sites); do
  [ -d "$s" ] || continue
  TOTAL_LOCKED=$((TOTAL_LOCKED + $(count_locked "$s")))
done

# 写下加锁基线快照。守护用它判断「隔离判据成立的前提是否存在」。
#
# 为什么不让守护自己去算加锁覆盖率：覆盖率的分母是当前文件总数，而新增文件
# 会把分母顶大。实测 100 个已锁文件的站点里突然出现 30 个新文件，覆盖率就掉到
# 77%，守护会误判成「基线没建立」而停止隔离 —— 等于攻击者一次多传些文件就能
# 让防护自己关掉。把加锁那一刻的数量固定下来当分母，新增文件就影响不了这个判断。
BASEFILE=$PREFIX/.baseline
{
  echo "# SuguangWebGuard 加锁基线快照，由 lock.sh 生成，unlock.sh 删除"
  echo "# 守护(watch.sh)据此确认加锁基线确实建立过，不要手工编辑"
  echo "locked=$TOTAL_LOCKED"
  echo "time=$(ts)"
  echo "sites=$(echo $TARGETS | tr '\n' ' ')"
} > "$BASEFILE"
chmod 600 "$BASEFILE"

echo
echo "---- 配置预检 ----"
if check_phpok_coverage; then
  echo "  EXCLUDE 与 PHPOK 搭配正常，没有会被误隔离的文件"
fi

rm -f /www/SuguangWebGuard/.maintenance
echo "[维护模式] 已关闭：监控守护恢复自动隔离。"
