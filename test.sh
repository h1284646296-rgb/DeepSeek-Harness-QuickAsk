#!/usr/bin/env bash
# Smoke tests for DSH Quick Ask. Everything here is safe; the only step that
# spends a model call is the end-to-end one (`--ask`), and it is opt-in.
#
#   bash test.sh            # 不花钱的检查
#   bash test.sh --e2e      # 额外跑一次真实的 headless 任务（会消耗 token）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/DSH Quick Ask.app"
BIN="$APP/Contents/MacOS/DSHQuickAsk"
FAILED=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '    \033[31m✗\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }

step "1. 构建产物"
if [ -x "$BIN" ]; then ok "可执行文件存在"; else bad "缺少 $BIN，请先运行 bash build.sh"; exit 1; fi
[ -f "$APP/Contents/Info.plist" ] && ok "Info.plist" || bad "缺少 Info.plist"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && ok "AppIcon.icns" || bad "缺少图标"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && ok "签名校验通过" || bad "签名校验失败"

step "2. --diagnose：配置与路径解析"
REPORT="$("$BIN" --diagnose 2>&1)"
printf '%s\n' "$REPORT" | sed 's/^/    /'
printf '%s\n' "$REPORT" | grep -qE '^node +: /' && ok "node 已解析" || bad "node 未解析"
printf '%s\n' "$REPORT" | grep -qE '^dsh 入口 +: /' && ok "dsh 入口已解析" || bad "dsh 入口未解析"

step "3. --print-terminal-script：终端模式脚本"
SCRIPT="$("$BIN" --print-terminal-script "冒烟测试" 2>&1)"
printf '%s\n' "$SCRIPT" | sed 's/^/    /'
printf '%s\n' "$SCRIPT" | grep -q -- '--profile headless' && ok "包含 headless 调用" || bad "脚本里没有 headless 调用"
printf '%s\n' "$SCRIPT" | grep -q "^cd '" && ok "包含工作区切换" || bad "脚本里没有 cd"

step "4. 面板执行路径的 argv（这一项就是为上次那个 bug 加的）"
ARGV="$("$BIN" --print-argv "冒烟测试" 2>&1)"
printf '%s\n' "$ARGV" | sed 's/^/    /'
FIRST="$(printf '%s\n' "$ARGV" | head -1)"
SECOND="$(printf '%s\n' "$ARGV" | sed -n '2p')"
if [ -f "$SECOND" ] && printf '%s' "$SECOND" | grep -q "dsh"; then
  ok "node 的第一个参数是 dsh 入口脚本"
else
  bad "argv 里缺少 dsh 入口（node 会报 bad option: --profile）"
fi
printf '%s\n' "$ARGV" | grep -q -- "--profile" && ok "包含 --profile" || bad "缺少 --profile"
printf '%s\n' "$ARGV" | grep -q -- "--patch" && ok "包含 --patch（按次模型覆盖）" || bad "缺少 --patch"

step "5. 打包资源（音效 / 模型目录脚本）"
[ -f "$APP/Contents/Resources/duang.wav" ] && ok "duang.wav 已打包" || bad "缺少 duang.wav"
[ -f "$APP/Contents/Resources/model-catalog.js" ] && ok "model-catalog.js 已打包" || bad "缺少 model-catalog.js"
afinfo "$APP/Contents/Resources/duang.wav" >/dev/null 2>&1 && ok "duang.wav 是合法音频" || bad "duang.wav 无法解析"

step "6. 双击 Shift 判定逻辑自检"
TRIGGER="$("$BIN" --selftest-trigger 2>&1)"
printf '%s\n' "$TRIGGER" | sed 's/^/    /'
printf '%s\n' "$TRIGGER" | grep -q '全部通过' && ok "9 项时序断言全部通过" || bad "触发器自检未通过"

step "7. 模型目录提取"
CATALOG="$("$BIN" --catalog 2>&1)"
COUNT="$(printf '%s\n' "$CATALOG" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("models",[])))' 2>/dev/null || echo 0)"
if [ "${COUNT:-0}" -gt 0 ]; then ok "提取到 $COUNT 个模型"; else bad "没有提取到模型"; fi
printf '%s\n' "$CATALOG" | grep -q '"efforts"' && ok "含推理档位信息" || bad "缺少推理档位"

step "8. --help / --version"
"$BIN" --version >/dev/null 2>&1 && ok "--version 正常" || bad "--version 失败"
"$BIN" --help >/dev/null 2>&1 && ok "--help 正常" || bad "--help 失败"

step "9. 配置文件"
CONFIG="$HOME/Library/Application Support/DSHQuickAsk/config.json"
if [ -f "$CONFIG" ]; then
  python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$CONFIG" && ok "$CONFIG 是合法 JSON" || bad "配置文件不是合法 JSON"
  python3 - "$CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
print("    trigger =", cfg.get("trigger"))
print("    model   =", cfg.get("provider"), "/", cfg.get("model"), "effort =", cfg.get("effort"))
missing = [k for k in ("trigger", "workspace", "nodePath", "dshEntry", "catalog") if k not in cfg]
print("    缺少的键:", missing or "无")
PY
else
  printf '    \033[33m·\033[0m 尚未安装（install.sh 会写 $CONFIG）\n'
fi

if [ "${1:-}" = "--e2e" ]; then
  step "10. 端到端：真的执行一次 headless 任务（面板代码路径）"
  printf '    任务：在 shell 里运行 pwd，然后只回复它输出的绝对路径\n'
  START=$(date +%s)
  "$BIN" --ask "在 shell 里运行 pwd，然后只回复它输出的绝对路径，不要其它内容" 2>&1 | sed 's/^/    /'
  CODE=${PIPESTATUS[0]}
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$CODE" = "0" ]; then ok "退出码 0（${ELAPSED}s）"; else bad "退出码 $CODE"; fi
else
  step "10. 端到端（已跳过）"
  printf '    加上 --e2e 会真跑一次：bash test.sh --e2e\n'
fi

printf '\n'
if [ "$FAILED" = "0" ]; then
  printf '\033[32m全部通过。\033[0m 手动验证见 README 的「验证」一节。\n'
  exit 0
fi
printf '\033[31m%d 项失败。\033[0m\n' "$FAILED"
exit 1
