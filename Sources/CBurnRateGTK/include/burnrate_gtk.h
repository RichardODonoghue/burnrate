#ifndef BURNRATE_GTK_H
#define BURNRATE_GTK_H

/// Callback the host registers; invoked on the GTK main thread when the UI
/// wants fresh data (the Refresh button, or the 5-minute timer).
typedef void (*br_void_cb)(void *ctx);

/// Runs the GTK application (blocking). `body` is the initial window text.
/// `on_refresh` is called immediately-invoked style by a timer/button; the
/// host fetches data and calls `br_ui_post` with the new text.
void br_ui_run(const char *title, const char *body, br_void_cb on_refresh, void *ctx);

/// Thread-safe: schedules a window-text update on the GTK main thread.
void br_ui_post(const char *body);

/// Requests the GTK application to quit.
void br_ui_quit(void);

/// One checkbox row for the settings window.
typedef struct {
    const char *label;
    int id;
    int checked;
} br_checkbox;

/// Invoked on the GTK main thread when a checkbox is toggled.
typedef void (*br_checkbox_cb)(int id, int checked, void *ctx);

/// Shows (or rebuilds) the settings window with the given checkboxes.
void br_settings_show(const char *title, const br_checkbox *items, int count,
                      br_checkbox_cb callback, void *ctx);

#endif
