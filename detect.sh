#!/bin/bash
# 探测站点需要保持可写的目录，输出可粘贴进 exclude.conf 的配置片段
# 用法: detect.sh <站点根目录> [天数,默认90]
#
# 判定证据（命中任一即"确定排除"）：
#   1) 整条路径命中常见可写目录白名单（static/upload、e/data、runtime ...）
#   2) 末级目录名明确是上传/附件目录
#   3) 近 N 天有 >=3 个文件被写入（程序在持续写）
#   4) 近 N 天被写入的文件里有**非代码文件**（.db/.log/.xml/图片/无扩展名等）
#      —— 区分"程序在写数据"和"人工改了几个 .php"的关键判据
# 其余只有少量代码文件改动、或仅目录名像运行时目录的，输出为注释行待人工确认。
#
# 设计取舍：宁可漏排（网站报错，可见且可修）也不多排（静默留下攻击面）。
set -u
S="${1:-}"; DAYS="${2:-90}"; MIN_FILES=3
[ -n "$S" ] && [ -d "$S" ] || { echo "用法: $0 <站点根目录> [天数]" >&2; exit 1; }
S="${S%/}"

STRONG_PATH='^(static/upload|static/backup|public/upload|public/uploads|uploads|upload|e/data|d/file|wp-content/uploads|data/sessions|application/runtime|storage/framework|runtime)$'
STRONG_BASE='^(upload|uploads|uploadfile|uploadfiles|attachment|attachments)$'
WEAK_BASE='^(runtime|cache|caches|temp|tmp|session|sessions|log|logs|backup|backups|data|thumb|thumbs)$'
CODE_EXT='\.(php|php[357]|phtml|phar|inc|html?|js|css|ini)$'

is_strong(){ echo "$1" | grep -qE "$STRONG_PATH" && return 0; echo "${1##*/}" | grep -qE "$STRONG_BASE"; }
is_weak(){ echo "${1##*/}" | grep -qE "$WEAK_BASE"; }
has_data_write(){ find "$S/$1" -maxdepth 2 -type f -mtime "-$DAYS" 2>/dev/null | grep -qivE "$CODE_EXT"; }

MAP=$(find "$S" -type f -mtime "-$DAYS" 2>/dev/null | sed "s|^$S/||" \
      | awk -F/ 'NF>1{print $1"/"$2} NF==1{print "@ROOT@"}' | sort | uniq -c | sort -rn)

echo ""
echo "SITE=$S"
echo "# ===== 探测于 $(date '+%F %T')，回溯 ${DAYS} 天 ====="
if [ -n "$MAP" ]; then
  echo "# 写入分布（文件数 路径）："
  echo "$MAP" | sed 's/@ROOT@/(站点根目录下的文件)/' | sed 's/^/#   /'
else
  echo "# 近 ${DAYS} 天无文件写入"
fi

TA=$(mktemp); TQ=$(mktemp); trap 'rm -f "$TA" "$TQ"' EXIT

echo "$MAP" | while read -r cnt path; do
  [ -n "${path:-}" ] || continue
  [ "$path" = "@ROOT@" ] && continue
  if [ ! -d "$S/$path" ]; then path="${path%%/*}"; [ -d "$S/$path" ] || continue; fi
  top="${path%%/*}"
  if   is_strong "$path";           then echo "$path" >> "$TA"
  elif is_strong "$top";            then echo "$top"  >> "$TA"
  elif [ "$cnt" -ge "$MIN_FILES" ]; then echo "$path" >> "$TA"
  elif has_data_write "$path";      then echo "$path" >> "$TA"
  else echo "$cnt|$path" >> "$TQ"
  fi
done

find "$S" -maxdepth 2 -type d 2>/dev/null | sed "s|^$S/\{0,1\}||" | grep -v '^$' \
| while read -r d; do
    grep -qxF "$d" "$TA" 2>/dev/null && continue
    if is_strong "$d"; then echo "$d" >> "$TA"; elif is_weak "$d"; then echo "0|$d" >> "$TQ"; fi
  done

[ -d "$S/.well-known" ] && echo ".well-known" >> "$TA"

FINAL=$(sort -u "$TA" 2>/dev/null | awk '{print length"\t"$0}' | sort -n | cut -f2- | awk '
  { keep=1; for (i=0;i<n;i++) if (index($0"/", kept[i]"/")==1) keep=0
    if (keep) { kept[n++]=$0; print } }')

echo "# --- 保持可写（不加锁）---"
if [ -n "$FINAL" ]; then echo "$FINAL" | sed 's/^/EXCLUDE=/'; else echo "# （无，可整站加锁）"; fi

echo "# --- 允许程序在此生成 .php（监控白名单）---"
PHPOKS=$(echo "$FINAL" | while read -r d; do
  [ -n "$d" ] && [ -d "$S/$d" ] || continue
  subs=$(find "$S/$d" -maxdepth 3 -name '*.php' -type f 2>/dev/null | head -300 \
         | while read -r hit; do dirname "${hit#$S/}"; done | sort -u)
  n=$(echo "$subs" | grep -c '[^[:space:]]')
  if   [ "$n" -eq 0 ]; then :
  elif [ "$n" -gt 5 ]; then echo "$d"
  else echo "$subs"
  fi
done | sort -u | grep -v '^$')
if [ -n "$PHPOKS" ]; then echo "$PHPOKS" | sed 's/^/PHPOK=/'; else echo "# （无）"; fi

if [ -s "$TQ" ]; then
  Q=$(sort -t'|' -k2,2 -k1,1nr "$TQ" | awk -F'|' '!seen[$2]++' | while IFS='|' read -r c p; do
        covered=0
        while read -r f; do [ -n "$f" ] && case "$p/" in "$f/"*) covered=1;; esac; done <<< "$FINAL"
        [ "$covered" = "0" ] && echo "$c|$p"
      done)
  if [ -n "$Q" ]; then
    echo "#"
    echo "# !!!!!!!!!!!!!!!! 以下需要你人工确认 !!!!!!!!!!!!!!!!"
    echo "# 这些目录只有少量代码文件被改动，或仅目录名像运行时目录。"
    echo "# 可能是：低频业务写入 / 管理员手工改动 / 入侵痕迹。"
    echo "# 确属程序需要持续写入的 → 去掉行首 # 号；不确定就保持注释（纳入保护，更安全）。"
    echo "$Q" | sort -t'|' -k1,1nr | while IFS='|' read -r c p; do
      if [ "$c" = "0" ]; then
        echo "# EXCLUDE=$p    # 近 ${DAYS} 天无写入，仅目录名像运行时目录（可能只是源码目录）"
      else
        echo "# EXCLUDE=$p    # 近 ${DAYS} 天仅 $c 个代码文件被改动，请确认来源"
      fi
    done
  fi
fi
echo ""
