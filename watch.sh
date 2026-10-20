#!/bin/bash
# 实时监控守护：拦截受保护站点中新出现的可执行脚本文件
#
# 两条独立防线：
#   1) inotify 实时监控 —— 毫秒级响应，但存在固有竞态：新建目录后立刻在其中写文件，
#      内核给新目录建立 watch 之前事件就已发生，会漏掉。
#   2) 定期全量扫描 —— 每 SWEEP_INTERVAL 秒兜底一次，把竞态窗口和 inotify 队列
#      溢出导致的漏网文件补捞回来。
#
# 降级策略：防线 1 起不来时（最常见的是 inotify 监视数超上限），不退出进程，
#           而是保留防线 2 继续运行并定期重试恢复。整体退出会连带停掉防线 2，
#           变成毫无防护的崩溃循环，比降级运行糟糕得多。
#
# ===================== 2026-09-13 事故后重写 =====================
# 那天这个守护在 5 分钟内把 26363 个正常文件搬进了隔离区，7 个站全部瘫痪。
# 根因不是判据写错了，而是**判据的前提没有被检查**：should_quarantine 以
# 「文件没有 +i 属性」为可疑依据，而 install.sh 是先启动守护、后加锁的，
# 加锁还默认关闭——于是守护上岗时全站 40371 个文件一个锁都没有，每一个
# 都是「可疑新增脚本」。
#
# 本次重写加了三道闸门，任何一道都足以拦下那天的灾难：
#   闸门 1  基线闸门：加锁覆盖率不足就拒绝隔离，只告警。
#   闸门 2  熔断闸门：单轮隔离数超阈值立即停手。真实入侵不会一次冒出几十个马，
#           到了这个量级几乎必然是判据失灵。
#   闸门 3  维护模式：.maintenance 存在时只记录不动手（unlock.sh 会创建）。
#
# 隔离区结构也一并重做。旧版命名是「时间戳-PID-文件名」，丢掉了完整路径，
# 结果同一秒内不同站点的同名文件（index.php / config.php / app.php）互相覆盖，
# 那天 26363 次隔离只剩下 24970 个文件，1285 个文件内容永久丢失。
# 新结构见 common.sh 顶部说明：批次目录 + 完整路径镜像 + manifest。
# =================================================================
. /www/SuguangWebGuard/common.sh
mkdir -p "$QUAR" "$LOGDIR"
ALERT=$LOGDIR/alert.log
MAINT=$PREFIX/.maintenance
FUSE_FLAG=$PREFIX/.fuse-tripped
SWEEP_INTERVAL=${SWEEP_INTERVAL:-60}

# 熔断阈值：单轮扫描（或实时监控累计）隔离数超过它就停止隔离。
# 20 这个值的依据：正常业务一轮 60 秒内不会新增 20 个未在白名单里的 .php；
# 而误判场景（基线丢失）一轮就是成千上万个。两者相差三个数量级，
# 阈值定在哪里都行，取小的更安全。
FUSE_LIMIT=${FUSE_LIMIT:-20}

# 基线覆盖率阈值（百分比）。低于它就认为加锁基线没建立好。
BASELINE_MIN=${BASELINE_MIN:-90}

# 「只记录」状态（维护模式 / 基线未就绪 / 熔断）下，单轮定期扫描最多逐条记录
# 多少个文件，其余汇总成一行。变量名沿用最初只管维护模式时的叫法。
MAINT_LOG_CAP=${MAINT_LOG_CAP:-200}

# ---------- 单实例保护 ----------
# 两个守护实例同时跑会互相拆台：.baseline-ok 是进程间共享的判定缓存，
# 另一个实例（尤其是拿不同 CONF 跑的临时实例）算出的结果会把它删掉，
# 正在服役的守护于是被静默压进纯告警模式 —— 看着在跑，实际不拦截。
#
# 这不是假想：2026-09-14 一次测试留下的实例，CONF 指向已删除的目录，
# 每轮算出「加锁数 0」，反复删掉标记，把生产守护的隔离功能关了两小时。
#
# 锁由 fd 9 持有，进程退出（含被 KILL）时内核自动释放；sweeper 子进程会
# 继承这个 fd，所以「主进程死了、sweeper 还在」的残留同样会被挡住 ——
# 那种情况本来就该让人知道，而不是让两个实例悄悄打架。
LOCKFILE=$PREFIX/.watch.lock
exec 9>"$LOCKFILE" || { echo "无法创建锁文件 $LOCKFILE" >&2; exit 1; }
if ! flock -w 10 9; then
  {
    echo "$(ts) [告警] 已有守护实例在运行，本次启动放弃"
    echo "         同时跑两个实例会互相覆盖基线判定缓存，反而让防护失效。"
    echo "         排查残留进程： ps -eo pid,lstart,cmd | grep [w]atch.sh"
    echo "         确认是残留后： kill -KILL <PID>，再 systemctl restart suguang-webguard-watch"
  } >> "$ALERT"
  echo "已有守护实例在运行，本次启动放弃（详见 $ALERT）" >&2
  exit 1
