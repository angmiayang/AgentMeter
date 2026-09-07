#!/bin/bash
# Builds AgentMeter.app. Needs only the Xcode Command Line Tools.
#
#   ./scripts/build.sh            build into ./build
#   ./scripts/build.sh --install  build, then replace the copy in /Applications
#
# Ad-hoc signing is sufficient here: AgentMeter holds no system permission that
# a re-sign would invalidate, so there is no certificate to set up.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="AgentMeter"
BUNDLE_ID="local.agentmeter"
OUT="build/$APP_NAME.app"
VERSION="1.0"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "==> rendering app icon"
swiftc -swift-version 5 -O -framework AppKit src/makeicon.swift -o build/makeicon
(cd build && ./makeicon)
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

echo "==> compiling"
swiftc -swift-version 5 -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework ServiceManagement \
  src/main.swift -o "$OUT/Contents/MacOS/$APP_NAME"

cp build/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

echo "==> Info.plist"
cat > "$OUT/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundleIconName</key>          <string>AppIcon</string>
  <key>NSHumanReadableCopyright</key>  <string>Local build</string>
</dict>
</plist>
PL

echo "==> signing ad-hoc"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$OUT"
codesign --verify --verbose=1 "$OUT" 2>&1 | tail -2

echo
echo "Built: $ROOT/$OUT"

if [ "${1:-}" = "--install" ]; then
  echo
  echo "==> installing to /Applications"
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$OUT" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "installed and relaunched."
fi
exit 0
