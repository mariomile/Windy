#!/bin/bash
# Builds Windy.app (release), signs it ad hoc, and zips it to build/Windy.zip.
# Set SIGN_IDENTITY to a "Developer ID Application: ..." identity to sign for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.0"
APP="build/Windy.app"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Windy" "$APP/Contents/MacOS/Windy"

# App icon, drawn by the same code the app uses.
ICONSET="build/Windy.iconset"
mkdir -p "$ICONSET"
swift scripts/render-icon.swift "build/icon-1024.png"
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Windy</string>
  <key>CFBundleDisplayName</key><string>Windy</string>
  <key>CFBundleIdentifier</key><string>app.windy.mac</string>
  <key>CFBundleExecutable</key><string>Windy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"

(cd build && ditto -c -k --keepParent Windy.app Windy.zip)
echo "Built $APP and build/Windy.zip"
