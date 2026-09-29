#!/usr/bin/env bash
# Install "DSH Quick Ask": build it, place the .app, write a config with the
# resolved node/dsh paths and the model catalog, and register a per-user
# LaunchAgent so the trigger is live after every login.
#
# Everything here is per-user. No sudo, nothing in /Library.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DSH Quick Ask"
EXECUTABLE="DSHQuickAsk"
LABEL="local.dsh.quickask"
SUPPORT="$HOME/Library/Application Support/DSHQuickAsk"
CONFIG="$SUPPORT/config.json"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs"

WORKSPACE="${DSH_QUICKASK_WORKSPACE:-$HOME/Desktop/harness}"
TRIGGER="double-shift"
HOTKEY=""
MODE="inline"
SOUND="duang"
INSTALL_AGENT=1
PREFIX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --trigger)   TRIGGER="$2";   shift 2 ;;
    --hotkey)    HOTKEY="$2";    shift 2 ;;
    --mode)      MODE="$2";      shift 2 ;;
    --sound)     SOUND="$2";     shift 2 ;;
    --prefix)    PREFIX="$2";    shift 2 ;;
    --no-agent)  INSTALL_AGENT=0; shift ;;
    -h|--help)
      cat <<'HELP'
用法: bash install.sh [选项]

  --workspace <路径>   headless 执行时的工作目录（默认 ~/Desktop/harness）
  --trigger <方式>     触发方式：double-shift（默认）/ double-shift-carbon / hotkey / both
  --hotkey <组合键>    组合键触发（默认空 = 不占用任何组合键，只用双击 Shift）
  --mode <模式>        inline（面板内直接出结果）或 terminal（开终端窗口执行）
  --sound <音效>       duang（自带合成音）/ 系统音效名如 Hero / "" 静音
  --prefix <目录>      安装到指定目录（默认 /Applications，不可写时用 ~/Applications）
  --no-agent           只装应用，不注册开机自启
HELP
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

echo "==> 0/6 代码签名身份（决定「输入监视」授权会不会被重编译冲掉）"
if [ -f "$HOME/Library/Keychains/dsh-quickask.keychain-db" ]; then
  echo "    已有独立钥匙串，跳过"
else
  echo "    还没有，创建一个自签身份（不碰你的登录钥匙串）"
  bash "$ROOT/tools/make-signing-identity.sh" || echo "    ! 创建失败，将退回 ad-hoc 签名（授权会随重编译失效）"
fi

echo "==> 1/6 编译"
bash "$ROOT/build.sh"

if [ -z "$PREFIX" ]; then
  if [ -w /Applications ]; then PREFIX="/Applications"; else PREFIX="$HOME/Applications"; fi
fi
mkdir -p "$PREFIX"
TARGET="$PREFIX/$APP_NAME.app"

echo "==> 2/6 安装到 $TARGET"
rm -rf "$TARGET"
cp -R "$ROOT/dist/$APP_NAME.app" "$TARGET"
# 复制本身不会破坏签名，所以**不要**在这里重签 —— 之前这里做了一次 ad-hoc 重签，
# 直接把 build.sh 打好的稳定签名覆盖掉，TCC 授权因此每次安装都失效。
# 只有校验不过时才补签一次。
if ! codesign --verify --strict "$TARGET" >/dev/null 2>&1; then
  echo "    签名校验失败，重新签名"
  bash "$ROOT/tools/sign.sh" "$TARGET"
fi

BIN="$TARGET/Contents/MacOS/$EXECUTABLE"

echo "==> 3/6 解析 node / dsh 路径"
RESOLVED="$("$BIN" --diagnose 2>/dev/null || true)"
NODE_PATH="$(printf '%s\n' "$RESOLVED" | awk -F': ' '/^node /{print $2}' | head -1 | sed -e 's/[[:space:]]*$//')"
DSH_PATH="$(printf '%s\n' "$RESOLVED" | awk -F': ' '/^dsh 入口 /{print $2}' | head -1 | sed -e 's/[[:space:]]*$//')"
echo "    node = ${NODE_PATH:-<未找到>}"
echo "    dsh  = ${DSH_PATH:-<未找到>}"
if [ -z "$NODE_PATH" ] || [ -z "$DSH_PATH" ]; then
  echo "    !! 未找到 node 或 dsh。请先确认 \`dsh --version\` 可用，然后重跑本脚本。"
  echo "       应用仍会安装，但按下触发键后无法执行。"
fi

echo "==> 4/6 提取模型目录"
mkdir -p "$SUPPORT"
CATALOG_FILE="$SUPPORT/catalog.json"
echo '{}' > "$CATALOG_FILE"
if [ -n "$NODE_PATH" ] && [ -n "$DSH_PATH" ]; then
  if "$BIN" --catalog > "$CATALOG_FILE" 2>/dev/null; then
    python3 - "$CATALOG_FILE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
