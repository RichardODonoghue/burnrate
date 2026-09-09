#!/bin/zsh
# Builds BurnRate.app — a self-contained macOS app bundle from the SPM
# release binary. No Xcode project needed.
#
# Output: dist/BurnRate.app
# Usage: scripts/make_app.sh [version]
set -e

APP_NAME="BurnRate"
# Fresh bundle ID: iconservices/Notification Center cache the app icon per
# bundle ID, and the old ID ("com.burnrate.app") had a blank icon baked in
# from an early iconless build that no cache clearing would dislodge.
BUNDLE_ID="com.burnrate.desktop"
VERSION="${1:-0.1.0}"
DIST="dist"

echo "==> swift build -c release"
swift build -c release

BINARY=".build/release/${APP_NAME}"
[[ -x "$BINARY" ]] || { echo "error: $BINARY not found"; exit 1; }

echo "==> assembling ${DIST}/${APP_NAME}.app"
APP="${DIST}/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>         <string>${APP_NAME}</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundleVersion</key>             <string>${VERSION}</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSHumanReadableCopyright</key>    <string>Copyright © 2026</string>
</dict>
</plist>
EOF

cp "$BINARY" "$APP/Contents/MacOS/${APP_NAME}"

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

# Re-register with LaunchServices so Notification Center picks up the new
# icns (icon cache keys off the bundle registration).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null

echo "==> done: $APP"
echo "    launch with: open ${APP}"
