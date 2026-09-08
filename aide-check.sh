#!/bin/bash
# AIDE 每日完整性核查（由 /etc/cron.d/suguang-webguard 调用）
. /www/SuguangWebGuard/common.sh
AIDEBIN=$(command -v aide || echo /usr/sbin/aide)
LOG=/www/SuguangWebGuard/logs/aide-report.log
DB=/www/SuguangWebGuard/aide.db.gz
[ -x "$AIDEBIN" ] || { echo "$(ts) [AIDE] 未安装 aide" >> "$LOG"; exit 1; }
[ -f "$DB" ] || { echo "$(ts) [AIDE] 基线库不存在，请先运行 aide-init.sh" >> "$LOG"; exit 1; }
[ -f "$AIDECONF" ] || { echo "$(ts) [AIDE] 配置不存在，请先运行 aide-init.sh" >> "$LOG"; exit 1; }

OUT=$("$AIDEBIN" --config="$AIDECONF" --check 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
  echo "$(ts) [AIDE] 完整性核查通过，无变更" >> "$LOG"
else
  {
    echo "===================================================="
    echo "$(ts) [AIDE] 检测到文件变更 (exit=$RC)"
    echo "$OUT" | grep -vE '^$' | head -200
    echo "===================================================="
  } >> "$LOG"
  logger -t suguang-webguard "AIDE 检测到网站文件变更，详见 $LOG"
  echo "$(ts) [AIDE告警] 检测到文件变更，详见 $LOG" >> /www/SuguangWebGuard/logs/alert.log
fi
