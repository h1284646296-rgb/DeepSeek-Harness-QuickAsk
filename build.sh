#!/usr/bin/env bash
# Build "DSH Quick Ask.app": compile the Swift agent, attach the icon, and
# ad-hoc sign the bundle so LaunchServices and the Carbon hotkey treat it as a
# stable app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DSH Quick Ask"
EXECUTABLE="DSHQuickAsk"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BUILD="$ROOT/build"

if [ ! -f "$BUILD/AppIcon.icns" ]; then
  bash "$ROOT/tools/make-icon.sh"
fi

# 音效是合成出来的，不进版本库；缺失时现做一份。
if [ ! -f "$ROOT/Resources/duang.wav" ]; then
  python3 "$ROOT/tools/make-duang.py" "$ROOT/Resources/duang.wav"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc \
  -O \
  -whole-module-optimization \
  -module-cache-path "$BUILD/ModuleCache" \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -o "$APP/Contents/MacOS/$EXECUTABLE" \
  "$ROOT/Sources/"*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/duang.wav" "$APP/Contents/Resources/duang.wav"
cp "$ROOT/tools/model-catalog.js" "$APP/Contents/Resources/model-catalog.js"
printf 'APPL????' > "$APP/Contents/PkgInfo"

bash "$ROOT/tools/sign.sh" "$APP"

echo "==> built: $APP"
echo "==> binary: $APP/Contents/MacOS/$EXECUTABLE"
