#!/usr/bin/env bash
# Gate 0: does a Tauri v2 tray actually work on Linux?
#
# Builds the app and runs scripts/tauri-smoke-inner.sh in a container with Xvfb
# and a real StatusNotifierWatcher, asserting tray registration, DBusMenu
# service, in-place menu text mutation and click dispatch.
#
# Requires Docker. Run from the repo root: scripts/tauri-smoke.sh
set -euo pipefail

cd "$(dirname "$0")/.."

RUST_IMAGE="${RUST_IMAGE:-rust:1.97-bookworm}"

docker run --rm -v "$PWD":/work -w /work "$RUST_IMAGE" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Build deps: WebKitGTK 4.1 for the webview, GTK3 + libayatana for the
# tray-icon backend. libayatana is a GTK3 library, but in a Tauri process there
# is no GTK4 in the way — which is exactly why this works where the old
# hand-rolled GTK4 tray did not.
apt-get install -y -qq --no-install-recommends \
  libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev libjavascriptcoregtk-4.1-dev \
  libayatana-appindicator3-dev librsvg2-dev patchelf build-essential pkg-config \
  ca-certificates curl file libssl-dev libxdo-dev \
  xvfb xauth dbus-x11 haskell-status-notifier-item-utils libglib2.0-bin >/dev/null

# Build into a container-local target dir, never the mounted one. Sharing a
# target/ between the host (macOS) and the container (Linux) corrupts the
# proc-macro artifacts, and the build then fails with E0463 for every
# dependency of tauri-build and gtk.
export CARGO_TARGET_DIR=/tmp/tauri-target

echo "== build =="
cargo build --workspace 2>&1 | tail -3

echo "== tray =="
dbus-run-session -- bash scripts/tauri-smoke-inner.sh /work "$CARGO_TARGET_DIR/debug/burnrate-desktop"
'
