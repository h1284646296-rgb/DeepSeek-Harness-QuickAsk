#!/usr/bin/env bash
# 建一个**本地自签的代码签名身份**，让 App 的 designated requirement 稳定下来。
#
# 为什么需要它：ad-hoc 签名的 DR 是 `cdhash H"…"` —— 二进制一变（也就是每次
# ./build.sh），TCC 就认为这是一个新 App，「输入监视」授权立刻失效，用户得重新勾。
# 换成自签证书后 DR 变成
#
#     identifier "local.dsh.quickask" and certificate root = H"…"
#
# 只跟证书有关，重编译多少次都不变，授权一直有效。
#
# 用的是**独立钥匙串**（不是你的登录钥匙串），密码固定写在脚本里，
# 所以不碰任何个人数据、也不需要你的登录密码。
#
# 用法: bash tools/make-signing-identity.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KC="$HOME/Library/Keychains/dsh-quickask.keychain-db"
KC_PASS="dshquickask"
IDENTITY="DSH Quick Ask Local Signing"
WORK="$ROOT/build/signing"

mkdir -p "$WORK"
cd "$WORK"

if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> 已经存在，跳过创建"
  security find-identity -p codesigning "$KC"
  exit 0
fi

echo "==> 1/4 生成自签证书（仅用于本机代码签名）"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$IDENTITY/O=DSH Quick Ask/C=CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null
openssl pkcs12 -export -out identity.p12 -inkey key.pem -in cert.pem \
  -passout "pass:$KC_PASS" -name "$IDENTITY" 2>/dev/null

echo "==> 2/4 建独立钥匙串 $KC"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
# 6 小时自动锁定：够一次构建，也不至于长期敞着。
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"

echo "==> 3/4 导入身份"
security import identity.p12 -k "$KC" -P "$KC_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -A
# 免掉 codesign 每次访问私钥时的弹窗。
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

echo "==> 4/4 完成"
security find-identity -p codesigning "$KC" | sed 's/^/    /'
echo
echo "    CSSMERR_TP_NOT_TRUSTED 是正常的：证书没有加进系统信任链，"
echo "    只用来给本机 App 一个稳定的签名，不影响运行。"
echo "    现在 bash build.sh 会自动用上它。"
