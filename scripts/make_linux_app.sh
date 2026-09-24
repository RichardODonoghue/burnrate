#!/bin/sh
# Packages the Linux app as a tarball + .deb: the release binary, the Swift
# runtime libraries it needs, a .desktop entry and an install script.
#
#   scripts/make_linux_app.sh [version]
#
# Output: dist/BurnRate-<version>-linux-<arch>.tar.gz and
#         dist/burnrate_<version>_<debarch>.deb
#
# The Swift runtime (libswiftCore.so, libFoundation.so, …) is not a distro
# package, so it is bundled and found via an rpath of
# `$ORIGIN/../lib/BurnRate` (works for both the tarball layout and /usr/bin).
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
LIBDIR="lib/BurnRate"

# Debian architecture names differ from uname.
case "$ARCH" in
  aarch64) DEB_ARCH="arm64" ;;
  x86_64)  DEB_ARCH="amd64" ;;
  *)       DEB_ARCH="$ARCH" ;;
esac

echo "==> swift build -c release --product BurnRate"
swift build -c release --product BurnRate \
  -Xlinker -rpath -Xlinker '$ORIGIN/../lib/BurnRate'

BINARY=".build/release/BurnRate"
[ -x "$BINARY" ] || { echo "error: $BINARY not found"; exit 1; }

# Locate the toolchain's Swift runtime libraries.
SWIFT_BIN="$(command -v swift)"
SWIFT_LIB_DIR=""
for dir in \
  "$(cd "$(dirname "$SWIFT_BIN")/.." && pwd)/lib/swift/linux" \
  "$(cd "$(dirname "$SWIFT_BIN")/../.." && pwd)/lib/swift/linux" \
  /usr/lib/swift/linux \
  /usr/local/lib/swift/linux; do
  if [ -f "$dir/libswiftCore.so" ]; then SWIFT_LIB_DIR="$dir"; break; fi
done
if [ -z "$SWIFT_LIB_DIR" ]; then
  SWIFT_LIB_DIR="$(dirname "$(find / -name libswiftCore.so 2>/dev/null | head -1)")"
fi
if [ -z "$SWIFT_LIB_DIR" ] || [ ! -f "$SWIFT_LIB_DIR/libswiftCore.so" ]; then
  echo "error: could not find the Swift runtime libraries (libswiftCore.so)" >&2
  exit 1
fi
echo "==> bundling Swift runtime from $SWIFT_LIB_DIR"

copy_runtime() {
  dest="$1"
  mkdir -p "$dest"
  for pattern in 'libswift*.so*' 'libFoundation*.so*' 'lib_Foundation*' \
                 'libdispatch.so*' 'libBlocksRuntime.so*' 'libswiftDispatch.so*'; do
    for file in "$SWIFT_LIB_DIR"/$pattern; do
      [ -e "$file" ] || continue
      case "$file" in
        *XCTest*|*Testing*|*Observation*|*plugin*) continue ;;
      esac
      cp -f "$file" "$dest/"
    done
  done
}

echo "==> assembling $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"
cp "$BINARY" "$STAGE/bin/BurnRate"
cp Resources/burnrate.desktop "$STAGE/burnrate.desktop"
copy_runtime "$STAGE/$LIBDIR"

cat > "$STAGE/install.sh" <<'EOF'
#!/bin/sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
install -Dm755 "$here/bin/BurnRate" "$prefix/bin/BurnRate"
install -Dm644 "$here/burnrate.desktop" "$prefix/share/applications/burnrate.desktop"
mkdir -p "$prefix/lib/BurnRate"
cp -f "$here/lib/BurnRate/"*.so* "$prefix/lib/BurnRate/" 2>/dev/null || true

missing="$(ldd "$prefix/bin/BurnRate" 2>/dev/null | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')"
if [ -n "$missing" ]; then
  echo "Installed to $prefix/bin/BurnRate, but these libraries are missing:"
  echo "  $missing"
  echo "GTK4 is required (the Swift runtime is bundled). Install it with:"
  echo "  Fedora:        sudo dnf install gtk4"
  echo "  Debian/Ubuntu: sudo apt install libgtk-4-1"
  echo "  Arch:          sudo pacman -S gtk4"
else
  echo "Installed to $prefix/bin/BurnRate"
fi
EOF
chmod +x "$STAGE/install.sh"

tar -C "$DIST" -czf "$DIST/$NAME.tar.gz" "$(basename "$STAGE")"
echo "==> done: $DIST/$NAME.tar.gz"
echo "    install: tar -xzf $DIST/$NAME.tar.gz -C /tmp && /tmp/$(basename "$STAGE")/install.sh"

# Optional .deb when dpkg-deb is available.
if command -v dpkg-deb >/dev/null 2>&1; then
  PKG="$DIST/burnrate_${VERSION}_${DEB_ARCH}"
  rm -rf "$PKG"
  mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/share/applications" "$PKG/usr/lib/BurnRate"
  cp "$BINARY" "$PKG/usr/bin/BurnRate"
  cp Resources/burnrate.desktop "$PKG/usr/share/applications/burnrate.desktop"
  cp "$STAGE/$LIBDIR/"*.so* "$PKG/usr/lib/BurnRate/" 2>/dev/null || true
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
