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

#endif
