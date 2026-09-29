#!/usr/bin/env bash
# 给一个 .app 签名。签名身份决定 TCC 的匹配依据：
#
#   · ad-hoc   → designated requirement 是 `cdhash H"…"`，二进制一变就变，
#                「输入监视 / 辅助功能」授权会跟着失效；
#   · 自签证书 → DR 是 `identifier "…" and certificate root = H"…"`，
#                只跟证书有关，重编译多少次都稳定。
#
# 所以优先用 tools/make-signing-identity.sh 建好的独立钥匙串里的身份，
# 找不到才退回 ad-hoc。
#
# 用法: bash tools/sign.sh <path/to/App.app>
set -euo pipefail

APP="${1:?用法: bash tools/sign.sh <path/to/App.app>}"
IDENTIFIER="local.dsh.quickask"
KEYCHAIN="$HOME/Library/Keychains/dsh-quickask.keychain-db"
IDENTITY_NAME="DSH Quick Ask Local Signing"

SIGN_HASH=""
if [ -f "$KEYCHAIN" ]; then
  security unlock-keychain -p dshquickask "$KEYCHAIN" >/dev/null 2>&1 || true
  SIGN_HASH="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v n="$IDENTITY_NAME" 'index($0, n) {print $2; exit}')"
fi

if [ -n "$SIGN_HASH" ]; then
  echo "==> signing (自签身份 $SIGN_HASH)"
  if codesign --force --sign "$SIGN_HASH" --keychain "$KEYCHAIN" \
      --identifier "$IDENTIFIER" --timestamp=none "$APP" >/dev/null 2>&1; then
    codesign -d -r- "$APP" 2>&1 | tail -1
    exit 0
  fi
  echo "    !! 自签失败，退回 ad-hoc"
fi

echo "==> signing (ad-hoc；想稳定授权请先跑 bash tools/make-signing-identity.sh)"
codesign --force --sign - --identifier "$IDENTIFIER" --timestamp=none "$APP" >/dev/null
codesign -d -r- "$APP" 2>&1 | tail -1
