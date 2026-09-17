#!/bin/sh
# Packages the Linux app as a tarball: the release binary, a .desktop entry and
# an install script. Run on Linux with GTK4 dev installed.
#
#   scripts/make_linux_app.sh [version]
#
# Output: dist/BurnRate-<version>-linux-<arch>.tar.gz
set -e

ARCH="$(uname -m)"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  VERSION="${VERSION:-0.0.0}"
fi

DIST="dist"
STAGE="$DIST/BurnRate-$VERSION-linux-$ARCH"
NAME="BurnRate-$VERSION-linux-$ARCH"

# Debian architecture names differ from uname.
case "$ARCH" in
  aarch64) DEB_ARCH="arm64" ;;
  x86_64)  DEB_ARCH="amd64" ;;
  *)       DEB_ARCH="$ARCH" ;;
esac

echo "==> swift build -c release --product BurnRate"
swift build -c release --product BurnRate

BINARY=".build/release/BurnRate"
[ -x "$BINARY" ] || { echo "error: $BINARY not found"; exit 1; }

echo "==> assembling $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"
cp "$BINARY" "$STAGE/bin/BurnRate"
cp Resources/burnrate.desktop "$STAGE/burnrate.desktop"

cat > "$STAGE/install.sh" <<'EOF'
#!/bin/sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
install -Dm755 "$here/bin/BurnRate" "$prefix/bin/BurnRate"
install -Dm644 "$here/burnrate.desktop" "$prefix/share/applications/burnrate.desktop"
echo "Installed to $prefix/bin/BurnRate"
EOF
chmod +x "$STAGE/install.sh"

tar -C "$DIST" -czf "$DIST/$NAME.tar.gz" "$(basename "$STAGE")"
echo "==> done: $DIST/$NAME.tar.gz"
echo "    install: tar -xzf $DIST/$NAME.tar.gz -C /tmp && /tmp/$(basename "$STAGE")/install.sh"

# Optional .deb when dpkg-deb is available.
if command -v dpkg-deb >/dev/null 2>&1; then
  PKG="$DIST/burnrate_${VERSION}_${DEB_ARCH}"
  rm -rf "$PKG"
  mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/share/applications"
  cp "$BINARY" "$PKG/usr/bin/BurnRate"
  cp Resources/burnrate.desktop "$PKG/usr/share/applications/burnrate.desktop"
  cat > "$PKG/DEBIAN/control" <<EOF
Package: burnrate
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: BurnRate <noreply@github.com/RichardODonoghue/burnrate>
Depends: libgtk-4-1 | libgtk-4-0
Section: utils
Priority: optional
Description: Track AI plan subscription usage from the system tray.
EOF
  dpkg-deb --build --root-owner-group "$PKG" "$DIST/burnrate_${VERSION}_${DEB_ARCH}.deb" >/dev/null
  echo "==> done: $DIST/burnrate_${VERSION}_${DEB_ARCH}.deb"
fi
