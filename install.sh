#!/bin/bash
# ============================================================
# SuguangWebGuard 网站防篡改系统 · 安装脚本
# 速光网络软件开发  https://suguang.cc
#
# 用法: ./install.sh [选项]
#
#   --site <路径>   要保护的站点根目录，可重复指定
#                   例: --site /www/wwwroot/a.com --site /www/wwwroot/b.com
#   --days <N>      探测可写目录时回溯的天数（默认 90）
#   --lock          安装完成后立即加锁（默认不加锁，留给你先核对配置）
#   --port <N>      Web 管理界面端口（默认 19196）
#   --no-web        不安装 Web 管理界面
#   --no-aide       不安装 AIDE 完整性核查
#   --yes           全部确认，不交互
#   --help          显示帮助
#
# 不带 --site 也可以装，之后手工编辑 exclude.conf 再运行 lock.sh。
# ============================================================
set -u

VERSION=1.1.0
PREFIX=/www/SuguangWebGuard
LOGDIR=/www/SuguangWebGuard/logs
AIDECONF=/www/SuguangWebGuard/aide.conf
AIDEDB=/www/SuguangWebGuard/aide.db.gz
UNIT=/etc/systemd/system/suguang-webguard-watch.service
WEBUNIT=/etc/systemd/system/suguang-webguard-web.service
CRON=/etc/cron.d/suguang-webguard
LOGROT=/etc/logrotate.d/suguang-webguard
WEBCONF=$PREFIX/web.conf
SRC="$(cd "$(dirname "$0")" && pwd)"

DO_LOCK=0; DO_AIDE=1; DO_WEB=1; ASSUME_YES=0; DAYS=90; WEBPORT=19196
SITES=()

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
step(){ echo; printf '\033[36m>>> %s\033[0m\n' "$*"; }
die(){ red "错误: $*"; exit 1; }

usage(){ sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --site) shift; [ $# -gt 0 ] || die "--site 需要参数"; SITES+=("${1%/}");;
    --days) shift; DAYS="$1";;
    --port) shift; WEBPORT="$1";;
    --lock) DO_LOCK=1;;
    --no-web) DO_WEB=0;;
    --no-aide) DO_AIDE=0;;
    --yes|-y) ASSUME_YES=1;;
    --help|-h) usage;;
    *) die "未知参数: $1（--help 查看用法）";;
  esac
  shift
done

confirm(){
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '%s [y/N] ' "$1"; read -r a </dev/tty
  case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

echo "=============================================="
echo " SuguangWebGuard 网站防篡改系统  v$VERSION"
echo " 速光网络软件开发  https://suguang.cc"
echo " 源目录: $SRC"
echo "=============================================="

# ---------- 1. 前置检查 ----------
step "1/9 前置检查"
[ "$(id -u)" = "0" ] || die "必须用 root 运行"

for c in find xargs awk sed systemctl; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done
grn "  基础命令齐全"

command -v chattr >/dev/null 2>&1 || die "缺少 chattr，请先安装 e2fsprogs"
command -v lsattr >/dev/null 2>&1 || die "缺少 lsattr，请先安装 e2fsprogs"
grn "  chattr / lsattr 可用"

TESTF=$(mktemp /tmp/at_fs_test.XXXXXX) || die "无法创建临时文件"
if chattr +i "$TESTF" 2>/dev/null; then
  chattr -i "$TESTF" 2>/dev/null; rm -f "$TESTF"
  grn "  文件系统支持 immutable 属性"
else
  rm -f "$TESTF"
  ylw "  /tmp 不支持 immutable（可能是 tmpfs），将在站点目录上验证"
fi

NEED="common.sh lock.sh unlock.sh status.sh watch.sh aide-init.sh aide-check.sh"
for f in $NEED; do
  [ -f "$SRC/$f" ] || die "源目录缺少 $f，请确认解压完整"
done
for f in dist/suguang-webguard-watch.service dist/cron.suguang-webguard dist/logrotate.suguang-webguard; do
  [ -f "$SRC/$f" ] || die "源目录缺少 $f"
done
if [ "$DO_WEB" = "1" ]; then
  for f in web/webui.py web/index.html dist/suguang-webguard-web.service; do
    [ -f "$SRC/$f" ] || die "源目录缺少 $f（如不需要 Web 界面请加 --no-web）"
  done
  PY=$(command -v python3 || true)
  [ -n "$PY" ] || die "未找到 python3，Web 界面需要 Python 3.6+（或加 --no-web 跳过）"
  PYV=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)
  grn "  python3: $PYV ($PY)"
fi
grn "  源文件完整"

