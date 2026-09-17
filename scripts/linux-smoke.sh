#!/bin/sh
# Builds and smoke-runs the Linux app in an Ubuntu container.
#
#   1. GTK window launches under Xvfb and stays up.
#   2. With a session bus + StatusNotifierWatcher, the tray registers, the
#      DBusMenu layout is served, and a "clicked" event dispatches (Quit exits).
#
# Requires Docker. Not run in CI (CI only compiles the target).
set -e

docker run --rm -v "$PWD":/work -w /work swift:6.0-noble bash -lc '
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  libgtk-4-dev xvfb dbus-x11 haskell-status-notifier-item-utils >/dev/null
swift build --product BurnRate

echo "== window =="
xvfb-run -a .build/debug/BurnRate > /tmp/window.log 2>&1 &
APP=$!
sleep 6
if kill -0 $APP 2>/dev/null; then echo "window: OK"; else echo "window: exited"; cat /tmp/window.log; exit 1; fi
kill $APP 2>/dev/null || true

echo "== tray =="
dbus-run-session -- bash -c "
  status-notifier-watcher > /tmp/watcher.log 2>&1 &
  sleep 1
  xvfb-run -a .build/debug/BurnRate > /tmp/app.log 2>&1 &
  APP=\$!
  sleep 8
  ITEMS=\$(gdbus call --session --dest org.kde.StatusNotifierWatcher \
      --object-path /StatusNotifierWatcher \
      --method org.freedesktop.DBus.Properties.Get \
      org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems)
  SVC=\$(echo \"\$ITEMS\" | grep -oE \"org\.kde\.StatusNotifierItem-[0-9]+-1\" | head -1)
  if [ -z \"\$SVC\" ]; then echo \"tray: not registered\"; cat /tmp/app.log; exit 1; fi
  echo \"tray: registered \$SVC\"
  gdbus call --session --dest \$SVC --object-path /MenuBar \
      --method com.canonical.dbusmenu.GetLayout -- 0 -1 \"[]\" | grep -q \"Quit\" \
      && echo \"tray: menu OK\" || { echo \"tray: empty menu\"; exit 1; }
  EMPTY=\"<uint32 0>\"
  gdbus call --session --dest \$SVC --object-path /MenuBar \
      --method com.canonical.dbusmenu.Event -- 6 clicked \"\$EMPTY\" 0 >/dev/null || true
  sleep 3
  if kill -0 \$APP 2>/dev/null; then echo \"tray: click not dispatched\"; exit 1; else echo \"tray: click dispatched\"; fi
"
'