fi

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

# ---------- 闸门 1：基线闸门 ----------
# 隔离的判据是「没有 +i 属性」，这个判据只有在加锁基线已经建立时才成立。
# 基线没建立时全站文件都没有 +i，判据对每一个文件都返回真 —— 那不是防护，是删库。
#
# 判据取自 lock.sh 留下的基线快照，而不是现场计算加锁覆盖率。现算的分母是
# 当前文件总数，新增文件会把分母顶大：实测 100 个已锁文件的目录里突然出现
# 30 个新文件，覆盖率就掉到 77%，守护会误判成「基线没建立」而停止隔离 ——
# 等于攻击者一次多传些文件就能让防护自己关掉。拿加锁那一刻的数量当分母，
# 新增多少文件都影响不了这个判断。
#
# 结果同时落到 .baseline-ok 标记文件：sweeper 与 inotify 分处两个子进程，
# 变量互不可见；而 inotify 路径若每个事件都全量跑一次 lsattr 又太慢
# （3.5 万个文件每次 0.7 秒）。让 sweeper 每轮更新标记、inotify 只读标记，
# 两边判断一致，开销也可控。
BASEFILE=$PREFIX/.baseline
BASEOK=$PREFIX/.baseline-ok
BASE_WHY=""

baseline_ok() {
  local ref s total=0
  BASE_REF=0; BASE_HAVE=0; BASE_PCT=0
  if [ ! -f "$BASEFILE" ]; then
    BASE_WHY="从未成功执行过 lock.sh（找不到基线快照 $BASEFILE）"
    rm -f "$BASEOK"; return 1
  fi
  ref=$(awk -F= '$1=="locked"{print $2}' "$BASEFILE" 2>/dev/null | tr -d ' ')
  case "$ref" in ''|*[!0-9]*)
    BASE_WHY="基线快照损坏，请重新执行 lock.sh"
    rm -f "$BASEOK"; return 1 ;;
  esac
  if [ "$ref" -le 0 ]; then
    BASE_WHY="基线快照记录的加锁数为 0"
    rm -f "$BASEOK"; return 1
  fi
  for s in $WATCH_DIRS; do
    [ -d "$s" ] || continue
    total=$((total + $(count_locked "$s")))
  done
  BASE_REF=$ref; BASE_HAVE=$total
  BASE_PCT=$((total * 100 / ref))
  if [ "$BASE_PCT" -ge "$BASELINE_MIN" ]; then
    : > "$BASEOK"
    return 0
  fi
  BASE_WHY="加锁基线已被破坏：基线记录 $ref 个，现存 $total 个（${BASE_PCT}% < ${BASELINE_MIN}%）"
  rm -f "$BASEOK"
  return 1
}

# ---------- 闸门 2：熔断闸门 ----------
# 熔断状态用文件表示而不是变量：sweeper 与 inotify 分处两个子进程，
# 变量各改各的互不可见，只有落到磁盘上的标记才是两边都认的同一份状态。
fused() { [ -f "$FUSE_FLAG" ]; }

trip_fuse() {
  local n="$1" batch="$2"
  : > "$FUSE_FLAG"
  {
    echo "$(ts) [熔断] 本轮已隔离 $n 个文件，达到阈值 $FUSE_LIMIT，立即停止隔离"
    echo "         一次冒出这么多新脚本几乎不可能是真实入侵，更可能是加锁基线"
    echo "         被破坏（例如解锁后忘了重新加锁）。守护已转入纯告警模式，"
    echo "         在人工确认之前不会再移动任何文件。"
    echo "         已隔离的文件整批恢复："
    echo "           $PREFIX/restore.sh $batch"
    echo "         确认并重新加锁后解除熔断："
    echo "           rm -f $FUSE_FLAG && systemctl restart suguang-webguard-watch"
  } >> "$ALERT"
  logger -t suguang-webguard "熔断：单轮隔离数达到 $FUSE_LIMIT，已停止隔离，批次 $batch"
}

