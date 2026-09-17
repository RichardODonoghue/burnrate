#ifndef BURNRATE_TRAY_H
#define BURNRATE_TRAY_H

/// One tray menu row.
/// `action_id >= 0` is clickable and reported back via the callback for that
/// tray; `action_id == -1` is a disabled label row; `action_id == -2` is a
/// separator.
typedef struct {
    const char *label;
    int action_id;
    int enabled;
} br_tray_item;

/// Invoked (on a D-Bus thread) when the user clicks a row. `tray` identifies
/// the item (`br_tray_add` return value); `action_id` matches `br_tray_item`.
typedef void (*br_tray_action_cb)(int tray, int action_id, void *ctx);

/// Publishes a StatusNotifierItem + `com.canonical.dbusmenu` menu on its own
/// session-bus connection and registers with the StatusNotifierWatcher.
///
/// Returns a tray index (>= 0) on success, or -1 when there is no session bus.
/// Multiple trays (main item + per-provider widgets) are supported.
int br_tray_add(const char *icon_name, const char *title,
                br_tray_action_cb callback, void *ctx);

/// Replaces the menu rows of `tray`. Safe to call repeatedly.
void br_tray_set_items(int tray, const br_tray_item *items, int count);

/// Removes a tray and frees its D-Bus objects. Its index may be reused by a
/// later `br_tray_add`.
void br_tray_remove(int tray);

/// Updates a tray's title (used as the tooltip).
void br_tray_set_title(int tray, const char *title);

/// Releases every tray's D-Bus objects.
void br_tray_stop_all(void);

#endif
