#!/bin/sh
# Builds and smoke-runs the Linux app in an Ubuntu container.
#
#   1. GTK window launches under Xvfb and stays up.
#   2. With a session bus + StatusNotifierWatcher: the main tray registers, a
#      per-provider widget tray registers too, the DBusMenu layout is served,
#      and a "clicked" event dispatches (Quit exits).
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
cat > /tmp/inner.sh <<"INNER"
#!/usr/bin/env bash
set -e
timeout 3 xvfb-run -a .build/debug/BurnRate >/dev/null 2>&1 || true
SETTINGS=$(find "$HOME" -name linux-settings.json 2>/dev/null | head -1)
echo "settings=$SETTINGS"
if [ -n "$SETTINGS" ]; then
  sed -i "s/\"widgetProviders\":\[\]/\"widgetProviders\":[\"Claude\"]/" "$SETTINGS"
fi
status-notifier-watcher > /tmp/watcher.log 2>&1 &
sleep 1
xvfb-run -a .build/debug/BurnRate > /tmp/app.log 2>&1 &
APP=$!
sleep 8
ITEMS=$(gdbus call --session --dest org.kde.StatusNotifierWatcher --object-path /StatusNotifierWatcher \
    --method org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems)
COUNT=$(printf "%s" "$ITEMS" | grep -oE "org\.kde\.StatusNotifierItem-[0-9]+-[0-9]+" | wc -l)
echo "tray count=$COUNT"
[ "$COUNT" -ge 2 ] || { echo "tray: expected main + widget"; exit 1; }
SVC=$(printf "%s" "$ITEMS" | grep -oE "org\.kde\.StatusNotifierItem-[0-9]+-0" | head -1)
[ -n "$SVC" ] || { echo "tray: no main item"; exit 1; }
echo "tray: registered $SVC"
LAYOUT=$(gdbus call --session --dest "$SVC" --object-path /MenuBar \
    --method com.canonical.dbusmenu.GetLayout -- 0 -1 "[]")
printf "%s" "$LAYOUT" | grep -q "Quit" && echo "tray: menu OK" || { echo "tray: empty menu"; exit 1; }

# Resolve item ids by label. The menu row count is not fixed — a "Not working:"
# block only appears when a provider is broken — so positional ids drift.
menu_id() {
  printf "%s" "$LAYOUT" | python3 -c "
import re, sys
want = sys.argv[1]
for m in re.finditer(r\"<\\((\\d+), \\{[\\x27]label[\\x27]: <[\\x27]([^\\x27]*)[\\x27]>\", sys.stdin.read()):
    if m.group(2).startswith(want):
        print(m.group(1)); break
" "$1"
}
CHARTS_ID=$(menu_id "Charts")
QUIT_ID=$(menu_id "Quit")
[ -n "$CHARTS_ID" ] && [ -n "$QUIT_ID" ] || { echo "tray: could not resolve menu ids"; exit 1; }
echo "tray: charts id=$CHARTS_ID quit id=$QUIT_ID"

# Open the charts window and let Cairo draw it.
gdbus call --session --dest "$SVC" --object-path /MenuBar \
    --method com.canonical.dbusmenu.Event -- "$CHARTS_ID" clicked "<uint32 0>" 0 >/dev/null || true
sleep 3
if kill -0 "$APP" 2>/dev/null; then echo "charts: window OK"; else echo "charts: crash"; cat /tmp/app.log; exit 1; fi
# Quit.
gdbus call --session --dest "$SVC" --object-path /MenuBar \
    --method com.canonical.dbusmenu.Event -- "$QUIT_ID" clicked "<uint32 0>" 0 >/dev/null || true
sleep 3
if kill -0 "$APP" 2>/dev/null; then echo "tray: click not dispatched"; exit 1; else echo "tray: click dispatched"; fi
INNER
dbus-run-session -- bash /tmp/inner.sh
'
