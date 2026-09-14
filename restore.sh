#!/bin/bash
# 从隔离区恢复文件到原路径
#
# 用法:
#   restore.sh --list                       列出所有隔离批次
#   restore.sh <批次>                        恢复整批
#   restore.sh <批次> <站点目录名>            只恢复该站点的文件
#   restore.sh <批次> --verify               只校验不恢复（看看内容还在不在、对不对）
#   restore.sh <批次> [站点] --dry-run        演练，打印将要做什么但不动手
#
# 恢复的依据是批次目录里的 manifest.tsv，不依赖 alert.log —— manifest 跟着
# 批次目录走，日志轮转、清理都不会把恢复能力带走。
#
# 安全约束：
#   * 原路径已存在文件时【跳过并报冲突】，绝不覆盖
#   * 恢复前逐个校验 md5，内容对不上的单独列出来，不静默恢复坏内容
#   * 属主、权限按 manifest 原样还原
#   * 应加锁范围内的文件恢复后自动 chattr +i（否则守护下一轮又给隔离了）
#   * 全程把守护置于维护模式，避免边恢复边被重新隔离
. /www/SuguangWebGuard/common.sh
need_root

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# 从一条绝对路径里取出「站点目录名」。按 exclude.conf 里的 SITE 动态剥离，
# 而不是写死 /www/wwwroot/ —— SITE 可以是任意路径，写死前缀在别的部署上会取空。
site_of() {
  local p="$1" s
  for s in $(get_sites); do
    case "$p" in "$s"/*) printf '%s\n' "${p#"$s"/}" | cut -d/ -f1; return ;; esac
  done
  # 配置里已经没有对应的 SITE 了（站点被移出配置），退回到取路径的第 4 段
  printf '%s\n' "$p" | awk -F/ '{print $4}'
}

BATCH=""; FILTER=""; VERIFY=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l)  LIST=1 ;;
    --verify)   VERIFY=1 ;;
    --dry-run)  DRY=1 ;;
    -h|--help)  usage ;;
    -*)         echo "未知参数: $1（--help 查看用法）" >&2; exit 1 ;;
    *)          if [ -z "$BATCH" ]; then BATCH="$1"; else FILTER="$1"; fi ;;
  esac
  shift
done

# ---------- 列出批次 ----------
if [ "${LIST:-0}" = "1" ] || [ -z "$BATCH" ]; then
  echo "隔离批次一览  ($QUAR)"
  echo "------------------------------------------------------------------"
  found=0
  for d in "$QUAR"/*/; do
    [ -f "$d/manifest.tsv" ] || continue
    found=1
    id=$(basename "$d")
    n=$(grep -vc '^#' "$d/manifest.tsv" 2>/dev/null)
    left=$(find "$d/files" -type f 2>/dev/null | wc -l)
    sites=$(grep -v '^#' "$d/manifest.tsv" 2>/dev/null | cut -f1 \
            | while IFS= read -r p; do [ -n "$p" ] && site_of "$p"; done \
            | sort -u | tr '\n' ' ')
    when=$(grep -v '^#' "$d/manifest.tsv" 2>/dev/null | head -1 | cut -f6)
    printf "%-22s 记录 %-6s 待恢复 %-6s %s\n" "$id" "$n" "$left" "${when:-}"
    printf "%-22s 涉及站点: %s\n" "" "${sites:-(无)}"
  done
  [ "$found" = "0" ] && echo "（隔离区为空）"
  echo "------------------------------------------------------------------"
  echo "恢复整批:   $0 <批次>"
  echo "按站恢复:   $0 <批次> <站点目录名>"
  exit 0
fi

DIR="$QUAR/$BATCH"
MAN="$DIR/manifest.tsv"
[ -d "$DIR" ] || { echo "批次不存在: $BATCH（用 --list 查看）" >&2; exit 1; }
[ -f "$MAN" ] || { echo "批次缺少 manifest.tsv，无法恢复: $BATCH" >&2; exit 1; }

echo "批次: $BATCH"
[ -n "$FILTER" ] && echo "只处理站点: $FILTER"
[ "$VERIFY" = "1" ] && echo "模式: 仅校验"
[ "$DRY" = "1" ] && echo "模式: 演练（不会真的动文件）"
echo

# 恢复期间把守护挡在维护模式外面。直接停服务也行，但那会连带停掉防线 2，
# 而且中途出错就可能忘了起回来；维护模式是可逆且自解释的。
MAINT="$PREFIX/.maintenance"
MAINT_WAS=0
[ -f "$MAINT" ] && MAINT_WAS=1
if [ "$MAINT_WAS" = "0" ] && [ "$DRY" = "0" ] && [ "$VERIFY" = "0" ]; then
  touch "$MAINT"
  trap 'rm -f "$MAINT"' EXIT
fi

ok=0; conflict=0; badmd5=0; missing=0; skipped=0; locked=0
CONFLICTS=""; BADMD5=""; PHPOK_HINT=""

while IFS=$'\t' read -r src size md5 own perm when src_tag; do
  case "$src" in '#'*|'') continue ;; esac
  [ -n "$FILTER" ] && { case "$src" in */"$FILTER"/*) ;; *) skipped=$((skipped+1)); continue ;; esac; }

  qf="$DIR/files$src"
  if [ ! -f "$qf" ]; then
    missing=$((missing+1)); continue
  fi

  # 内容校验：manifest 记的 md5 就是隔离那一刻的内容指纹
  if [ -n "$md5" ] && [ "$md5" != "?" ]; then
    cur=$(md5sum "$qf" 2>/dev/null | awk '{print $1}')
    if [ "$cur" != "$md5" ]; then
      badmd5=$((badmd5+1))
      BADMD5="$BADMD5
  $src"
      continue
    fi
  fi

  [ "$VERIFY" = "1" ] && { ok=$((ok+1)); continue; }

  # 原路径已有文件 —— 可能是恢复过了，也可能是程序又生成了同名文件。
  # 两种情况都不该覆盖：覆盖是不可逆的，而跳过随时可以人工处理。
  if [ -e "$src" ]; then
    conflict=$((conflict+1))
    CONFLICTS="$CONFLICTS
  $src"
    continue
  fi

  if [ "$DRY" = "1" ]; then
    echo "  [演练] 将恢复 $src"
    ok=$((ok+1)); continue
  fi

  d=$(dirname "$src")
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  if ! mv "$qf" "$src" 2>/dev/null; then
    echo "  [失败] $src"
    continue
  fi
  [ -n "$own" ] && [ "$own" != "?" ] && chown "$own" "$src" 2>/dev/null
  [ -n "$perm" ] && [ "$perm" != "?" ] && chmod "$perm" "$src" 2>/dev/null

  # 应锁范围内的文件必须重新加锁，否则守护下一轮扫描会把它再隔离一次
  if in_lock_scope "$src"; then
    chattr +i "$src" 2>/dev/null && locked=$((locked+1))
  elif ! in_phpok "$src"; then
    # EXCLUDE 目录里、又不在 PHPOK 白名单 —— 这类文件不能加锁（一锁程序就写不动），
    # 但不加锁守护又会再次隔离它。唯一的出路是把它的目录补进 PHPOK。
    PHPOK_HINT="$PHPOK_HINT
  $src"
  fi
  echo "$(ts) RESTORE $src (批次 $BATCH)" >> "$LOGDIR/action.log"
  ok=$((ok+1))
done < "$MAN"

echo "----------------------------------------"
if [ "$VERIFY" = "1" ]; then
  echo "校验通过 : $ok"
else
  echo "已恢复   : $ok    （其中重新加锁 $locked 个）"
fi
[ "$conflict" -gt 0 ] && echo "原路径已存在，跳过: $conflict"
[ "$badmd5"  -gt 0 ] && echo "内容校验失败      : $badmd5"
[ "$missing" -gt 0 ] && echo "隔离区中已不存在  : $missing"
[ "$skipped" -gt 0 ] && echo "不属于该站点，跳过: $skipped"

[ -n "$CONFLICTS" ] && { echo; echo "以下文件原路径已有内容，未覆盖（请人工确认后处理）:"; echo "$CONFLICTS"; }
[ -n "$BADMD5" ] && { echo; echo "以下文件内容与隔离时记录的 md5 不符，未恢复:"; echo "$BADMD5"; }
[ -n "$PHPOK_HINT" ] && {
  echo
  echo "以下文件位于 EXCLUDE 目录内且不在 PHPOK 白名单，守护可能再次隔离它们。"
  echo "确认是程序自带/自动生成的文件后，请在 exclude.conf 里补 PHPOK= 对应目录:"
  echo "$PHPOK_HINT"
}

if [ "$VERIFY" = "0" ] && [ "$DRY" = "0" ] && [ "$ok" -gt 0 ]; then
  echo
  echo "提示: 剩余未恢复的文件仍在 $DIR/files 下，批次目录与 manifest 保留作为记录。"
fi
exit 0