# ---------- 隔离批次 ----------
# 一次隔离动作 = 一个批次目录，惰性创建（真要隔离第一个文件时才建）。
BATCH_DIR=""
BATCH_ID=""
MANIFEST=""

batch_begin() {
  local n=1
  BATCH_ID=$(date +%Y%m%d-%H%M%S)
  BATCH_DIR="$QUAR/$BATCH_ID"
  # 同一秒内两个子进程各自开批次时加序号，保证目录唯一
  while ! mkdir "$BATCH_DIR" 2>/dev/null; do
    BATCH_ID="$(date +%Y%m%d-%H%M%S)-$n"
    BATCH_DIR="$QUAR/$BATCH_ID"
    n=$((n + 1))
    [ "$n" -gt 50 ] && { echo "$(ts) [错误] 无法创建隔离批次目录" >> "$ALERT"; return 1; }
  done
  mkdir -p "$BATCH_DIR/files" || return 1
  MANIFEST="$BATCH_DIR/manifest.tsv"
  {
    echo "# SuguangWebGuard 隔离批次 $BATCH_ID"
    echo "# 恢复整批: $PREFIX/restore.sh $BATCH_ID"
    echo "# 只恢复某个站: $PREFIX/restore.sh $BATCH_ID <站点目录名>"
    printf '#原路径\t大小\tmd5\t属主:属组\t权限\t隔离时间\t来源\n'
  } > "$MANIFEST"
  BATCH_COUNT=0
  return 0
}

# 当前是否处于「只记录、不移动文件」的状态（三道闸门任一不通过）
record_only() { [ -f "$MAINT" ] || [ ! -f "$BASEOK" ] || fused; }

# 隔离一个文件。$2 为来源标记（实时 / 定期扫描）
# $3=1 表示这个文件（同一 mtime）之前已经记过日志：只记录状态下不再重复记，
# 隔离失败也不再重复告警，但隔离动作照常重试。
#
# 路径镜像：/www/wwwroot/a/b.php  ->  $BATCH_DIR/files/www/wwwroot/a/b.php
# 完整路径就是文件的身份，不同站点的同名文件落在不同子目录，物理上不可能互相覆盖。
# 恢复时路径自带归属，不需要去翻 alert.log —— manifest 跟着批次目录走，
# 日志轮转也丢不了。
do_quarantine() {
  local f="$1" src="$2" dup="${3:-0}" dest sz md5 own perm
  # 三道闸门在这里统一把关。任何一道不通过就只记录，绝不动文件。
  if [ -f "$MAINT" ]; then
    [ "$dup" = "1" ] || echo "$(ts) [维护模式-仅记录] 新增脚本($src): $f" >> "$ALERT"
    return 0
  fi
  if [ ! -f "$BASEOK" ]; then
    [ "$dup" = "1" ] || echo "$(ts) [基线未就绪-仅记录] 新增脚本($src): $f" >> "$ALERT"
    return 0
  fi
  if fused; then
    [ "$dup" = "1" ] || echo "$(ts) [熔断-仅记录] 新增脚本($src): $f" >> "$ALERT"
    return 0
  fi
  [ -n "$BATCH_DIR" ] || batch_begin || return 1

  dest="$BATCH_DIR/files$f"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || {
    [ "$dup" = "1" ] || echo "$(ts) [告警] 无法创建隔离目录，未移动文件($src): $f" >> "$ALERT"
    return 1
  }
  # 元数据必须在 mv 之前采集 —— 文件一旦搬走，原路径上什么都没有了
  sz=$(stat -c %s "$f" 2>/dev/null)
  md5=$(md5sum "$f" 2>/dev/null | awk '{print $1}')
  own=$(stat -c %U:%G "$f" 2>/dev/null)
  perm=$(stat -c %a "$f" 2>/dev/null)

  if mv "$f" "$dest" 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$f" "${sz:-0}" "${md5:-?}" "${own:-?}" "${perm:-644}" "$(ts)" "$src" >> "$MANIFEST"
    echo "$(ts) [拦截] 新增脚本已隔离($src): $f -> $BATCH_ID" >> "$ALERT"
    logger -t suguang-webguard "拦截新增脚本($src) $f 批次 $BATCH_ID"
    BATCH_COUNT=$((BATCH_COUNT + 1))
    if [ "$BATCH_COUNT" -ge "$FUSE_LIMIT" ]; then
      trip_fuse "$BATCH_COUNT" "$BATCH_ID"
    fi
    return 0
  fi
  [ "$dup" = "1" ] && return 1
  echo "$(ts) [告警] 发现新增脚本但隔离失败($src): $f" >> "$ALERT"
  logger -t suguang-webguard "发现新增脚本但隔离失败($src) $f"
  return 1
}

