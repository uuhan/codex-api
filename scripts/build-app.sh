#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CodexAPI.app"
BINARY="$ROOT/.build/release/CodexAPI"
VERSION="${VERSION:-1.0.1}"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/CodexAPI"
chmod +x "$APP/Contents/MacOS/CodexAPI"
cp "$ROOT/Resources/CodexAPI.icns" "$APP/Contents/Resources/CodexAPI.icns"
cp "$ROOT/Resources/TrayIcon.png" "$APP/Contents/Resources/TrayIcon.png"
cp "$ROOT/Resources/TrayIcon@2x.png" "$APP/Contents/Resources/TrayIcon@2x.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexAPI</string>
  <key>CFBundleIdentifier</key>
  <string>ai.xu.codex-api</string>
  <key>CFBundleIconFile</key>
  <string>CodexAPI</string>
  <key>CFBundleName</key>
  <string>CodexAPI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

echo "Built $APP"
