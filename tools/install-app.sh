#!/usr/bin/env bash
# 安装一个**已经编译好**的 DSH Quick Ask.app：放到位、建签名身份、提取模型目录、
# 写配置、注册 LaunchAgent。
#
# 从源码安装走 install.sh；这个脚本是它的后半段，单独拆出来是为了让
# Release 里下载的用户也能一键装（那边没有源码、也没打算编译）。
#
# 用法:
#   bash tools/install-app.sh <路径/DSH Quick Ask.app> [选项]
#   bash 安装.command                 # 参数省略时自动找同目录下的 .app
#
# 选项:
#   --workspace <路径>   headless 执行时的工作目录
#   --trigger <方式>     double-shift（默认）/ double-shift-carbon / hotkey / both
#   --hotkey <组合键>    组合键触发（默认空 = 不占用）
#   --mode <模式>        inline（默认）/ terminal
#   --sound <音效>       duang（默认）/ 系统音效名 / "" 静音
#   --prefix <目录>      安装目录（默认 /Applications，不可写时用 ~/Applications）
#   --no-agent           只装应用，不注册开机自启
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DSH Quick Ask"
EXECUTABLE="DSHQuickAsk"
LABEL="local.dsh.quickask"
SUPPORT="$HOME/Library/Application Support/DSHQuickAsk"
CONFIG="$SUPPORT/config.json"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs"
KEYCHAIN="$HOME/Library/Keychains/dsh-quickask.keychain-db"
IDENTITY_NAME="DSH Quick Ask Local Signing"
KEYCHAIN_PASS="dshquickask"

SOURCE_APP=""
WORKSPACE="${DSH_QUICKASK_WORKSPACE:-$HOME/Desktop/harness}"
TRIGGER="double-shift"
HOTKEY=""
MODE="inline"
SOUND="duang"
PREFIX=""
INSTALL_AGENT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --trigger)   TRIGGER="$2";   shift 2 ;;
    --hotkey)    HOTKEY="$2";    shift 2 ;;
    --mode)      MODE="$2";      shift 2 ;;
    --sound)     SOUND="$2";     shift 2 ;;
    --prefix)    PREFIX="$2";    shift 2 ;;
    --no-agent)  INSTALL_AGENT=0; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *)           SOURCE_APP="$1"; shift ;;
  esac
done

