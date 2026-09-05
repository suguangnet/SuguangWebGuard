#!/bin/bash
# SuguangWebGuard 重置 Web 管理密码
# 速光网络软件开发  https://suguang.cc
#
# 忘记密码时用这个——Web 界面上的「重置密码」按钮要先登录才能用，
# 登不进去的时候只剩命令行这一条路。
#
# 用法:
#   ./reset-password.sh                    随机生成一个新密码
#   ./reset-password.sh 你的新密码          指定密码（至少 8 位）
#   ./reset-password.sh --user newadmin    同时改用户名
#   ./reset-password.sh --keep-sessions    保留已登录的会话（默认全部注销）
#
# 真正的改写逻辑在 web/webui.py --reset-password 里，这里只做检查和转发。
# 两处各写一套哈希逻辑迟早会走偏，所以共用同一份。
set -u
PREFIX=/www/SuguangWebGuard
WEBUI="$PREFIX/web/webui.py"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
die(){ red "错误: $*"; exit 1; }

case "${1:-}" in
  -h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0;;
esac

[ "$(id -u)" = "0" ] || die "必须用 root 运行"
[ -f "$WEBUI" ] || die "找不到 $WEBUI，请确认 SuguangWebGuard 已安装在 $PREFIX"
command -v python3 >/dev/null 2>&1 || die "需要 python3"

echo "=============================================="
echo " SuguangWebGuard 重置 Web 管理密码"
echo "=============================================="
echo

python3 "$WEBUI" --reset-password "$@" || die "重置失败"

echo
# Web 服务在下次登录时会自己重新载入 web.conf，正常不需要重启。
# 但服务没在跑的话，密码改了也登不上，这里提示一下。
if systemctl is-active --quiet suguang-webguard-web 2>/dev/null; then
  PORT=$(python3 - <<'PY' 2>/dev/null || echo 19196
import json
try:
    print(json.load(open('/www/SuguangWebGuard/web.conf')).get('port', 19196))
except Exception:
    print(19196)
PY
)
  grn "Web 服务运行中，直接用新密码登录即可（无需重启）："
  echo "  http://<服务器IP>:${PORT}/"
else
  ylw "Web 服务当前未运行，启动后才能登录："
  echo "  systemctl start suguang-webguard-web"
fi
