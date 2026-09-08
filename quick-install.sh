#!/bin/bash
# ============================================================
# SuguangWebGuard 网站防篡改系统 · 一键安装引导脚本
# 速光网络软件开发  https://suguang.cc
#
# 用法（在服务器上以 root 执行）：
#
#   curl -fsSL https://raw.githubusercontent.com/suguangnet/SuguangWebGuard/main/quick-install.sh \
#     | bash -s -- --site /www/wwwroot/你的站点
#
# 本脚本只负责「取回代码 + 校验完整性 + 调用 install.sh」，
# 真正的安装逻辑全在 install.sh 里。
#
# 本脚本自己的参数：
#   --ref <分支或标签>   指定版本，默认 main。生产环境建议指定 tag 而非 main
#   --mirror <前缀>      通过镜像下载，例如 --mirror https://ghfast.top/
#                        （--mirror auto 依次尝试内置镜像列表）
#   --src-dir <路径>     源码解压位置，默认 /root/SuguangWebGuard-src
#   --keep-src           保留源码目录（默认也保留，便于以后升级/卸载）
#   --download-only      只下载不安装
#   --help               显示帮助
#
# 其余参数原样透传给 install.sh，常用的有：
#   --site <站点路径>  --port <端口>  --lock  --yes  --no-web  --no-aide
#   完整说明见 README.md 或 install.sh --help
# ============================================================
set -euo pipefail

REPO="suguangnet/SuguangWebGuard"
REF="main"
MIRROR=""
SRC_DIR="/root/SuguangWebGuard-src"
DOWNLOAD_ONLY=0
PASS_ARGS=()

# 内置镜像（第三方服务，仅在 --mirror auto 时使用）
AUTO_MIRRORS=(
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://ghproxy.net/"
)

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
step(){ printf '\033[36m>>> %s\033[0m\n' "$*"; }
die(){ red "错误: $*"; exit 1; }

usage(){
  sed -n '3,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || cat <<'EOF'
用法: curl -fsSL <本脚本URL> | bash -s -- --site /www/wwwroot/你的站点
参数: --ref --mirror --src-dir --keep-src --download-only --help
其余参数透传给 install.sh
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)          shift; [ $# -gt 0 ] || die "--ref 需要参数"; REF="$1";;
    --mirror)       shift; [ $# -gt 0 ] || die "--mirror 需要参数"; MIRROR="$1";;
    --src-dir)      shift; [ $# -gt 0 ] || die "--src-dir 需要参数"; SRC_DIR="${1%/}";;
    --keep-src)     ;;                       # 默认就保留，接受该参数以兼容
    --download-only) DOWNLOAD_ONLY=1;;
    -h|--help)      usage;;
    *)              PASS_ARGS+=("$1");;
  esac
  shift
done

echo "=============================================="
echo " SuguangWebGuard 一键安装"
echo " 速光网络软件开发  https://suguang.cc"
echo " 仓库: $REPO    版本: $REF"
echo "=============================================="
echo

# ---------- 1. 前置检查 ----------
step "[1/4] 前置检查"
[ "$(id -u)" = "0" ] || die "必须用 root 运行"

DL=""
if command -v curl >/dev/null 2>&1; then DL=curl
elif command -v wget >/dev/null 2>&1; then DL=wget
else die "需要 curl 或 wget"; fi
command -v tar >/dev/null 2>&1 || die "需要 tar"
grn "  下载工具: $DL；tar 可用"

# 非交互环境下 install.sh 的确认提示会失败，提前提醒
HAS_YES=0
for a in "${PASS_ARGS[@]:-}"; do
  case "$a" in --yes|-y) HAS_YES=1;; esac
done
if [ ! -t 1 ] && [ "$HAS_YES" = "0" ]; then
  ylw "  当前不是交互终端。若安装过程需要确认会失败，建议加 --yes"
fi

# ---------- 2. 下载 ----------
step "[2/4] 下载源码"
TMP=$(mktemp -d /tmp/swg-dl.XXXXXX) || die "无法创建临时目录"
trap 'rm -rf "$TMP"' EXIT
TGZ="$TMP/src.tar.gz"

fetch(){ # $1=url  $2=输出文件
  if [ "$DL" = curl ]; then
    curl -fsSL --connect-timeout 15 -m 180 -o "$2" "$1"
  else
    wget -q --timeout=15 --tries=2 -O "$2" "$1"
  fi
}

# REF 可能是分支也可能是标签，两种路径都作为候选，由下面的循环挑第一个成功的
DIRECT_HEAD="https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF"
DIRECT_TAG="https://codeload.github.com/$REPO/tar.gz/refs/tags/$REF"