# 没给路径就找脚本旁边的 .app —— 双击「安装.command」走的就是这条。
if [ -z "$SOURCE_APP" ]; then
  for candidate in "$SELF_DIR/$APP_NAME.app" "$SELF_DIR"/*.app; do
    [ -d "$candidate" ] && SOURCE_APP="$candidate" && break
  done
fi
if [ -z "$SOURCE_APP" ] || [ ! -d "$SOURCE_APP" ]; then
  echo "✗ 找不到 $APP_NAME.app。请把本脚本和 .app 放在同一个目录里。" >&2
  exit 1
fi

echo "==> 1/5 解除下载隔离"
# 从网上下载的 .app 会被打上 com.apple.quarantine，Gatekeeper 会直接拦住。
# 这是本机自用的小工具、不是商店分发，所以这里显式去掉隔离属性。
xattr -dr com.apple.quarantine "$SOURCE_APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$SELF_DIR" 2>/dev/null || true
echo "    ok"

echo "==> 2/5 建立稳定的代码签名身份"
# ad-hoc 签名的 designated requirement 是 cdhash，二进制一变 TCC 授权就失效。
# 换成自签证书后 DR 变成 certificate root，重装多少次都稳定。
SIGN_TOOL=""
[ -f "$SELF_DIR/tools/make-signing-identity.sh" ] && SIGN_TOOL="$SELF_DIR/tools/make-signing-identity.sh"
[ -f "$SELF_DIR/../tools/make-signing-identity.sh" ] && SIGN_TOOL="$SELF_DIR/../tools/make-signing-identity.sh"

if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "    已有自签身份"
elif [ -n "$SIGN_TOOL" ]; then
  bash "$SIGN_TOOL" >/dev/null 2>&1 && echo "    已创建自签身份" || echo "    ! 创建失败，保持原签名"
else
  # 没有工具脚本就地建一个，逻辑与 tools/make-signing-identity.sh 相同。
  WORK="$(mktemp -d)"
  ( cd "$WORK"
    openssl req -x509 -newkey rsa:2048 -keyout k.pem -out c.pem -days 3650 -nodes \
      -subj "/CN=$IDENTITY_NAME/O=DSH Quick Ask/C=CN" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" \
      -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
    openssl pkcs12 -export -out i.p12 -inkey k.pem -in c.pem -passout "pass:$KEYCHAIN_PASS" -name "$IDENTITY_NAME" 2>/dev/null
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
    security import i.p12 -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" -T /usr/bin/codesign -T /usr/bin/security -A
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
  ) >/dev/null 2>&1 && echo "    已创建自签身份" || echo "    ! 创建失败，保持原签名"
  rm -rf "$WORK"
fi

if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1 || true
  HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | awk -v n="$IDENTITY_NAME" 'index($0,n){print $2; exit}')"
  if [ -n "$HASH" ]; then
    codesign --force --sign "$HASH" --keychain "$KEYCHAIN" --identifier "$LABEL" --timestamp=none "$SOURCE_APP" >/dev/null 2>&1 \
      && echo "    已用自签身份签名" || echo "    ! 重签失败，保持原签名"
  fi
fi

if [ -z "$PREFIX" ]; then
  if [ -w /Applications ]; then PREFIX="/Applications"; else PREFIX="$HOME/Applications"; fi
fi
mkdir -p "$PREFIX"
TARGET="$PREFIX/$APP_NAME.app"

echo "==> 3/5 安装到 $TARGET"
rm -rf "$TARGET"
cp -R "$SOURCE_APP" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
# 复制不会破坏签名，所以这里不重签。
codesign --verify --strict "$TARGET" >/dev/null 2>&1 && echo "    签名校验通过" || echo "    ! 签名校验没过（不影响使用，但可能需要重新授权）"

BIN="$TARGET/Contents/MacOS/$EXECUTABLE"
[ -x "$BIN" ] || { echo "✗ 包里没有可执行文件 $EXECUTABLE" >&2; exit 1; }

RESOLVED="$("$BIN" --diagnose 2>/dev/null || true)"
NODE_PATH="$(printf '%s\n' "$RESOLVED" | awk -F': ' '/^node /{print $2}' | head -1 | sed -e 's/[[:space:]]*$//')"
DSH_PATH="$(printf '%s\n' "$RESOLVED" | awk -F': ' '/^dsh 入口 /{print $2}' | head -1 | sed -e 's/[[:space:]]*$//')"
echo "    node = ${NODE_PATH:-<未找到>}"
echo "    dsh  = ${DSH_PATH:-<未找到>}"
[ -z "$NODE_PATH" ] || [ -z "$DSH_PATH" ] && \
  echo "    !! 没找到 node/dsh。请先确认 \`dsh --version\` 可用，再重跑一次。"

echo "==> 4/5 提取模型目录并写配置"
mkdir -p "$SUPPORT"
CATALOG_FILE="$SUPPORT/catalog.json"
echo '{}' > "$CATALOG_FILE"
if [ -n "$NODE_PATH" ] && [ -n "$DSH_PATH" ] && "$BIN" --catalog > "$CATALOG_FILE" 2>/dev/null; then
  python3 - "$CATALOG_FILE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
models = doc.get("models", [])
providers = sorted({m.get("provider", "?") for m in models})
print(f"    {len(models)} 个模型，来自 {len(providers)} 个 provider: {', '.join(providers)}")
PY
else
  echo "    提取失败（没有 node/dsh 或读取不了 settings.yaml），面板会退回内置的 DeepSeek 列表"
fi

python3 - "$CONFIG" "$CATALOG_FILE" "$TRIGGER" "$HOTKEY" "$WORKSPACE" "$NODE_PATH" "$DSH_PATH" "$MODE" "$SOUND" <<'PY'
import json, os, sys
path, catalog_path, trigger, hotkey, workspace, node, dsh, mode, sound = sys.argv[1:10]
existing = {}
if os.path.exists(path):
    try: existing = json.load(open(path))
    except Exception: existing = {}
try: catalog = json.load(open(catalog_path))
except Exception: catalog = {}

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
  echo "==> 5/5 跳过 LaunchAgent"
  echo "手动启动: \"$BIN\""
  exit 0
fi

echo "==> 5/5 注册开机自启"
mkdir -p "$(dirname "$AGENT")" "$LOGS"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$BIN</string></array>
	<key>RunAtLoad</key><true/>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>$LOGS/DSHQuickAsk.launchd.log</string>
	<key>StandardErrorPath</key><string>$LOGS/DSHQuickAsk.launchd.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
pkill -f "DSHQuickAsk" >/dev/null 2>&1 || true
sleep 0.5
launchctl bootstrap "gui/$UID" "$AGENT" >/dev/null 2>&1 || launchctl load -w "$AGENT" >/dev/null 2>&1 || true
sleep 1.5

if pgrep -f "DSHQuickAsk" >/dev/null 2>&1; then
  echo "    ✓ 已启动 (pid $(pgrep -f DSHQuickAsk | tr '\n' ' '))"
else
  echo "    ! 没起来，看看 $LOGS/DSHQuickAsk.launchd.log"
fi

if [ "$TRIGGER" != "hotkey" ]; then
  echo
  echo "    ⚠ 还需要你做一次授权（只需一次）："
  echo "        系统设置 → 隐私与安全性 → 给「DSH Quick Ask」打开"
  echo "        「输入监视」或「辅助功能」（任一项），然后从菜单栏 ✨ 重启一次。"
fi

cat <<DONE

============================================================
安装完成。

  应用      : $TARGET
  配置      : $CONFIG
  触发方式  : $TRIGGER
  音效      : ${SOUND:-静音}      彩虹跑马灯: 开
  工作区    : $WORKSPACE
  日志      : $LOGS/DSHQuickAsk.log

连按两下 Shift 就会弹出输入框。
移除: 双击「卸载.command」，或 bash uninstall.sh
============================================================
DONE
