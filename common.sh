#!/bin/bash
# SuguangWebGuard 公共库：配置解析、find 排除表达式、AIDE 配置生成
PREFIX=/www/SuguangWebGuard
CONF="${CONF:-$PREFIX/exclude.conf}"
LOGDIR=$PREFIX/logs
QUAR=$PREFIX/quarantine
AIDECONF=$PREFIX/aide.conf
AIDEDB=$PREFIX/aide.db.gz

# ---------------------------------------------------------------------------
# 隔离区结构（2026-09-13 重做）
#
#   quarantine/
#   └── 20260913-204710/                  一次隔离动作 = 一个批次目录
#       ├── manifest.tsv                  原路径│大小│md5│属主:组│权限│时间│来源
#       └── files/
#           └── www/wwwroot/
#               ├── bjuba.com.cn/index.php        完整路径镜像
#               └── bjuba.cn/index.php            同名，但不冲突
#
# 为什么是这个结构：旧版命名为「时间戳-PID-文件名」，只保留了 basename。
# 批量扫描时时间戳（秒级）和 PID 都是常量，不同站点的同名文件——index.php、
# config.php、app.php——目标名完全一致，mv 静默覆盖，先隔离的那个内容永久丢失。
# 2026-09-13 那次 26363 次隔离只剩下 24970 个文件，1285 个文件因此救不回来。
#
# 用完整路径做镜像，路径即身份，物理上不可能撞名；恢复时路径自带归属，
# 不需要去解析 alert.log —— manifest 跟着批次目录走，日志轮转也丢不了。
# ---------------------------------------------------------------------------

# 全系统统一北京时间（东八区），不跟随服务器自身时区。
# 云主机镜像默认多半是 UTC，那样告警日志会比现场人员的手表慢 8 小时——
# 事后对事故时间线时，差的这 8 小时足够把人绕晕。钉死在这里，
# 所有 source 了本文件的脚本（watch/lock/unlock/status/aide-check）一并生效。
export TZ=Asia/Shanghai

get_sites() { grep -E '^\s*SITE=' "$CONF" 2>/dev/null | sed 's/^\s*SITE=//' | tr -d '\r' | sed 's/\s*$//'; }

get_excludes() {
  awk -v want="$1" '
    /^[ \t]*SITE=/ { sub(/^[ \t]*SITE=/,""); gsub(/[ \t\r]+$/,""); cur=$0; next }
    /^[ \t]*EXCLUDE=/ { if (cur==want) { sub(/^[ \t]*EXCLUDE=/,""); gsub(/[ \t\r]+$/,""); print } }
  ' "$CONF" 2>/dev/null
}

get_phpok() {
  awk -v want="$1" '
    /^[ \t]*SITE=/ { sub(/^[ \t]*SITE=/,""); gsub(/[ \t\r]+$/,""); cur=$0; next }
    /^[ \t]*PHPOK=/ { if (cur==want) { sub(/^[ \t]*PHPOK=/,""); gsub(/[ \t\r]+$/,""); print } }
  ' "$CONF" 2>/dev/null
}

