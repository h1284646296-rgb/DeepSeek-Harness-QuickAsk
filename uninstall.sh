#!/usr/bin/env bash
# Remove the LaunchAgent and (optionally) the installed app. User data
# (config, logs, run scripts) is kept unless --purge is given.
set -euo pipefail

APP_NAME="DSH Quick Ask"
LABEL="local.dsh.quickask"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="$HOME/Library/Application Support/DSHQuickAsk"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> 停止并移除 LaunchAgent"
launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
if [ -f "$AGENT" ]; then
  launchctl unload -w "$AGENT" >/dev/null 2>&1 || true
  rm -f "$AGENT"
fi
pkill -f "DSHQuickAsk" >/dev/null 2>&1 || true

echo "==> 移除应用"
for target in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
  [ -d "$target" ] && rm -rf "$target" && echo "    removed $target"
done

if [ "$PURGE" = "1" ]; then
  echo "==> 清除配置与日志"
  rm -rf "$SUPPORT"
  rm -f "$HOME/Library/Logs/DSHQuickAsk.log" "$HOME/Library/Logs/DSHQuickAsk.launchd.log"
fi

echo "完成。"
