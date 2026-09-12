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
VERSION="${1:-}"
DIST="dist"

CT=/Library/Developer/CommandLineTools

# CLT 27.0's MacOSX27.0 SDK is missing the SwiftUI macro plugin
# (libSwiftUIMacros) — @State etc. cannot expand. Pin the last-good SDK
# until the CLT ships a fixed 27.x SDK. Honor an explicit SDKROOT.
# (Also: CLT 27's driver no longer auto-discovers the Testing macro plugin
# in plugins/testing/ — test.sh passes -load-plugin-library explicitly.)
if [[ -z "$SDKROOT" ]]; then
  good="$(ls -d "$CT"/SDKs/MacOSX2*.sdk 2>/dev/null | grep -v 'MacOSX\.sdk$' | sort -V | grep -v 'MacOSX27' | tail -1)"
  [[ -n "$good" ]] && export SDKROOT="$good"
fi

echo "==> swift build -c release (arm64)"
swift build -c release --arch arm64

BINARY=".build/release/${APP_NAME}"
[[ -x "$BINARY" ]] || { echo "error: $BINARY not found"; exit 1; }

echo "==> assembling ${DIST}/${APP_NAME}.app"
APP="${DIST}/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Version: explicit arg wins, else latest semver tag, else 0.0.0.
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
  VERSION="${VERSION:-0.0.0}"
fi

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

echo "==> verifying arm64-only slice"
ARCH_OUT="$(file "$APP/Contents/MacOS/${APP_NAME}")"
case "$ARCH_OUT" in
  *arm64*) ;;
  *) echo "error: binary is not arm64: $ARCH_OUT"; exit 1 ;;
esac
case "$ARCH_OUT" in
  *x86_64*) echo "error: universal build not allowed (arm64 only): $ARCH_OUT"; exit 1 ;;
esac

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP"

# Re-register with LaunchServices so Notification Center picks up the new
# icns (icon cache keys off the bundle registration). Unregister first: a
# stale record for this path (e.g. under a previous bundle ID) can make
# `open` fail with -600 procNotFound even though the build is valid.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$APP" 2>/dev/null
"$LSREG" -f "$APP" 2>/dev/null

echo "==> done: $APP"
echo "    launch with: open ${APP}"
