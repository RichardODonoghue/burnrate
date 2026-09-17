#ifndef BURNRATE_TRAY_H
#define BURNRATE_TRAY_H

/// One tray menu row.
/// `action_id >= 0` is clickable and reported back via `br_tray_action_cb`;
/// `action_id == -1` is a disabled label row; `action_id == -2` is a separator.
typedef struct {
    const char *label;
    int action_id;
    int enabled;
} br_tray_item;

/// Invoked (on a D-Bus thread) when the user clicks a row; `action_id` matches
/// the value passed in `br_tray_item`.
typedef void (*br_tray_action_cb)(int action_id, void *ctx);

/// Publishes a StatusNotifierItem + `com.canonical.dbusmenu` menu on the
/// session bus and registers with the StatusNotifierWatcher.
///
/// Returns 1 on success, 0 when there is no session bus or no watcher — the
/// caller keeps running headless in that case.
int br_tray_start(const char *icon_name, const char *title,
                  br_tray_action_cb callback, void *ctx);

/// Replaces the tray menu rows. Safe to call repeatedly.
void br_tray_set_items(const br_tray_item *items, int count);

/// Releases the tray's D-Bus objects.
void br_tray_stop(void);

#endif
