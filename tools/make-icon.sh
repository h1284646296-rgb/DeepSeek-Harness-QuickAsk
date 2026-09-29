#!/usr/bin/env bash
# Render the 1024px master PNG, then slice it into an .icns with sips/iconutil.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
MASTER="$BUILD/icon-1024.png"
ICONSET="$BUILD/AppIcon.iconset"

mkdir -p "$BUILD"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Keep the module cache inside the project: builds must not need ~/Library.
swift -module-cache-path "$BUILD/ModuleCache" "$ROOT/tools/make-icon.swift" "$MASTER" >/dev/null

while read -r pixels label; do
  sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/icon_${label}.png" >/dev/null
done <<'SIZES'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SIZES

iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
echo "==> icon: $BUILD/AppIcon.icns"
