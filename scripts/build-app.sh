#!/usr/bin/env bash
# build-app.sh —— 把 SPM executable 打成 macOS .app bundle。
# 输出：build/dist/ClaudePet.app
#
# 用法:
#   ./scripts/build-app.sh           # release 构建 + ad-hoc codesign
#   ./scripts/build-app.sh --install # 上一行 + 复制到 /Applications/
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudePet"
DISPLAY_NAME="Claude Pet"
BUNDLE_ID="com.czg.claudepet"
VERSION="${CLAUDE_PET_VERSION:-1.0.0}"

DIST_DIR="build/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

echo "→ swift build -c release"
swift build -c release

BIN=".build/release/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "✗ 构建产物不存在：$BIN" >&2
  exit 1
fi

echo "→ 重新生成 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "→ 写 Info.plist"
cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
EOF

echo "→ 复制 pets/ 到 Resources/"
if [[ -d pets ]]; then
  cp -R pets "$RESOURCES_DIR/pets"
else
  echo "⚠ 项目根没有 pets/ 目录，应用将以"无可用形象"启动" >&2
fi

echo "→ ad-hoc codesign"
codesign -s - --force --deep --timestamp=none "$APP_DIR" 2>&1 | grep -v 'replacing existing signature' || true

echo ""
echo "✓ Built: $APP_DIR"

if [[ $INSTALL -eq 1 ]]; then
  echo "→ 安装到 /Applications/"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" "/Applications/"
  echo "✓ Installed: /Applications/$APP_NAME.app"
  echo "  open -a $APP_NAME"
else
  echo "  打开:    open '$APP_DIR'"
  echo "  安装:    cp -R '$APP_DIR' /Applications/"
  echo "  或一键: ./scripts/build-app.sh --install"
fi
