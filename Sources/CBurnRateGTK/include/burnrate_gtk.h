#ifndef BURNRATE_GTK_H
#define BURNRATE_GTK_H

#include <stddef.h>

/// Callback the host registers; invoked on the GTK main thread when the UI
/// wants fresh data (the Refresh button, or the 5-minute timer).
typedef void (*br_void_cb)(void *ctx);

/* ---- Dashboard panes ----------------------------------------------------- */

enum {
    BR_PANE_USAGE = 0,
    BR_PANE_NOTIFICATIONS = 1,
    BR_PANE_WIDGETS = 2,
    BR_PANE_ABOUT = 3,
    BR_PANE_COUNT = 4
};

/// Mirrors `ChartRange` in BurnRateCore (24h / 7d / 30d).
enum { BR_RANGE_24H = 0, BR_RANGE_7D = 1, BR_RANGE_30D = 2 };

/// Mirrors the macOS `Metric` enum (Tokens / Cost).
enum { BR_METRIC_TOKENS = 0, BR_METRIC_COST = 1 };

/* ---- The query seam ------------------------------------------------------
 *
 * The GTK layer owns the user's selection (br_query); the host answers with a
 * br_view for exactly that query. Previously the host pushed one pre-rendered
 * text blob and one hard-coded set of chart points, so a control in the window
 * had no way to say "the user picked 30d + Cost + Claude" — the interface had
 * no parameters at all. Inverting it is what makes the window interactive.
 */

typedef struct {
    int pane;         /* BR_PANE_* */
    int range;        /* BR_RANGE_* */
    int metric;       /* BR_METRIC_* */
    int provider;     /* index into br_view.providers, -1 = all providers */
    int trend_label;  /* index into br_view.trend_labels, -1 = first available */
} br_query;

/// Invoked on the GTK main thread whenever the selection changes, including
/// once at startup. The host answers asynchronously with `br_ui_present`.
typedef void (*br_query_cb)(br_query query, void *ctx);

/* ---- The view model (host fills, GTK frees) ------------------------------ */

typedef struct {
    char *label;   /* e.g. "Weekly" */
    char *value;   /* e.g. "94%"   */
    char *detail;  /* e.g. "resets in 2d" */
} br_card;

typedef struct {
    double x; /* 0…1 across the range */
    double y; /* 0…100 percent remaining */
} br_xy;

/// One line on the remaining-over-time chart. A provider can contribute several
/// (Claude Weekly + a model-scoped "Fable" weekly); `dashed` marks the scoped
/// ones so they read as secondary.
typedef struct {
    char *name;
    double rgb[3];
    int dashed;
    int count;
    br_xy *pts;
} br_series;

/// One bar in the model-ranking chart. `value` is 0…1 of the largest entry.
typedef struct {
    char *label;
    double value;
    double rgb[3];
} br_bar;

/// One segment of a stacked daily-usage column; `day` is the column index.
typedef struct {
    int day;
    double value;
    double rgb[3];
} br_seg;

typedef struct {
    br_card *cards;
    int card_count;
    br_series *series;
    int series_count;
    br_bar *bars;
    int bar_count;
    br_seg *segments;
    int segment_count;
    int day_count;
    /// Provider names for the filter dropdown. Index 0 is "All"; the host must
    /// keep the list stable across refreshes so a selection survives a poll.
    char **providers;
    int provider_count;
    /// Window labels (Rolling/Weekly/…) available for the trend chart.
    char **trend_labels;
    int trend_label_count;
    /// When set, the charts are replaced by this message (loading/empty state).
    char *status;
    /// Shown in the About pane.
    char *version;
    /// Newline-separated "not working" lines; shown under the charts.
    char *diagnostics;
} br_view;

/// Allocates a zeroed view for the host to fill.
br_view *br_view_new(void);
/// Frees a view and everything it owns.
void br_view_free(br_view *view);
/// strdup for C-owned strings in a view (GLib's allocator).
char *br_dup(const char *s);

/* ---- Application --------------------------------------------------------- */

/// Runs the GTK application (blocking), then shows the window.
void br_ui_run(const char *title, br_query_cb on_query, br_void_cb on_refresh, void *ctx);

/// Thread-safe: takes ownership of `view` and renders it. Pass NULL to render
/// nothing (e.g. while a fetch is in flight).
void br_ui_present(br_view *view);

/// Brings the window forward on the given pane (menu actions).
void br_ui_show_pane(int pane);

/// Requests the GTK application to quit.
void br_ui_quit(void);

/* ---- Settings window ----------------------------------------------------- */

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

#endif