models = doc.get("models", [])
providers = sorted({m.get("provider", "?") for m in models})
print(f"    {len(models)} 个模型，来自 {len(providers)} 个 provider: {', '.join(providers)}")
if doc.get("warning"):
    print(f"    警告: {doc['warning']}")
PY
  else
    echo "    提取失败，面板将退回内置的 DeepSeek 列表"
    echo '{}' > "$CATALOG_FILE"
  fi
else
  echo "    跳过（没有 node/dsh）"
fi

echo "==> 5/6 写配置 $CONFIG"
python3 - "$CONFIG" "$CATALOG_FILE" "$TRIGGER" "$HOTKEY" "$WORKSPACE" "$NODE_PATH" "$DSH_PATH" "$MODE" "$SOUND" <<'PY'
import json, os, sys
path, catalog_path, trigger, hotkey, workspace, node, dsh, mode, sound = sys.argv[1:10]

existing = {}
if os.path.exists(path):
    try:
        existing = json.load(open(path))
    except Exception:
        existing = {}

try:
    catalog = json.load(open(catalog_path))
except Exception:
    catalog = {}

existing.update({
    "trigger": trigger,
    "hotkey": hotkey,
    "doubleShiftWindowMs": existing.get("doubleShiftWindowMs", 400),
    "workspace": workspace,
    "nodePath": node,
    "dshEntry": dsh,
    "mode": mode,
    "rainbow": existing.get("rainbow", True),
    "sound": sound,
})
if catalog.get("models"):
    existing["catalog"] = catalog
    # 还没记住过选择时，跟随 settings.yaml 里的当前默认。
    if not existing.get("model"):
        current = catalog.get("current") or {}
        if current.get("model"):
            existing["provider"] = current.get("provider", "")
            existing["model"] = current["model"]
            existing["effort"] = current.get("effort") or ""

json.dump(existing, open(path, "w"), ensure_ascii=False, indent=2, sort_keys=True)
print("    触发方式:", existing.get("trigger"), "| 音效:", existing.get("sound") or "静音")
print("    模型    :", existing.get("provider"), "/", existing.get("model"), "推理:", existing.get("effort"))
PY

if [ "$INSTALL_AGENT" = "0" ]; then
  echo "==> 6/6 跳过 LaunchAgent（--no-agent）"
  echo
  echo "手动启动: \"$BIN\""
  exit 0
fi

echo "==> 6/6 注册登录项 $AGENT"
mkdir -p "$(dirname "$AGENT")" "$LOGS"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$LOGS/DSHQuickAsk.launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$LOGS/DSHQuickAsk.launchd.log</string>
</dict>
</plist>
PLIST

# Replace any previous instance so the new config/binary is the one running.
launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
pkill -f "DSHQuickAsk" >/dev/null 2>&1 || true
sleep 0.5
if ! launchctl bootstrap "gui/$UID" "$AGENT" >/dev/null 2>&1; then
  launchctl load -w "$AGENT" >/dev/null 2>&1 || true
fi

sleep 1.5
if pgrep -f "DSHQuickAsk" >/dev/null 2>&1; then
  echo "    ✓ 代理已启动 (pid $(pgrep -f DSHQuickAsk | tr '\n' ' '))"
else
  echo "    ! 代理未在运行，请查看 $LOGS/DSHQuickAsk.launchd.log"
fi

# 「连按两下 Shift」用 CGEventTap 旁听键盘，需要系统授权。这里只提示，
# 因为授权必须由用户本人在系统设置里点。
if [ "$TRIGGER" != "hotkey" ]; then
  echo
  echo "    ⚠ 首次使用需要在「系统设置 → 隐私与安全性」里给「DSH Quick Ask」打开"
  echo "       「辅助功能」或「输入监视」（任一项即可），然后从菜单栏 ✨ 重启一次。"
  echo "       应用已经改用了稳定的自签身份，这一步只需要做一次，以后重装不再失效。"
fi

cat <<DONE

============================================================
安装完成。

  应用      : $TARGET
  配置      : $CONFIG
  触发方式  : $TRIGGER$([ "$TRIGGER" != "double-shift" ] && echo "（组合键 $HOTKEY）")
  音效      : ${SOUND:-静音}      彩虹跑马灯: 开
  工作区    : $WORKSPACE
  执行方式  : $MODE
  日志      : $LOGS/DSHQuickAsk.log

现在连按两下 Shift 就会弹出输入框。

验证:
  "$BIN" --diagnose          # 配置、路径、模型目录
  "$BIN" --selftest-trigger  # 自检双击 Shift 的判定逻辑
  "$BIN" --selftest          # 真跑一次 headless 任务

移除: bash uninstall.sh
============================================================
DONE
