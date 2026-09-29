#!/usr/bin/env bash
# Inner half of the Gate 0 tray smoke — runs INSIDE the container, on a private
# D-Bus session (dbus-run-session) with a real StatusNotifierWatcher.
#
# Asserts:
#   1. window + webview come up under Xvfb
#   2. three tray items register with the watcher (main + two per-plan widgets)
#   3. the main item serves a DBusMenu layout
#   4. menu text MUTATES in place — on Linux a tray menu cannot be swapped once
#      set, so the real menu has to edit items, which is what the old
#      hand-rolled tray could not do
#   5. a DBusMenu click dispatches to Rust and quits the app
#
# Tauri reaches the Linux tray through libayatana-appindicator, so items live at
# /org/ayatana/NotificationItem/<sanitised id> with the menu at <item>/Menu.
set -euo pipefail

cd "${1:-/work}"
# The binary may live in a container-local target dir (see tauri-smoke.sh).
APP="${2:-${1:-/work}/target/debug/burnrate-desktop}"

mkdir -p /tmp/run && chmod 700 /tmp/run
export XDG_RUNTIME_DIR=/tmp/run
export XDG_DATA_HOME=/tmp/xdg-data
# WebKitGTK needs software rendering in a headless container.
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export LIBGL_ALWAYS_SOFTWARE=1
export GDK_BACKEND=x11

WATCHER_NAME=org.kde.StatusNotifierWatcher

# tray-icon builds indicator ids as "tray-icon tray app <id>"; libayatana
# sanitises them for the object path.
indicator_path() {
  local sanitised
  sanitised=$(printf 'tray-icon tray app %s' "$1" | sed 's/[^a-zA-Z0-9]/_/g')
  printf '/org/ayatana/NotificationItem/%s' "$sanitised"
}

