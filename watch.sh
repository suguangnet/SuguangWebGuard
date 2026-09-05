#!/bin/bash
# 实时监控守护：拦截受保护站点中新出现的可执行脚本文件
#
# 两条独立防线：
#   1) inotify 实时监控 —— 毫秒级响应，但存在固有竞态：新建目录后立刻在其中写文件，
#      内核给新目录建立 watch 之前事件就已发生，会漏掉。本次入侵正是这种手法
#      （先建 runtime/upgrade/ 再立刻写 tmp.php）。
#   2) 定期全量扫描 —— 每 SWEEP_INTERVAL 秒兜底一次，把竞态窗口和 inotify 队列
#      溢出导致的漏网文件补捞回来。
#
# 维护模式：存在 /www/SuguangWebGuard/.maintenance 时两条防线都只记录、不隔离
#           （unlock.sh 创建该标记，lock.sh 清除）
. /www/SuguangWebGuard/common.sh
mkdir -p "$QUAR" "$LOGDIR"
ALERT=$LOGDIR/alert.log
MAINT=/www/SuguangWebGuard/.maintenance
SWEEP_INTERVAL=${SWEEP_INTERVAL:-60}

WATCH_DIRS=$(get_sites | while read -r s; do [ -d "$s" ] && echo "$s"; done)
[ -z "$WATCH_DIRS" ] && { echo "无可监控站点"; exit 1; }

WHITELIST=""
for s in $WATCH_DIRS; do
  while IFS= read -r p; do
    [ -n "$p" ] && WHITELIST="$WHITELIST $s/$p/"
  done < <(get_phpok "$s")
done

is_whitelisted() {
  local f="$1" w
  for w in $WHITELIST; do case "$f" in "$w"*) return 0;; esac; done
  return 1
}

# 判断一个文件是否应当被隔离
should_quarantine() {
  local f="$1"
  case "$f" in
    *.php|*.php5|*.php7|*.phtml|*.phar|*.pht|*.phps) ;;
    *) return 1 ;;
  esac
  [ -f "$f" ] || return 1
  is_whitelisted "$f" && return 1
  # 已加锁的原有文件属于受保护代码，正常
  lsattr -d "$f" 2>/dev/null | grep -q '^....i' && return 1
  return 0
}

# 隔离一个文件。$2 为来源标记（实时 / 定期扫描）
do_quarantine() {
  local f="$1" src="$2" base dest
  if [ -f "$MAINT" ]; then
    echo "$(ts) [维护模式-仅记录] 脚本文件变动($src): $f" >> "$ALERT"
    return
  fi
  base=$(basename "$f")
  dest="$QUAR/$(date +%Y%m%d-%H%M%S)-$$-$base"
  if mv "$f" "$dest" 2>/dev/null; then
    echo "$(ts) [拦截] 新增脚本已隔离($src): $f -> $dest" >> "$ALERT"
    logger -t suguang-webguard "拦截新增脚本($src) $f -> $dest"
  else
    echo "$(ts) [告警] 发现新增脚本但隔离失败($src): $f" >> "$ALERT"
    logger -t suguang-webguard "发现新增脚本但隔离失败($src) $f"
  fi
}

# ---------- 防线 2：定期全量扫描 ----------
sweeper() {
  local s f
  while true; do
    sleep "$SWEEP_INTERVAL"
    for s in $WATCH_DIRS; do
      [ -d "$s" ] || continue
      while IFS= read -r -d '' f; do
        should_quarantine "$f" && do_quarantine "$f" "定期扫描"
      done < <(find "$s" -type f \( -name '*.php' -o -name '*.php5' -o -name '*.php7' \
                 -o -name '*.phtml' -o -name '*.phar' -o -name '*.pht' -o -name '*.phps' \) \
                 -print0 2>/dev/null)
    done
  done
}

echo "$(ts) WATCH-START 监控: $(echo $WATCH_DIRS | tr '\n' ' ') (实时 + 每 ${SWEEP_INTERVAL}s 全量扫描)" >> "$ALERT"

sweeper &
SWEEP_PID=$!
trap 'kill $SWEEP_PID 2>/dev/null' EXIT INT TERM

# ---------- 防线 1：inotify 实时 ----------
inotifywait -mrq -e close_write -e moved_to --format '%w%f' $WATCH_DIRS 2>/dev/null \
| while read -r f; do
    should_quarantine "$f" && do_quarantine "$f" "实时"
  done