# ---------- 防线 2：定期全量扫描 ----------
# 性能要点：不要对每个文件单独 fork lsattr。实测 4.8 万个 php 单独 fork 要 68 秒，
# 比 SWEEP_INTERVAL 还长；交给 xargs 批量执行只要 0.7 秒。先滤掉已加锁的文件
# ——它们是受保护的原有代码，本来就改不动——剩下的才逐个判断。
#
# 日志量控制：「只记录」状态下（维护模式 / 基线未就绪 / 熔断）全站脚本都可能
# 没有 +i，原先每轮扫描都把它们全部记一遍。2026-10 一台 26 个站约 15 万个文件
# 的服务器忘了加锁，5 天写出 18G 的 alert.log，磁盘写满、MySQL 停摆。现在：
#   - 维护模式只看 .maintenance 之后改过的文件（find -newer），没动过的不记；
#   - 同一文件同一 mtime 只记一次（SEEN 去重），隔离失败的告警同样不重复刷；
#   - 只记录状态下单轮最多逐条记 MAINT_LOG_CAP 条，其余汇总成一行。
# 正常隔离不受去重和上限影响（失败的文件下一轮照常重试），有熔断闸门兜底。
#
# 读循环用 < <(...) 而不是管道：管道右侧是子 shell，SEEN 和批次变量在里面改了
# 带不出来。顺带也让一轮扫描真正只有一个批次、熔断按「整轮」计数，与上面
# 「每轮一个新批次」的设计一致（管道写法下每个站点各开一个批次、各计各的）。
sweeper() {
  local s line f key dup ro state last_state="" n_log n_more
  local -a newer
  local -A SEEN=()
  while true; do
    sleep "$SWEEP_INTERVAL"

    # 每轮开始前重新确认基线，并刷新 .baseline-ok 标记（inotify 子进程也读它）。
    # 基线可能在运行期间被破坏：有人手工 chattr -i、或跑了 unlock.sh 没跑 lock.sh。
    if ! baseline_ok; then
      if [ "$BASE_WARNED" != "1" ]; then
        {
          echo "$(ts) [告警] 加锁基线不可用，隔离已暂停，只记录不移动文件"
          echo "         原因: $BASE_WHY"
          echo "         请执行: $PREFIX/lock.sh"
        } >> "$ALERT"
        logger -t suguang-webguard "加锁基线不可用($BASE_WHY)，隔离已暂停"
        BASE_WARNED=1
      fi
    elif [ "$BASE_WARNED" = "1" ]; then
      echo "$(ts) [恢复] 加锁基线已就绪（基线 $BASE_REF / 现存 $BASE_HAVE），隔离功能恢复" >> "$ALERT"
      BASE_WARNED=0
    fi

    # 每轮一个新批次：批次即「一次隔离动作」，也是熔断计数的单位
    BATCH_DIR=""; BATCH_ID=""; MANIFEST=""; BATCH_COUNT=0

    # 闸门状态变化（进出维护模式、基线恢复或丢失、熔断）时清空去重表，
    # 让新状态下的情况重新完整记录一次；表过大时也清空，防止内存上涨
    state="$([ -f "$MAINT" ] && echo M)$([ -f "$BASEOK" ] || echo B)$(fused && echo F)"
    if [ "$state" != "$last_state" ] || [ "${#SEEN[@]}" -gt 50000 ]; then
      SEEN=()
      last_state=$state
    fi
    newer=(); [ -f "$MAINT" ] && newer=(-newer "$MAINT")
    n_log=0; n_more=0

    for s in $WATCH_DIRS; do
      [ -d "$s" ] || continue
      while IFS= read -r line; do
        # lsattr 输出形如 "----i--------e-- /路径"，第 5 位是 immutable
        case "$line" in ????i*) continue;; esac
        f=${line#* }                                   # 去掉属性字段
        while [ "$f" != "${f# }" ]; do f=${f# }; done   # 去掉多余前导空格
        [ -n "$f" ] || continue
        should_quarantine "$f" || continue
        key="$f|$(stat -c %Y "$f" 2>/dev/null)"
        dup=0; [ -n "${SEEN[$key]}" ] && dup=1
        SEEN[$key]=1
        ro=0; record_only && ro=1
        if [ "$ro" = "1" ]; then
          [ "$dup" = "1" ] && continue
          if [ "$n_log" -ge "$MAINT_LOG_CAP" ]; then n_more=$((n_more + 1)); continue; fi
          n_log=$((n_log + 1))
        fi
        do_quarantine "$f" "定期扫描" "$dup"
      done < <(find "$s" -type f \( -name '*.php' -o -name '*.php5' -o -name '*.php7' \
                 -o -name '*.phtml' -o -name '*.phar' -o -name '*.pht' -o -name '*.phps' \) \
                 "${newer[@]}" -print0 2>/dev/null \
               | xargs -0 -r lsattr -d 2>/dev/null)
    done
    [ "$n_more" -gt 0 ] && echo "$(ts) [仅记录] 本轮另有 $n_more 个新增脚本未逐条记录（单轮上限 $MAINT_LOG_CAP 条，同一文件不重复记录）" >> "$ALERT"
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

# ---------- 启动自检 ----------
echo "$(ts) WATCH-START 监控: $(echo $WATCH_DIRS | tr '\n' ' ') (实时 + 每 ${SWEEP_INTERVAL}s 全量扫描)" >> "$ALERT"

# 熔断标记的处理：如果基线已经恢复正常，说明上次熔断的原因（基线丢失）已排除，
# 自动解除；否则保留，避免「重启一下就又能搬文件了」这种危险的自愈。
BASE_WARNED=0
if baseline_ok; then
  if fused; then
    rm -f "$FUSE_FLAG"
    echo "$(ts) [恢复] 基线已就绪（基线 $BASE_REF / 现存 $BASE_HAVE），自动解除熔断" >> "$ALERT"
  fi
  echo "$(ts) [自检] 加锁基线正常: 基线 $BASE_REF / 现存 $BASE_HAVE (${BASE_PCT}%)，隔离功能已启用" >> "$ALERT"
else
  BASE_WARNED=1
  {
    echo "$(ts) [告警] 加锁基线不可用，守护以【纯告警模式】启动，不会移动任何文件"
    echo "         原因: $BASE_WHY"
    echo "         请先执行 $PREFIX/lock.sh 建立基线，隔离功能会在下一轮扫描自动恢复。"
  } >> "$ALERT"
  logger -t suguang-webguard "基线不可用($BASE_WHY)，以纯告警模式启动"
fi
[ -f "$MAINT" ] && echo "$(ts) [自检] 维护模式开启中，本次只记录不移动文件" >> "$ALERT"

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
    # .baseline-ok 只是本进程判断结果的缓存，守护不在跑的时候它没有意义，
    # 留着反而会让下次启动在算出结果之前短暂地「看起来基线是好的」。
    rm -f "$ERRF" "$BASEOK"
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
RETRY=${INOTIFY_RETRY:-300}
DEGRADED=0
while true; do
    if inotify_capacity; then
        [ "$DEGRADED" = "1" ] && {
            echo "$(ts) [恢复] inotify 容量已满足（目录 $INO_NEED / 上限 $INO_CUR），恢复实时监控" >> "$ALERT"
            DEGRADED=0
        }
        : > "$ERRF"
        # 实时路径自己维护一个批次。它是长驻的，不像 sweeper 每轮重开，
        # 所以熔断计数在这里是「累计」语义 —— 达到阈值同样停手。
        BATCH_DIR=""; BATCH_ID=""; MANIFEST=""; BATCH_COUNT=0
        # 实时侧同样按「文件+mtime」去重，同一次改动不重复记录
        declare -A RT_SEEN=()
        inotifywait -mrq -e close_write -e moved_to --format '%w%f' $WATCH_DIRS 2>"$ERRF" \
        | while read -r f; do
            should_quarantine "$f" || continue
            [ "${#RT_SEEN[@]}" -gt 50000 ] && RT_SEEN=()
            key="$f|$(stat -c %Y "$f" 2>/dev/null)"
            dup=0; [ -n "${RT_SEEN[$key]}" ] && dup=1
            RT_SEEN[$key]=1
            do_quarantine "$f" "实时" "$dup"
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
