#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${1:-${PROJECT_DIR:h}}"
BUILD_DIR="${2:-${PROJECT_DIR}/.build}"
APP_DIR="${OUTPUT_DIR}/专注镜.app"
mkdir -p "$OUTPUT_DIR"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" -c release --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/FocusLens" "$APP_DIR/Contents/MacOS/FocusLens"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>专注镜</string>
<key>CFBundleDisplayName</key><string>专注镜</string>
<key>CFBundleIdentifier</key><string>com.focuslens.mac</string>
<key>CFBundleExecutable</key><string>FocusLens</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
ICON_DIR="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICON_DIR"
swift "$PROJECT_DIR/scripts/make-icon.swift" "$BUILD_DIR/icon-1024.png"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$BUILD_DIR/icon-1024.png" --out "$ICON_DIR/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    DOUBLE_SIZE=$((ICON_SIZE * 2))
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$BUILD_DIR/icon-1024.png" --out "$ICON_DIR/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.focuslens.mac "$APP_DIR"
print "应用已生成：$APP_DIR"
