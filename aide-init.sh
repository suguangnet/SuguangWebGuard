#!/bin/bash
# 建立/重建 AIDE 基线
# 会先根据 exclude.conf 重新生成 /www/SuguangWebGuard/aide.conf，保证两者始终一致。
# 何时运行：首次安装后、你主动修改过网站文件后、新增受保护站点后。
. /www/SuguangWebGuard/common.sh
[ "$(id -u)" = "0" ] || { echo "必须用 root 运行"; exit 1; }
AIDEBIN=$(command -v aide || echo /usr/sbin/aide)
[ -x "$AIDEBIN" ] || { echo "未安装 aide"; exit 1; }

gen_aide_conf || exit 1
echo "已根据 exclude.conf 生成 $AIDECONF"

echo "正在建立基线，请稍候（文件多时需要几分钟）..."
"$AIDEBIN" --config="$AIDECONF" --init 2>&1 | tail -5
if [ -f /www/SuguangWebGuard/aide.db.new.gz ]; then
  mv -f /www/SuguangWebGuard/aide.db.new.gz /www/SuguangWebGuard/aide.db.gz
  echo "基线已建立: /www/SuguangWebGuard/aide.db.gz"
  ls -la /www/SuguangWebGuard/aide.db.gz
  echo "$(ts) [AIDE] 基线已重建" >> /www/SuguangWebGuard/logs/alert.log
else
  echo "基线建立失败，请检查 $AIDECONF"; exit 1
fi