# 配置预检：找出「EXCLUDE 了、里面有 .php、却没有 PHPOK 覆盖」的目录
#
# 为什么这是个坑：EXCLUDE 只让 lock.sh 跳过加锁，**管不着监控隔离**。
# watch.sh 判断一个文件要不要隔离只看三件事——扩展名是不是脚本、在不在
# PHPOK 白名单、有没有 i 属性。于是这种目录最危险：里面的 .php 既没有锁
# 保护（被 EXCLUDE 了），又不在白名单，程序一写就被当成新增后门搬走。
#
# 这不是假想。织梦的 data/ 下就躺着 safequestions.php、downmix.data.php、
# enums/*.php 这些数据文件，帝国的 e/data/、ThinkPHP 的 runtime/ 同理。
# 实测漏配这一条，一个扫描周期内隔离掉 71 个文件，网站功能当场报错，
# 而告警日志里看起来就像"拦截了 71 个后门"——最坏的一种误报。
#
# 注意：这里刻意不看文件当前有没有 i 属性。它是**预检**，回答的是
# "按这份配置跑起来会怎样"；而按这份配置，EXCLUDE 目录里的文件本来就
# 不会被加锁。拿加锁现状当判据会在首次安装时漏报。
#
# 输出：每条隐患若干行说明；有隐患返回 1，无隐患返回 0（不输出）。
check_phpok_coverage() {
  local rc=0 s e d ok p f n examples covered
  for s in $(get_sites); do
    [ -d "$s" ] || continue
    ok=""
    while IFS= read -r p; do
      [ -n "$p" ] && ok="$ok $s/${p%/}"
    done < <(get_phpok "$s")

    while IFS= read -r e; do
      [ -n "$e" ] || continue
      d="$s/${e%/}"
      [ -d "$d" ] || continue
      n=0; examples=""
      while IFS= read -r f; do
        covered=0
        for p in $ok; do
          case "$f" in "$p"/*|"$p") covered=1; break;; esac
        done
        [ "$covered" = "1" ] && continue
        n=$((n+1))
        [ "$n" -le 3 ] && examples="$examples ${f#$d/}"
        [ "$n" -ge 200 ] && break
      done < <(find "$d" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.php5' \) 2>/dev/null)

      if [ "$n" -gt 0 ]; then
        rc=1
        [ "$n" -ge 200 ] && n="200+"
        echo "  [警告] $d"
        echo "         该目录已 EXCLUDE（不加锁），但其中 $n 个 .php 不在 PHPOK 白名单，"
        echo "         会被监控当成新增脚本隔离走。例如:$examples"
        echo "         确认是程序自带的文件，就补一行：PHPOK=${e%/}"
      fi
    done < <(get_excludes "$s")
  done
  return $rc
}

# 生成 find 的 prune 参数数组（写入全局 FIND_PRUNE）
build_prune() {
  local site="$1"; FIND_PRUNE=()
  local first=1 e
  while IFS= read -r e; do
    [ -z "$e" ] && continue
    if [ $first -eq 1 ]; then FIND_PRUNE+=( '(' '-path' "$site/$e" ); first=0
    else FIND_PRUNE+=( '-o' '-path' "$site/$e" ); fi
  done < <(get_excludes "$site")
  if [ $first -eq 0 ]; then FIND_PRUNE+=( ')' '-prune' '-o' ); fi
}

# 判断一个绝对路径是否落在「应加锁」范围内（即：属于某个 SITE，且不在它的
# 任何 EXCLUDE 目录之下）。restore.sh 据此决定恢复后要不要重新 chattr +i：
# 应锁范围内的文件恢复后必须加锁，否则守护下一轮扫描又会把它当新增脚本；
# 而 EXCLUDE 里的文件（data/runtime、storage 这些）绝不能加锁，一锁程序就写不动了。
in_lock_scope() {
  local f="$1" site e ex
  for site in $(get_sites); do
    case "$f" in "$site"/*) ;; *) continue ;; esac
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      ex="$site/${e%/}"
      case "$f" in "$ex"/*|"$ex") return 1 ;; esac
    done < <(get_excludes "$site")
    return 0
  done
  return 1
}

# 判断一个绝对路径是否在 PHPOK 白名单内（守护不会隔离白名单里的脚本）
in_phpok() {
  local f="$1" site p ok
  for site in $(get_sites); do
    case "$f" in "$site"/*) ;; *) continue ;; esac
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      ok="$site/${p%/}"
      case "$f" in "$ok"/*|"$ok") return 0 ;; esac
    done < <(get_phpok "$site")
    return 1
  done
  return 1
}

# 统计"应锁范围内"实际带 i 属性的文件数
count_locked() {
  local site="$1"
  build_prune "$site"
  find "$site" "${FIND_PRUNE[@]}" -type f -print0 2>/dev/null \
    | xargs -0 -r lsattr -d 2>/dev/null | grep -c '^....i'
}

# 根据 exclude.conf 生成 AIDE 配置，保证二者始终一致
# 说明：AIDE 的排除行是正则。此处不对点号做转义——未转义的 . 匹配任意字符，
#       对站点路径而言只是更宽泛的匹配，实际效果等价，且避免转义处理出错。
gen_aide_conf() {
  local sites; sites=$(get_sites)
  [ -n "$sites" ] || { echo "exclude.conf 中没有配置任何 SITE" >&2; return 1; }
  mkdir -p "$(dirname "$AIDECONF")"
  {
    echo "# 本文件由 /www/SuguangWebGuard/aide-init.sh 自动生成，请勿手工编辑"
    echo "# 生成时间: $(date '+%F %T')    来源: $CONF"
    echo "database=file:$AIDEDB"
    echo "database_out=file:/www/SuguangWebGuard/aide.db.new.gz"
    echo "gzip_dbout=yes"
    echo "report_url=file:$LOGDIR/aide-report.log"
    echo "report_url=stdout"
    echo ""
    # 刻意不校验 ctime（c）。lock.sh 的 chattr +i 会改掉每一个文件的 ctime，
    # 于是加锁当晚 AIDE 就报"10 万个文件全变了"——实测 100357 条差异里有
    # 100356 条只差 ctime，唯一真变的那 1 个反而被埋在里面翻不出来。
    # 一份没人看得下去的报告等于没有这道防线。
    # 内容篡改有 md5+sha256+s 兜住，权限属主变动有 p+u+g，文件被整体替换有 i，
    # 少一个 ctime 不漏检任何实质攻击行为。
    echo "# 校验项：权限+inode+链接数+属主+属组+大小+mtime+md5+sha256+文件类型"
    echo "WEBFILE = p+i+n+u+g+s+m+md5+sha256+ftype"
    echo ""
    local s e
    while IFS= read -r s; do
      [ -n "$s" ] && [ -d "$s" ] || continue
      echo "$s    WEBFILE"
      while IFS= read -r e; do
        [ -n "$e" ] && echo "!$s/$e"
      done < <(get_excludes "$s")
      echo ""
    done <<< "$sites"
  } > "$AIDECONF"
  chmod 600 "$AIDECONF"
}

need_root() { [ "$(id -u)" = "0" ] || { echo "必须用 root 运行"; exit 1; }; }
ts() { date '+%Y-%m-%d %H:%M:%S'; }
