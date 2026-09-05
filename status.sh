#!/bin/bash
# 查看防篡改保护状态
. /www/SuguangWebGuard/common.sh
echo "############ 防篡改状态 $(ts) ############"
for site in $(get_sites); do
  [ -d "$site" ] || continue
  build_prune "$site"
  total=$(find "$site" "${FIND_PRUNE[@]}" -type f -print 2>/dev/null | wc -l)
  locked=$(count_locked "$site")
  if [ "$locked" -eq 0 ]; then st="未保护"
  elif [ "$locked" -ge "$total" ]; then st="已保护"
  else st="部分保护（有 $((total-locked)) 个新增文件未锁，可运行 lock.sh 纳入）"; fi
  echo
  echo "站点: $site"
  echo "  状态      : $st"
  echo "  应锁文件  : $total    已锁: $locked"
  echo -n "  可写目录  : "; get_excludes "$site" | tr '\n' ' '; echo
done
echo
echo "---- 监控守护 ----"
if systemctl is-active suguang-webguard-watch >/dev/null 2>&1; then
  echo "  suguang-webguard-watch: 运行中"
else
  echo "  suguang-webguard-watch: 未运行"
fi
q=$(ls -1 "$QUAR" 2>/dev/null | wc -l)
echo "  隔离区文件数    : $q  ($QUAR)"
echo
echo "---- 最近 10 条告警 ----"
tail -n 10 /www/SuguangWebGuard/logs/alert.log 2>/dev/null || echo "  (无)"