DOWNLOADED=0
try_urls=()
if [ -n "$MIRROR" ] && [ "$MIRROR" != "auto" ]; then
  # 指定了镜像：镜像优先，直连兜底
  try_urls=("${MIRROR%/}/https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
            "${MIRROR%/}/https://github.com/$REPO/archive/refs/tags/$REF.tar.gz"
            "$DIRECT_HEAD" "$DIRECT_TAG")
elif [ "$MIRROR" = "auto" ]; then
  # auto：先直连，不通再依次试内置镜像
  try_urls=("$DIRECT_HEAD" "$DIRECT_TAG")
  for m in "${AUTO_MIRRORS[@]}"; do
    try_urls+=("${m%/}/https://github.com/$REPO/archive/refs/heads/$REF.tar.gz")
  done
else
  try_urls=("$DIRECT_HEAD" "$DIRECT_TAG")
fi

for u in "${try_urls[@]}"; do
  echo "  尝试: ${u:0:90}"
  if fetch "$u" "$TGZ" && [ -s "$TGZ" ] && tar tzf "$TGZ" >/dev/null 2>&1; then
    DOWNLOADED=1
    case "$u" in
      https://codeload.github.com/*) ;;
      *) ylw "  注意: 本次通过第三方镜像下载，其内容不受本项目控制。";;
    esac
    break
  fi
  rm -f "$TGZ"
done

if [ "$DOWNLOADED" != "1" ]; then
  red "  下载失败。"
  echo
  echo "  可尝试："
  echo "    1) 通过镜像：在命令末尾加 --mirror auto"
  echo "       或指定镜像：--mirror https://你的镜像前缀/"
  echo "    2) 手工下载后安装："
  echo "       在能访问 GitHub 的机器上下载"
  echo "       https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
  echo "       上传到服务器后：tar xzf $REF.tar.gz && cd SuguangWebGuard-$REF && ./install.sh --site ..."
  exit 1
fi
grn "  已下载 $(stat -c%s "$TGZ" 2>/dev/null || echo '?') 字节"

# ---------- 3. 解压并校验 ----------
step "[3/4] 解压并校验完整性"
tar xzf "$TGZ" -C "$TMP" || die "解压失败"
# 注意：不能用 `tar tzf ... | head -1`。head 读完一行即关闭管道，tar 收到
# SIGPIPE 返回非零，配合 set -o pipefail 会让整个脚本直接退出。
# 改用 sed 读完全部输入再取第一行。
TOP=$(tar tzf "$TGZ" | sed -n "1{s|/.*||;p;}")
EXTRACTED="$TMP/$TOP"
[ -d "$EXTRACTED" ] || die "解压结果异常，未找到 $TOP"

NEED_FILES="install.sh uninstall.sh common.sh lock.sh unlock.sh status.sh watch.sh
detect.sh aide-init.sh aide-check.sh reset-password.sh web/webui.py web/index.html
dist/suguang-webguard-watch.service dist/suguang-webguard-web.service
dist/cron.suguang-webguard dist/logrotate.suguang-webguard"
MISSING=0
NEED_N=0
for f in $NEED_FILES; do
  NEED_N=$((NEED_N + 1))
  [ -f "$EXTRACTED/$f" ] || { red "  缺少 $f"; MISSING=1; }
done
[ "$MISSING" = "0" ] || die "下载内容不完整，可能是传输被截断或镜像返回了错误内容"
grn "  $NEED_N 个关键文件齐全"

# 统一换行符并赋可执行权限（防止经某些镜像/中转后变成 CRLF）
find "$EXTRACTED" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.service' \
     -o -name 'cron.*' -o -name 'logrotate.*' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$EXTRACTED"/*.sh 2>/dev/null || true
for f in "$EXTRACTED"/*.sh; do
  bash -n "$f" || die "脚本语法检查未通过: $(basename "$f")"
done
grn "  换行符已规范化，脚本语法检查通过"

# 落到最终源码目录
if [ -d "$SRC_DIR" ]; then
  BAK="${SRC_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  mv "$SRC_DIR" "$BAK"
  ylw "  已有源码目录，备份为 $BAK"
fi
mkdir -p "$(dirname "$SRC_DIR")"
cp -a "$EXTRACTED" "$SRC_DIR"
grn "  源码已放到 $SRC_DIR"

if [ "$DOWNLOAD_ONLY" = "1" ]; then
  echo
  grn "已按 --download-only 停止。手工安装："
  echo "  cd $SRC_DIR && ./install.sh --site /www/wwwroot/你的站点"
  exit 0
fi

# ---------- 4. 调用安装脚本 ----------
step "[4/4] 执行安装"
echo
cd "$SRC_DIR"
if [ "${#PASS_ARGS[@]}" -eq 0 ]; then
  ylw "未传入任何 install.sh 参数，将只安装框架、不配置站点。"
  ylw "安装后需手工编辑 $SRC_DIR/exclude.conf 再运行 lock.sh。"
  echo
  exec ./install.sh
else
  exec ./install.sh "${PASS_ARGS[@]}"
fi
