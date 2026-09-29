#!/usr/bin/env bash
# DSH Quick Ask 安装器。
#
# 三种跑法都对：
#   1. 从源码目录跑    bash install.sh          → 编译，然后安装
#   2. 从网上直接跑    curl -fsSL <raw>/install.sh | bash
#                                              → 先试下载预编译包，不行就下源码编译
#   3. Release 里双击  「安装.command」          → 见 tools/install-app.sh
#
# 真正「把 app 装到位、写配置、注册 LaunchAgent」的逻辑都在 tools/install-app.sh，
# 这里只负责把 .app 弄出来。
set -euo pipefail

REPO_SLUG="h1284646296-rgb/DeepSeek-Harness-QuickAsk"
REPO_BRANCH="main"
APP_NAME="DSH Quick Ask"

# 参数原样转交给 install-app.sh
PASSTHRU=()
FORCE_SOURCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from-source) FORCE_SOURCE=1; shift ;;
    -h|--help)
      cat <<'HELP'
用法: bash install.sh [选项]

  --workspace <路径>   headless 执行时的工作目录（默认 ~/Desktop/harness）
  --trigger <方式>     double-shift（默认）/ double-shift-carbon / hotkey / both
  --hotkey <组合键>    组合键触发（默认空 = 不占用任何组合键）
  --mode <模式>        inline（默认，面板内出结果）/ terminal（开终端窗口）
  --sound <音效>       duang（默认）/ 系统音效名 / "" 静音
  --prefix <目录>      安装目录（默认 /Applications）
  --no-agent           只装应用，不注册开机自启
  --from-source        强制从源码编译，不用预编译包
HELP
      exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

SELF="${BASH_SOURCE[0]:-$0}"
ROOT="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || pwd)"
TEMP=""
cleanup() { [ -n "$TEMP" ] && rm -rf "$TEMP" || true; }
trap cleanup EXIT

fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 15 --max-time 300 -o "$out" "$url" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" && return 0
  fi
  return 1
}

APP_SRC=""

if [ -d "$ROOT/Sources" ] && [ -f "$ROOT/build.sh" ]; then
  echo "==> 从源码编译"
  bash "$ROOT/build.sh"
  APP_SRC="$ROOT/dist/$APP_NAME.app"
else
  TEMP="$(mktemp -d)"
  cd "$TEMP"

  if [ "$FORCE_SOURCE" = "0" ]; then
    echo "==> 尝试下载预编译包（不用编译器，最快）"
    if fetch "https://github.com/$REPO_SLUG/releases/latest/download/DSH-QuickAsk-app.zip" app.zip 2>/dev/null \
       && unzip -qo app.zip 2>/dev/null; then
      APP_SRC="$TEMP/$APP_NAME.app"
      echo "    ✓ 下载完成"
    else
      echo "    下载不到（网络或还没有 Release），改用源码编译"
      FORCE_SOURCE=1
    fi
  fi

  if [ -z "$APP_SRC" ]; then
    echo "==> 下载源码并编译"
    fetch "https://codeload.github.com/$REPO_SLUG/tar.gz/refs/heads/$REPO_BRANCH" src.tar.gz
    tar -xzf src.tar.gz
    SRC_DIR="$(find . -maxdepth 1 -type d -name 'DeepSeek-Harness-QuickAsk-*' | head -1)"
    [ -n "$SRC_DIR" ] || { echo "✗ 源码包解压后找不到目录" >&2; exit 1; }

    if ! command -v swiftc >/dev/null 2>&1; then
      echo
      echo "✗ 这台机器没有 swiftc（Xcode 命令行工具）。"
      echo "  两种办法："
      echo "    1) 运行 xcode-select --install ，装完再跑一次本命令；"
      echo "    2) 到 Release 页下载预编译的 zip，双击里面的「安装.command」。"
      exit 1
    fi

    bash "$SRC_DIR/build.sh"
    APP_SRC="$SRC_DIR/dist/$APP_NAME.app"
  fi
fi

[ -d "$APP_SRC" ] || { echo "✗ 没能得到 $APP_NAME.app" >&2; exit 1; }

INSTALLER="$ROOT/tools/install-app.sh"
if [ ! -f "$INSTALLER" ]; then
  INSTALLER="$(find "${TEMP:-/nonexistent}" "$ROOT" -name install-app.sh -path '*/tools/*' 2>/dev/null | head -1)"
fi
[ -f "$INSTALLER" ] || INSTALLER="$(find "${TEMP:-/nonexistent}" -maxdepth 4 -name install-app.sh 2>/dev/null | head -1)"
[ -f "$INSTALLER" ] || { echo "✗ 找不到 tools/install-app.sh" >&2; exit 1; }

bash "$INSTALLER" "$APP_SRC" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
