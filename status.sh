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
echo "---- 加锁基线 ----"
# 基线快照决定守护敢不敢隔离：没有它，守护只告警不动文件。
if [ -f "$PREFIX/.baseline" ]; then
  ref=$(awk -F= '$1=="locked"{print $2}' "$PREFIX/.baseline" 2>/dev/null)
  when=$(awk -F= '$1=="time"{print $2}' "$PREFIX/.baseline" 2>/dev/null)
  now_locked=0
  for s in $(get_sites); do
    [ -d "$s" ] && now_locked=$((now_locked + $(count_locked "$s")))
  done
  echo "  基线建立于  : $when"
  echo "  基线记录    : $ref 个已加锁文件"
  echo "  当前实际    : $now_locked 个"
  if [ "${ref:-0}" -gt 0 ] && [ "$((now_locked * 100 / ref))" -ge 90 ]; then
    echo "  判定        : 正常，守护可以隔离新增脚本"
  else
    echo "  判定        : ⚠ 基线已被破坏，守护将只告警不隔离，请运行 lock.sh"
  fi
else
  echo "  ⚠ 未建立（没有 .baseline）。守护只会告警、不会隔离任何文件。"
  echo "    执行 $PREFIX/lock.sh 建立基线。"
fi
[ -f "$PREFIX/.maintenance" ] && echo "  维护模式    : 开启中（守护只记录不隔离）"
[ -f "$PREFIX/.fuse-tripped" ] && {
  echo "  ⚠ 熔断已触发：单轮隔离数超阈值，隔离已停止。"
  echo "    确认隔离区批次后重新加锁，再重启守护解除。"
}

echo
echo "---- 监控守护 ----"
if systemctl is-active suguang-webguard-watch >/dev/null 2>&1; then
  echo "  suguang-webguard-watch: 运行中"
else
  echo "  suguang-webguard-watch: 未运行"
fi
nb=0; nf=0
for d in "$QUAR"/*/; do
  [ -f "$d/manifest.tsv" ] || continue
  nb=$((nb+1))
  nf=$((nf + $(find "$d/files" -type f 2>/dev/null | wc -l)))
done
echo "  隔离批次        : $nb 个，待恢复文件 $nf 个  ($QUAR)"
[ "$nb" -gt 0 ] && echo "  查看/恢复       : $PREFIX/restore.sh --list"
echo
echo "---- 配置预检 ----"
if check_phpok_coverage; then
  echo "  EXCLUDE 与 PHPOK 搭配正常"
fi
echo
echo "---- 最近 10 条告警 ----"
tail -n 10 /www/SuguangWebGuard/logs/alert.log 2>/dev/null || echo "  (无)"
