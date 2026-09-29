#!/usr/bin/env bash
# 打一个可以直接下载使用的发行包。
#
# 产物: dist/release/DSH-QuickAsk-app.zip
#   ├── DSH Quick Ask.app      预编译、ad-hoc 签名
#   ├── 安装.command            双击即可：解隔离 + 装到 /Applications + 配置 + 开机自启
#   ├── 卸载.command
#   ├── 使用说明.txt
#   └── tools/                  装签名身份用的小脚本
#
# 为什么是 ad-hoc 而不是作者本地的自签身份：自签证书只存在于作者机器上，
# 下载者的系统不认识它，反而更容易被 Gatekeeper 判成「已损坏」。
#
# 用法: bash tools/make-release.sh [版本号]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
STAGE="$ROOT/dist/release/DSH Quick Ask $VERSION"
# 文件夹名不要带版本号，否则解压后 .app 不在 zip 根目录，安装脚本就找不到了。
STAGE="$ROOT/dist/release/stage"
OUT="$ROOT/dist/release/DSH-QuickAsk-app.zip"

echo "==> 1/4 编译（ad-hoc 签名，供分发）"
DSH_QUICKASK_ADHOC=1 bash "$ROOT/build.sh"

echo "==> 2/4 组装发行目录"
rm -rf "$ROOT/dist/release"
mkdir -p "$STAGE/tools"
cp -R "$ROOT/dist/DSH Quick Ask.app" "$STAGE/"

cp "$ROOT/tools/install-app.sh" "$STAGE/安装.command"
cp "$ROOT/uninstall.sh" "$STAGE/卸载.command"
cp "$ROOT/tools/make-signing-identity.sh" "$STAGE/tools/"
cp "$ROOT/tools/sign.sh" "$STAGE/tools/"
chmod +x "$STAGE/安装.command" "$STAGE/卸载.command" "$STAGE/tools/"*.sh

cat > "$STAGE/使用说明.txt" <<'NOTE'
DSH Quick Ask —— 连按两下 Shift，弹出输入框，交给 DeepSeek Harness 执行
================================================================

怎么装
------
1. 双击「安装.command」。
   如果 macOS 提示「来自身份不明的开发者」，右键点它 → 打开 → 再点「打开」。
   （命令行等效：在解压出来的目录里执行  bash 安装.command ）
2. 装完后，第一次还需要授权一次：
   系统设置 → 隐私与安全性 → 给「DSH Quick Ask」打开
   「输入监视」或「辅助功能」（任一项即可）。
   然后点菜单栏 ✨ →「重启 DSH Quick Ask」。
3. 连按两下 Shift 试试。

为什么要授权
------------
双击 Shift 靠旁听键盘事件实现（只旁听、不拦截，不影响大写和连选），
macOS 要求这一类程序必须由你本人授权。只需授权一次，之后一直有效。

前提
----
需要机器上已经装好 DeepSeek Harness，并且在终端里能跑：
    dsh --version
没装的话，本工具装上了也执行不了。

卸载
----
双击「卸载.command」。加 --purge 连配置和日志一起清掉。

更多
----
https://github.com/h1284646296-rgb/DeepSeek-Harness-QuickAsk
NOTE

echo "==> 3/4 打包"
# 不用 zip(1)：它把中文文件名写成 UTF-8 却不置 UTF-8 标志位，
# 别的解压工具（尤其 Windows）会看到乱码。Python 的 zipfile 能把标志位和
# 可执行权限都写对。
python3 - "$STAGE" "$OUT" <<'PY'
import os, stat, sys, zipfile

stage, out = sys.argv[1], sys.argv[2]
if os.path.exists(out):
    os.remove(out)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, stage)
            info = zipfile.ZipInfo.from_file(full, rel)
            mode = os.stat(full).st_mode
            info.external_attr = (stat.S_IMODE(mode) | (stat.S_IFREG)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())
print(f"    写入 {out}")
PY
# 顶层目录换个好看的名字
echo "==> 4/4 把 dist/ 恢复成本地签名（别把 ad-hoc 的留给本机安装）"
bash "$ROOT/build.sh" >/dev/null 2>&1 && echo "    ok"

echo
echo "完成: $OUT"
ls -lh "$OUT" | awk '{print "    "$5}'
echo
echo "    解压后顶层内容："
unzip -l "$OUT" | awk 'NR>3 && $4 != "" {print $4}' | grep -v "/$" | grep -v "^$" | head -10
echo "    ..."
echo
echo "    包内 app 的签名："
TMPV="$(mktemp -d)"
( cd "$TMPV" && unzip -q "$OUT" )
codesign -dvvv "$TMPV/DSH Quick Ask.app" 2>&1 | grep -E "Signature|Authority" | sed 's/^/      /'
rm -rf "$TMPV"
