#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AIOStudio"
APP="dist/AI-O Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICON_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_DIR"' EXIT
swift scripts/render-icon.swift "$ICON_DIR/icon.png"
mkdir "$ICON_DIR/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_DIR/icon.png" --out "$ICON_DIR/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_DIR/icon.png" --out "$ICON_DIR/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/AIOStudio"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIOStudio</string>
<key>CFBundleIdentifier</key><string>pro.ai-o.studio</string>
<key>CFBundleName</key><string>AI-O Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDisplayName</key><string>AI-O Studio</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" "dist/AI-O-Studio-macOS.zip"
