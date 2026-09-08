#!/bin/bash
# SuguangWebGuard 公共库：配置解析、find 排除表达式、AIDE 配置生成
CONF="${CONF:-/www/SuguangWebGuard/exclude.conf}"
LOGDIR=/www/SuguangWebGuard/logs
QUAR=/www/SuguangWebGuard/quarantine
AIDECONF=/www/SuguangWebGuard/aide.conf
AIDEDB=/www/SuguangWebGuard/aide.db.gz

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
    echo "# 校验项：权限+inode+链接数+属主+属组+大小+mtime+ctime+md5+sha256+文件类型"
    echo "WEBFILE = p+i+n+u+g+s+m+c+md5+sha256+ftype"
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
