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
# 降级策略：防线 1 起不来时（最常见的是 inotify 监视数超上限），不退出进程，
#           而是保留防线 2 继续运行并定期重试恢复。整体退出会连带停掉防线 2，
#           变成毫无防护的崩溃循环，比降级运行糟糕得多。
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
# 性能要点：原先对 find 出来的每个文件单独 fork 一次 lsattr。实测 4.8 万个 php
# 文件要 68 秒，扫描一轮比 SWEEP_INTERVAL 还长，兜底延迟实际是 2 分钟以上。
# 改为交给 xargs 批量执行 lsattr（同样 4.8 万个文件仅 0.7 秒），先滤掉已加锁的
# 文件——它们是受保护的原有代码，本来就改不动——剩下的才逐个判断。
sweeper() {
  local s line f
  while true; do
    sleep "$SWEEP_INTERVAL"
    for s in $WATCH_DIRS; do
      [ -d "$s" ] || continue
      find "$s" -type f \( -name '*.php' -o -name '*.php5' -o -name '*.php7' \
             -o -name '*.phtml' -o -name '*.phar' -o -name '*.pht' -o -name '*.phps' \) \
             -print0 2>/dev/null \
        | xargs -0 -r lsattr -d 2>/dev/null \
        | while IFS= read -r line; do
            # lsattr 输出形如 "----i--------e-- /路径"，第 5 位是 immutable
            case "$line" in ????i*) continue;; esac
            f=${line#* }                                   # 去掉属性字段
            while [ "$f" != "${f# }" ]; do f=${f# }; done   # 去掉多余前导空格
            [ -n "$f" ] || continue
            should_quarantine "$f" && do_quarantine "$f" "定期扫描"
          done
    done
  done
}

# ---------- inotify 监视数预检 ----------
# 内核给每个被监视的目录占用一个 watch，超出 fs.inotify.max_user_watches
# （默认仅 8192）时 inotifywait 会直接失败退出。站点目录上万很容易踩到。
inotify_capacity() {
    local need cur
    need=$(for s in $WATCH_DIRS; do find "$s" -type d 2>/dev/null; done | wc -l | tr -d ' ')
    cur=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    INO_NEED=$need
    INO_CUR=$cur
    [ "$cur" -gt 0 ] || return 0            # 读不到就不拦，交给 inotifywait 自己报错
    # 留 20% 余量：同机器上其他进程（编辑器、备份工具等）也在占用配额
    [ "$need" -lt $((cur * 8 / 10)) ]
}

echo "$(ts) WATCH-START 监控: $(echo $WATCH_DIRS | tr '\n' ' ') (实时 + 每 ${SWEEP_INTERVAL}s 全量扫描)" >> "$ALERT"

sweeper &
SWEEP_PID=$!
ERRF=$(mktemp /tmp/swg-inotify.XXXXXX)
SLEEP_PID=""

# 注意：TERM 的处理函数必须显式 exit。主体是 while true 循环，若 trap 只做清理
# 不退出，收到 SIGTERM 后脚本会继续循环，systemd 停不掉它，只能等 90 秒超时后
# SIGKILL——表现为 systemctl restart 卡住并把服务标成 failed。
cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    kill "$SWEEP_PID" 2>/dev/null
    rm -f "$ERRF"
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# 可被信号打断的等待。直接用 sleep 的话 bash 会等前台命令结束才处理 trap，
# 停服务最多要多等 RETRY 秒。
nap() {
    sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
}

# ---------- 防线 1：inotify 实时 ----------
# 关键：inotifywait 的 stderr 必须留存并写进日志。此前这里是 2>/dev/null，
# 「watch 数超上限」之类的致命错误被吞掉，systemd 只看到进程退出、退出码 0，
# 日志一片空白，表现成莫名其妙的崩溃重启，排查时完全无从下手。
#
# 另外：实时监控起不来时不再整个退出。退出会连带 trap 掉定期扫描，
# 结果是「一点防护都没有」的崩溃循环。改为降级运行——保留每
# SWEEP_INTERVAL 秒的全量扫描，同时每 RETRY 秒重试恢复实时监控。
RETRY=${INOTIFY_RETRY:-300}
DEGRADED=0
while true; do
    if inotify_capacity; then
        [ "$DEGRADED" = "1" ] && {
            echo "$(ts) [恢复] inotify 容量已满足（目录 $INO_NEED / 上限 $INO_CUR），恢复实时监控" >> "$ALERT"
            DEGRADED=0
        }
        : > "$ERRF"
        inotifywait -mrq -e close_write -e moved_to --format '%w%f' $WATCH_DIRS 2>"$ERRF" \
        | while read -r f; do
            should_quarantine "$f" && do_quarantine "$f" "实时"
          done
        rc=${PIPESTATUS[0]}
        # 能走到这里就说明 inotifywait 已经退出，把它临终说的话记下来
        while IFS= read -r line; do
            [ -n "$line" ] && echo "$(ts) [inotify错误] $line" >> "$ALERT"
        done < "$ERRF"
        echo "$(ts) [告警] 实时监控中断(退出码 $rc)，降级为每 ${SWEEP_INTERVAL}s 全量扫描，${RETRY}s 后重试" >> "$ALERT"
        logger -t suguang-webguard "实时监控中断(rc=$rc)，已降级为定期扫描"
        DEGRADED=1
    elif [ "$DEGRADED" = "0" ]; then
        # 只在状态变化时打完整提示，避免每次重试都刷屏
        {
            echo "$(ts) [告警] inotify 监视数不足，实时监控无法启动"
            echo "         需监视目录数: $INO_NEED"
            echo "         当前上限     : $INO_CUR  (fs.inotify.max_user_watches)"
            echo "         现已降级为每 ${SWEEP_INTERVAL}s 全量扫描，防护仍然有效但延迟变大。"
            echo "         永久解决（root 执行）："
            echo "           echo 'fs.inotify.max_user_watches = 524288'  > /etc/sysctl.d/99-suguang-webguard.conf"
            echo "           echo 'fs.inotify.max_user_instances = 512'  >> /etc/sysctl.d/99-suguang-webguard.conf"
            echo "           sysctl -p /etc/sysctl.d/99-suguang-webguard.conf"
            echo "           systemctl restart suguang-webguard-watch"
        } >> "$ALERT"
        logger -t suguang-webguard "inotify 监视数不足($INO_NEED>$INO_CUR)，已降级为定期扫描"
        DEGRADED=1
    fi
    nap "$RETRY"
done
