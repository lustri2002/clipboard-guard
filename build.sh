#!/bin/zsh
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="$ROOT/Clipboard Guard.app"
BUILD_CACHE="${TMPDIR:-/tmp}/clipboard-guard-swift-cache-$UID"
mkdir -p "$APP/Contents/MacOS" "$BUILD_CACHE"
/usr/bin/xcrun swiftc -swift-version 5 -O -g -module-cache-path "$BUILD_CACHE" \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework Cocoa -framework UserNotifications \
  "$ROOT/Sources/main.swift" -o "$APP/Contents/MacOS/ClipboardGuard"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>it.alessiolustri.clipboard-guard</string>
<key>CFBundleName</key><string>Clipboard Guard</string>
<key>CFBundleDisplayName</key><string>Clipboard Guard</string>
<key>CFBundleExecutable</key><string>ClipboardGuard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier it.alessiolustri.clipboard-guard "$APP"
/usr/bin/codesign --verify --strict "$APP"
print "Build complete: $APP"