for s in "${SITES[@]:-}"; do
  [ -n "$s" ] || continue
  [ -d "$s" ] || die "站点目录不存在: $s"
done
if [ "${#SITES[@]}" -gt 0 ]; then
  grn "  待保护站点: ${SITES[*]}"
else
  ylw "  未指定 --site，安装后需手工编辑 $PREFIX/exclude.conf"
fi


# ---------- 1.5 检测旧版安装并迁移 ----------
migrate_old(){
  local OLD="$1" OLDLOG="$2" OLDW="$3" OLDB="$4"
  step "检测到旧版安装: $OLD"
  ylw "  本产品的安装位置已变更，所有文件现统一存放在 $PREFIX 下。"
  ylw "  若不迁移，新旧两套会并存，可能重复隔离文件、重复告警。"
  echo "    旧: $OLD  日志:$OLDLOG"
  echo "    新: $PREFIX  日志:$LOGDIR（配置、日志、隔离区、AIDE 基线全在此目录内）"
  if confirm "  现在自动迁移（停用旧服务、沿用旧配置、删除旧目录）？"; then
    systemctl disable --now antitamper-watch antitamper-web \
                            suguang-webguard-watch suguang-webguard-web >/dev/null 2>&1
    rm -f /etc/systemd/system/antitamper-watch.service \
          /etc/systemd/system/antitamper-web.service \
          /etc/cron.d/antitamper /etc/logrotate.d/antitamper
    systemctl daemon-reload
    mkdir -p "$PREFIX/quarantine" "$LOGDIR"
    # 站点文件上的 chattr 锁与工具路径无关，无需解锁，直接沿用配置
    [ -f "$OLD/exclude.conf" ] && cp -f "$OLD/exclude.conf" "$PREFIX/exclude.conf"
    [ -f "$OLD/web.conf" ] && cp -f "$OLD/web.conf" "$PREFIX/web.conf" && chmod 600 "$PREFIX/web.conf"
    [ -f "$OLD/web-initial-password.txt" ] && cp -f "$OLD/web-initial-password.txt" "$PREFIX/" 2>/dev/null
    [ -f "$OLD/.maintenance" ] && touch "$PREFIX/.maintenance"
    [ -d "$OLD/quarantine" ] && cp -a "$OLD/quarantine/." "$PREFIX/quarantine/" 2>/dev/null
    [ -d "$OLDLOG" ] && cp -a "$OLDLOG/." "$LOGDIR/" 2>/dev/null
    rm -f "$OLDW" "$OLDB" "${OLDB%.gz}.new.gz" 2>/dev/null
    rm -rf "$OLD" "$OLDLOG"
    rmdir /etc/aide /etc/suguang-webguard /var/lib/aide /var/lib/suguang-webguard 2>/dev/null
    grn "  已迁移：配置、隔离区、日志已沿用；旧目录与旧服务已清除"
    ylw "  注意：AIDE 基线需要重建（本次安装最后一步会问你）"
  else
    die "已取消。请先手工卸载旧版（$OLD/uninstall.sh）后再安装。"
  fi
}

if [ -d /root/antitamper ] || systemctl list-unit-files 2>/dev/null | grep -q '^antitamper-'; then
  migrate_old /root/antitamper /var/log/antitamper \
              /etc/aide/aide-web.conf /var/lib/aide/aide-web.db.gz
elif [ -d /root/SuguangWebGuard ]; then
  migrate_old /root/SuguangWebGuard /var/log/suguang-webguard \
              /etc/suguang-webguard/aide.conf /var/lib/suguang-webguard/aide.db.gz
fi

# ---------- 2. 安装依赖 ----------
step "2/9 安装依赖"
need_pkg=""
command -v inotifywait >/dev/null 2>&1 || need_pkg="$need_pkg inotify-tools"
if [ "$DO_AIDE" = "1" ]; then
  command -v aide >/dev/null 2>&1 || [ -x /usr/sbin/aide ] || need_pkg="$need_pkg aide"
fi
if [ -n "$need_pkg" ]; then
  echo "  需要安装:$need_pkg"
  if command -v yum >/dev/null 2>&1; then
    yum install -y $need_pkg >/dev/null 2>&1 || yum install -y $need_pkg
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y $need_pkg
  else
    die "未识别的包管理器，请手工安装:$need_pkg"
  fi
fi
command -v inotifywait >/dev/null 2>&1 || die "inotify-tools 安装失败（CentOS 需启用 EPEL 源）"
grn "  inotify-tools: $(inotifywait --help 2>&1 | head -1)"
if [ "$DO_AIDE" = "1" ]; then
  AIDEBIN=$(command -v aide || echo /usr/sbin/aide)
  [ -x "$AIDEBIN" ] || die "aide 安装失败"
  grn "  aide: $($AIDEBIN --version 2>&1 | head -1)"
