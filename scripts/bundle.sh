#!/bin/zsh
# Builds a release binary and wraps it in Orbit.app (ad-hoc signed).
set -e
cd "${0:A:h}/.."
swift build -c release
app=Orbit.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Orbit "$app/Contents/MacOS/Orbit"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Orbit</string>
  <key>CFBundleIdentifier</key><string>app.orbit.Orbit</string>
  <key>CFBundleExecutable</key><string>Orbit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>Orbit turns speech in your audio and video files into text, on this Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Orbit reads the files you selected in Finder so it can convert them.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $PWD/$app"