props() {
  # props <bus-name> <object-path> [property]
  if [ $# -ge 3 ]; then
    gdbus call --session --dest "$1" --object-path "$2" \
      --method org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierItem "$3" 2>/dev/null || true
  else
    gdbus call --session --dest "$1" --object-path "$2" \
      --method org.freedesktop.DBus.Properties.GetAll org.kde.StatusNotifierItem 2>/dev/null || true
  fi
}

# Seed settings with two widget providers. Widgets are settings-driven now, so
# without this the app correctly installs only the main item — and the test
# would stop proving that per-plan tray items work at all. It also exercises the
# XDG settings path (~/.config/BurnRate on Linux).
mkdir -p "$HOME/.config/BurnRate"
cat > "$HOME/.config/BurnRate/settings.json" <<'SETTINGS'
{
  "milestones": [{ "provider": "Claude", "windowLabel": "Rolling", "step": 20 }],
  "widgetProviders": ["Claude", "Codex"],
  "burnAlerts": [],
  "costAlerts": [],
  "notifyOnReset": true,
  "pollIntervalSeconds": 300,
  "includesCharts": true
}
SETTINGS

status-notifier-watcher > /tmp/watcher.log 2>&1 &
WATCHER=$!
sleep 1
xvfb-run -a -s "-screen 0 1280x1024x24" "$APP" > /tmp/app.log 2>&1 &
APP_PID=$!

fail() {
  echo "FAIL: $1"
  echo "--- app.log ---"
  cat /tmp/app.log
  echo "--- watcher.log ---"
  cat /tmp/watcher.log
  kill "$APP_PID" 2>/dev/null || true
  exit 1
}

registered() {
  gdbus call --session --dest "$WATCHER_NAME" --object-path /StatusNotifierWatcher \
    --method org.freedesktop.DBus.Properties.Get \
    "$WATCHER_NAME" RegisteredStatusNotifierItems 2>/dev/null || true
}

# Wait for the three registrations instead of sleeping blindly.
ITEMS=""
COUNT=0
for _ in $(seq 1 30); do
  sleep 1
  kill -0 "$APP_PID" 2>/dev/null || fail "app exited early"
  ITEMS=$(registered)
  COUNT=$(printf '%s' "$ITEMS" | grep -oE ':[0-9]+\.[0-9]+' | wc -l)
  [ "$COUNT" -ge 3 ] && break
done

echo "window: $(kill -0 "$APP_PID" 2>/dev/null && echo OK || echo gone)"
echo "tray count=$COUNT"
[ "$COUNT" -ge 3 ] || fail "expected main + 2 widgets, got $COUNT ($ITEMS)"

# All three items come from one connection; that name is the app.
BUS=$(printf '%s' "$ITEMS" | grep -oE ':[0-9]+\.[0-9]+' | head -1)
MAIN_PATH=$(indicator_path main)
# Widget ids are "widget-<provider>", matching the seeded widgetProviders.
WIDGET_PATH=$(indicator_path widget-Claude)
echo "tray: bus=$BUS main=$MAIN_PATH"

main_props=$(props "$BUS" "$MAIN_PATH" || true)
printf '%s' "$main_props" | grep -q "'Id':" \
  || fail "no StatusNotifierItem properties at $MAIN_PATH: $main_props"
printf '%s' "$main_props" | grep -q "'Status': <'Active'>" \
  || fail "tray item is not Active: $main_props"
echo "tray: main item exports StatusNotifierItem (Active)"

layout() {
  gdbus call --session --dest "$BUS" --object-path "$MAIN_PATH/Menu" \
    --method com.canonical.dbusmenu.GetLayout -- 0 -1 '[]'
}

LAYOUT=$(layout || true)
# The real menu, as StatusMenuBuilder produces it. The container has no
# credentials, so the status row is the "Loading usage…" placeholder.
printf '%s' "$LAYOUT" | grep -q "Usage Dashboard" ||
  fail "menu missing the dashboard row: $LAYOUT"
# Charts is opt-in per platform; the seeded settings enable it.
printf '%s' "$LAYOUT" | grep -q "Charts" ||
  fail "menu missing the Charts row despite includesCharts: $LAYOUT"
printf '%s' "$LAYOUT" | grep -q "Settings" || fail "menu missing the Settings row"
printf '%s' "$LAYOUT" | grep -q "Quit" || fail "menu missing the Quit row"
echo "tray: menu OK (dashboard, charts, settings, quit)"

# In-place mutation. A Linux tray menu cannot be replaced once it is set, only
# edited, so this proves rows are rewritten rather than rebuilt. The status row
# starts as the initial placeholder and becomes whatever the first poll found.
sleep 2
T1=$(layout | grep -oE "label': <'[^']+'>" | head -1 || true)
sleep 4
T2=$(layout | grep -oE "label': <'[^']+'>" | head -1 || true)
echo "menu first row: $T1 / $T2"
[ -n "$T1" ] || fail "menu had no rows"

# Widget labels are rewritten too: they start as the bare provider name and
# become the widget title once a poll has run. libayatana carries the text next
# to the icon in XAyatanaLabel, not in Title.
W1=$(props "$BUS" "$WIDGET_PATH" XAyatanaLabel || true)
sleep 4
W2=$(props "$BUS" "$WIDGET_PATH" XAyatanaLabel || true)
echo "widget label: $W1 -> $W2"
[ -n "$W1" ] || fail "widget has no label"
case "$W1" in
*"Claude"*) ;;
*) fail "unexpected initial widget label: $W1" ;;
esac

# Click: the quit item dispatches to Rust and exits the process.
# The GVariant text form is not a Python literal (uint32/@av/<false>), so pull
# the id straight out of the item tuple that carries the label. The Quit row
# carries an "enabled" key before it, hence the two patterns.
QUIT_ID=$(layout | grep -oE "\(([0-9]+), \{(('enabled': <[a-z]+>, )?'label': <'Quit')" | head -1 | sed -E 's/^\(([0-9]+).*/\1/' || true)
echo "quit item id=$QUIT_ID"
gdbus call --session --dest "$BUS" --object-path "$MAIN_PATH/Menu" \
  --method com.canonical.dbusmenu.Event -- "$QUIT_ID" clicked '<uint32 0>' 0 >/dev/null
sleep 3
kill -0 "$APP_PID" 2>/dev/null && fail "menu click not dispatched"
echo "tray: click dispatched"

kill "$WATCHER" 2>/dev/null || true
echo "SPIKE OK"