fi

# ---------- 3. 创建目录 ----------
step "3/9 创建目录"
mkdir -p "$PREFIX/quarantine" "$PREFIX/web" "$LOGDIR"
chmod 700 "$PREFIX" "$PREFIX/quarantine"
chmod 700 "$LOGDIR"
grn "  $PREFIX（含 logs/ quarantine/ web/，权限 700，www 用户不可读）"

# ---------- 4. 安装程序文件 ----------
step "4/9 安装程序文件"
if [ "$SRC" = "$PREFIX" ]; then
  ylw "  源目录即安装目录，跳过复制（原地重装）"
else
  for f in $NEED detect.sh uninstall.sh install.sh README.md exclude.conf.example; do
    [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$PREFIX/"
  done
  if [ "$DO_WEB" = "1" ]; then
    cp -f "$SRC/web/webui.py" "$SRC/web/index.html" "$PREFIX/web/"
  fi
  grn "  已复制到 $PREFIX"
fi
chmod +x "$PREFIX"/*.sh 2>/dev/null
sed -i 's/\r$//' "$PREFIX"/*.sh 2>/dev/null
[ -f "$PREFIX/web/webui.py" ] && { sed -i 's/\r$//' "$PREFIX/web/webui.py"; chmod +x "$PREFIX/web/webui.py"; }
[ -f "$PREFIX/web/index.html" ] && sed -i 's/\r$//' "$PREFIX/web/index.html"
rm -rf "$PREFIX/web/__pycache__"
for f in "$PREFIX"/*.sh; do
  bash -n "$f" || die "脚本语法错误: $f"
done
if [ "$DO_WEB" = "1" ]; then
  "$PY" -c "import py_compile,sys; py_compile.compile('$PREFIX/web/webui.py', doraise=True)" \
    || die "webui.py 语法错误"
  rm -rf "$PREFIX/web/__pycache__"
fi
grn "  语法检查通过"

# ---------- 5. 生成 exclude.conf ----------
step "5/9 生成配置 exclude.conf"
if [ -f "$PREFIX/exclude.conf" ] && [ "${#SITES[@]}" -eq 0 ]; then
  ylw "  已存在 exclude.conf，保留不动"
elif [ "${#SITES[@]}" -eq 0 ]; then
  [ -f "$SRC/exclude.conf.example" ] && cp -f "$SRC/exclude.conf.example" "$PREFIX/exclude.conf"
  ylw "  已生成模板 exclude.conf，请手工编辑后运行 lock.sh"
else
  if [ -f "$PREFIX/exclude.conf" ]; then
    BAK="$PREFIX/exclude.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp -f "$PREFIX/exclude.conf" "$BAK"
    ylw "  已备份原配置到 $BAK"
  fi
  {
    echo "# ============================================================"
    echo "# 防篡改保护配置    生成于 $(date '+%F %T')"
    echo "# SITE=<站点绝对路径>  EXCLUDE=<保持可写的相对路径>  PHPOK=<允许生成.php的相对路径>"
    echo "# 以下由 install.sh 自动探测（回溯 ${DAYS} 天写入行为）"
    echo "# 请务必人工核对：漏掉可写目录会导致网站报错！"
    echo "# ============================================================"
  } > "$PREFIX/exclude.conf"
  for s in "${SITES[@]}"; do
    echo "  探测 $s ..."
    "$PREFIX/detect.sh" "$s" "$DAYS" >> "$PREFIX/exclude.conf"
  done
  grn "  已生成 $PREFIX/exclude.conf"
  echo
  echo "  ---------- 生成的配置 ----------"
  grep -vE '^\s*#|^\s*$' "$PREFIX/exclude.conf" | sed 's/^/  /'
  echo "  --------------------------------"
fi

# ---------- 6. 系统集成 ----------
step "6/9 安装系统集成（systemd / cron / logrotate）"
install -m 644 "$SRC/dist/suguang-webguard-watch.service" "$UNIT"
sed -i 's/\r$//' "$UNIT"
install -m 644 "$SRC/dist/logrotate.suguang-webguard" "$LOGROT"
sed -i 's/\r$//' "$LOGROT"
if [ "$DO_AIDE" = "1" ]; then
  install -m 644 "$SRC/dist/cron.suguang-webguard" "$CRON"
  sed -i 's/\r$//' "$CRON"
  grn "  cron: $CRON（每日 04:17 完整性核查）"
else
  rm -f "$CRON"; ylw "  跳过 AIDE，未安装 cron"
fi
if [ "$DO_WEB" = "1" ]; then
  install -m 644 "$SRC/dist/suguang-webguard-web.service" "$WEBUNIT"
  sed -i 's/\r$//' "$WEBUNIT"
  sed -i "s|ExecStart=.*|ExecStart=$PY $PREFIX/web/webui.py|" "$WEBUNIT"
  grn "  systemd unit: $WEBUNIT"
fi
systemctl daemon-reload
grn "  systemd unit: $UNIT"
grn "  logrotate: $LOGROT"

# ---------- 7. 启动守护 ----------
step "7/9 启动实时监控守护"
systemctl enable suguang-webguard-watch >/dev/null 2>&1
systemctl restart suguang-webguard-watch
sleep 2
if systemctl is-active suguang-webguard-watch >/dev/null 2>&1; then
  grn "  suguang-webguard-watch 运行中（已设置开机自启）"
else
  red "  suguang-webguard-watch 启动失败: journalctl -u suguang-webguard-watch -n 30"
fi

# ---------- 8. Web 管理界面 ----------
step "8/9 Web 管理界面"
if [ "$DO_WEB" != "1" ]; then
  ylw "  已跳过（--no-web）"
  systemctl disable --now suguang-webguard-web >/dev/null 2>&1
else
  if [ -f "$WEBCONF" ]; then
    "$PY" - "$WEBCONF" "$WEBPORT" <<'PYEOF'
import json,sys
p,port=sys.argv[1],int(sys.argv[2])
try: c=json.load(open(p))
except Exception: c={}
c['port']=port
json.dump(c,open(p,'w'),indent=2,ensure_ascii=False)
PYEOF
    ylw "  已存在 web.conf，保留原有账号密码，端口设为 $WEBPORT"
  else
    "$PY" - "$WEBCONF" "$WEBPORT" <<'PYEOF'
import json,sys
json.dump({'bind':'0.0.0.0','port':int(sys.argv[2]),'user':'admin',
           'salt':'','pwhash':'','allow_cidr':[]},
          open(sys.argv[1],'w'),indent=2,ensure_ascii=False)
PYEOF
    chmod 600 "$WEBCONF"
  fi
  systemctl enable suguang-webguard-web >/dev/null 2>&1
  systemctl restart suguang-webguard-web
  sleep 3
  if systemctl is-active suguang-webguard-web >/dev/null 2>&1; then
    grn "  suguang-webguard-web 运行中，监听 0.0.0.0:$WEBPORT"
    if [ -f "$PREFIX/web-initial-password.txt" ]; then
      echo
      ylw "  ----- 登录信息（首次生成，请登录后立即修改）-----"
      sed 's/^/    /' "$PREFIX/web-initial-password.txt"
      ylw "  ------------------------------------------------"
    fi
    IP=$(ip route get 1 2>/dev/null | awk '{print $7;exit}')
    echo "  访问地址: http://${IP:-服务器IP}:$WEBPORT"
    ylw "  提示: 云服务器还需在【安全组】放行 $WEBPORT/tcp，仅开放系统防火墙不够"
  else
    red "  suguang-webguard-web 启动失败: journalctl -u suguang-webguard-web -n 30"
  fi
fi

# ---------- 9. 加锁 + AIDE 基线 ----------
step "9/9 加锁与基线"
if [ "$DO_LOCK" = "1" ]; then
  "$PREFIX/lock.sh"
else
  ylw "  未加锁（默认行为）。请先核对 exclude.conf，确认无误后执行:"
  echo "      $PREFIX/lock.sh"
fi

if [ "$DO_AIDE" = "1" ]; then
  if confirm "  现在建立 AIDE 完整性基线？（站点文件多时需要几分钟）"; then
    "$PREFIX/aide-init.sh"
  else
    ylw "  已跳过。之后请手工执行: $PREFIX/aide-init.sh"
  fi
fi

echo
echo "=============================================="
grn " 安装完成"
echo "=============================================="
echo
echo "常用命令:"
echo "  $PREFIX/status.sh      查看保护状态"
echo "  $PREFIX/unlock.sh      解锁（改网站前跑）"
echo "  $PREFIX/lock.sh        加锁（改完后跑）"
echo "  $PREFIX/aide-init.sh   重建完整性基线"
echo "  $PREFIX/uninstall.sh   卸载"
echo
echo "文档: $PREFIX/README.md"
echo "日志: $LOGDIR/alert.log"
echo
if [ "$DO_LOCK" != "1" ]; then
  ylw "下一步：核对 $PREFIX/exclude.conf，然后运行 $PREFIX/lock.sh"
fi
