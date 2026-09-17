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

/// One numeric row for the settings window (e.g. a milestone step).
typedef struct {
    const char *label;
    int id;
    double value;
    double minimum;
    double maximum;
} br_spin;

/// Invoked on the GTK main thread when a checkbox is toggled.
typedef void (*br_checkbox_cb)(int id, int checked, void *ctx);

/// Invoked on the GTK main thread when a numeric row changes.
typedef void (*br_spin_cb)(int id, double value, void *ctx);

/// Shows (or rebuilds) the settings window with the given rows.
void br_settings_show(const char *title,
                      const br_checkbox *checks, int check_count,
                      const br_spin *spins, int spin_count,
                      br_checkbox_cb checkbox_callback, br_spin_cb spin_callback,
                      void *ctx);

/// One point on the trend chart: `series` selects the colour, `x` is 0…1
/// (time), `y` is 0…100 (percent remaining).
typedef struct {
    int series;
    double x;
    double y;
} br_trend_point;

/// Shows (or raises) the charts window.
void br_chart_show(const char *title);

/// Replaces the trend chart. `series_rgb` holds `series_count` × 3 components.
void br_chart_set_trend(const br_trend_point *points, int point_count,
                        const double *series_rgb, int series_count);

/// Replaces the ranking bars. Values are 0…1; labels are newline-separated.
void br_chart_set_bars(const double *values, const double *bar_rgb, int bar_count,
                       const char *labels);

#endif
