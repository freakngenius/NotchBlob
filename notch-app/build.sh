#!/bin/bash
# Builds NotchAlive.app next to this script. Needs Xcode's command line tools.
set -e
cd "$(dirname "$0")"
APP=NotchAlive.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 NotchAlive.swift -o "$APP/Contents/MacOS/NotchAlive" \
  -framework AppKit -framework AVFoundation -framework Accelerate -framework Speech
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Notch Alive</string>
  <key>CFBundleIdentifier</key><string>io.github.notchalive.app</string>
  <key>CFBundleExecutable</key><string>NotchAlive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Notch Alive listens for your voice so the notch can react. Audio is analysed live and never saved.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Optional: Notch Alive listens for the wake word "blob". Recognition runs on this Mac only.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
