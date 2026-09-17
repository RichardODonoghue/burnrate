#ifndef BURNRATE_WIN32_H
#define BURNRATE_WIN32_H

/// Callback the host registers; invoked on the UI thread when the app wants
/// fresh data (Refresh button or the 5-minute timer).
typedef void (*br_void_cb)(void *ctx);

/// Creates the window and runs the Win32 message loop (blocking). `body` is the
/// initial text; the host calls `br_win_post` with updates.
int br_win_run(const char *title, const char *body, br_void_cb on_refresh, void *ctx);

/// Thread-safe: posts a window-text update to the UI thread.
void br_win_post(const char *body);

/// Requests the window/message loop to close.
void br_win_quit(void);

/// Shows a tray balloon notification.
void br_notify(const char *title, const char *body);

/// Opens a URL in the default browser.
void br_open_url(const char *url);

/* ---- tray --------------------------------------------------------------- */

/// One tray menu row: `action_id >= 0` clickable, -1 disabled label, -2 separator.
typedef struct {
    const char *label;
    int action_id;
    int enabled;
} br_tray_item;

typedef void (*br_tray_action_cb)(int tray, int action_id, void *ctx);

/// Adds a notification-area icon + menu. Returns a tray index, or -1 on failure.
int br_tray_add(const char *title, br_tray_action_cb callback, void *ctx);
void br_tray_set_items(int tray, const br_tray_item *items, int count);
void br_tray_set_title(int tray, const char *title);
void br_tray_remove(int tray);
void br_tray_stop_all(void);

/* ---- charts (GDI) ------------------------------------------------------- */

typedef struct { int series; double x; double y; } br_trend_point;
typedef struct { int day; double value; double red, green, blue; } br_bar_segment;

void br_chart_set_trend(const br_trend_point *points, int point_count,
                        const double *series_rgb, int series_count);
void br_chart_set_bars(const double *values, const double *bar_rgb, int count,
                       const char *labels);
void br_chart_set_daily(const br_bar_segment *segments, int count, int day_count);

#endif
