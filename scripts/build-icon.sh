#!/usr/bin/env bash
# build-icon.sh —— 生成 build/AppIcon.icns（被 build-app.sh 调用）
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
PNG="build/icon-1024.png"
ICONSET="build/AppIcon.iconset"
ICNS="build/AppIcon.icns"

echo "→ Render base 1024×1024"
swift run -c release ClaudePetIconGen "$PNG" >/dev/null

echo "→ Compose .iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# pairs: <label>:<pixels-for-1x>:<pixels-for-2x>
for entry in 16:16:32 32:32:64 128:128:256 256:256:512 512:512:1024; do
  IFS=: read label one two <<< "$entry"
  sips -z "$one" "$one" "$PNG" --out "$ICONSET/icon_${label}x${label}.png"  >/dev/null
  sips -z "$two" "$two" "$PNG" --out "$ICONSET/icon_${label}x${label}@2x.png" >/dev/null
done

echo "→ iconutil → $ICNS"
iconutil -c icns -o "$ICNS" "$ICONSET"

echo "✓ $ICNS"
