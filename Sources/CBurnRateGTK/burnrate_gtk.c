#include "burnrate_gtk.h"
#include <gtk/gtk.h>
#include <string.h>

/* ---- view model ---------------------------------------------------------- */

br_view *br_view_new(void) {
    return g_new0(br_view, 1);
}

char *br_dup(const char *s) {
    return g_strdup(s ? s : "");
}

/// Frees everything a view owns, but not the view itself — so it can be reused
/// for a static instance as well as a heap one.
static void view_clear(br_view *view) {
    if (!view) {
        return;
    }
    for (int i = 0; i < view->card_count; i++) {
        g_free(view->cards[i].label);
        g_free(view->cards[i].value);
        g_free(view->cards[i].detail);
    }
    g_free(view->cards);
    for (int i = 0; i < view->series_count; i++) {
        g_free(view->series[i].name);
        g_free(view->series[i].pts);
    }
    g_free(view->series);
    for (int i = 0; i < view->bar_count; i++) {
        g_free(view->bars[i].label);
    }
    g_free(view->bars);
    g_free(view->segments);
    for (int i = 0; i < view->provider_count; i++) {
        g_free(view->providers[i]);
    }
    g_free(view->providers);
    for (int i = 0; i < view->trend_label_count; i++) {
        g_free(view->trend_labels[i]);
    }
    g_free(view->trend_labels);
    g_free(view->status);
    g_free(view->version);
    g_free(view->diagnostics);
    memset(view, 0, sizeof(*view));
}

void br_view_free(br_view *view) {
    if (!view) {
        return;
    }
    view_clear(view);
    g_free(view);
}

/* ---- window state -------------------------------------------------------- */

static GtkApplication *g_app = NULL;
static GtkWidget *g_window = NULL;
static br_void_cb g_refresh = NULL;
static br_query_cb g_on_query = NULL;
static void *g_ctx = NULL;

/* The selection the GTK layer owns; the host answers for exactly this. */
static br_query g_query = {BR_PANE_USAGE, BR_RANGE_7D, BR_METRIC_TOKENS, 0, 0};
/* The most recently presented view. The draw functions read it directly. */
static br_view g_view;
/* A view handed over from another thread but not yet rendered. */
static br_view *g_pending = NULL;
static GMutex g_pending_lock;

static GtkWidget *g_stack = NULL;
static GtkWidget *g_list = NULL;
static GtkWidget *g_range_dd = NULL;
static GtkWidget *g_metric_dd = NULL;
static GtkWidget *g_provider_dd = NULL;
static GtkWidget *g_label_dd = NULL;
static GtkWidget *g_cards = NULL;
static GtkWidget *g_legend = NULL;
static GtkWidget *g_trend = NULL;
static GtkWidget *g_daily = NULL;
static GtkWidget *g_bars = NULL;
/* The frames are hidden rather than the areas, so an empty chart leaves no
 * stray titled box behind. */
static GtkWidget *g_trend_frame = NULL;
static GtkWidget *g_daily_frame = NULL;
static GtkWidget *g_bars_frame = NULL;
static GtkWidget *g_status = NULL;
static GtkWidget *g_diag = NULL;

static const char *const PANE_NAMES[BR_PANE_COUNT] = {
    "usage", "notifications", "widgets", "about"
};
static const char *const PANE_TITLES[BR_PANE_COUNT] = {
    "Usage", "Notifications", "Menu Bar Widgets", "About"
};

static void notify_query(void) {
    if (g_on_query) {
        g_on_query(g_query, g_ctx);
    }
}

/* ---- small text helpers -------------------------------------------------- */

static GtkWidget *scaled_label(const char *text, double scale, gboolean bold,
                               double r, double g, double b) {
    GtkWidget *label = gtk_label_new(text ? text : "");
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    PangoAttrList *attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_scale_new(scale));
    if (bold) {
        pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
    }
    if (r >= 0) {
        /* Multiply first, then cast — casting the 0…1 value to guint16 before
         * scaling truncates every channel to 0, i.e. black. */
        pango_attr_list_insert(attrs, pango_attr_foreground_new(
            (guint16)(CLAMP(r, 0, 1) * 65535), (guint16)(CLAMP(g, 0, 1) * 65535),
            (guint16)(CLAMP(b, 0, 1) * 65535)));
    }
    gtk_label_set_attributes(GTK_LABEL(label), attrs);
    pango_attr_list_unref(attrs);
    return label;
}

static void on_refresh_clicked(GtkButton *button, gpointer data) {
    (void)button;
    (void)data;
    if (g_refresh) {
        g_refresh(g_ctx);
    }
}

static void on_quit_clicked(GtkButton *button, gpointer data) {
    (void)button;
    (void)data;
    br_ui_quit();
}

/* ---- cards --------------------------------------------------------------- */

static GtkWidget *make_card(const br_card *card) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_margin_top(box, 8);
    gtk_widget_set_margin_bottom(box, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);

    gtk_box_append(GTK_BOX(box), scaled_label(card->value, 1.6, TRUE, -1, -1, -1));
    gtk_box_append(GTK_BOX(box), scaled_label(card->label, 0.85, FALSE, -1, -1, -1));
    if (card->detail && *card->detail) {
        gtk_box_append(GTK_BOX(box), scaled_label(card->detail, 0.8, FALSE, -1, -1, -1));
    }
    return box;
}

static void clear_box(GtkWidget *box) {
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(box), child);
        child = next;
    }
}

static void rebuild_cards(void) {
    if (!g_cards) {
        return;
    }
    clear_box(g_cards);
    for (int i = 0; i < g_view.card_count; i++) {
        GtkWidget *frame = gtk_frame_new(NULL);
        gtk_frame_set_child(GTK_FRAME(frame), make_card(&g_view.cards[i]));
        gtk_widget_set_hexpand(frame, TRUE);
        gtk_box_append(GTK_BOX(g_cards), frame);
    }
    gtk_widget_set_visible(g_cards, g_view.card_count > 0);
}

static void rebuild_legend(void) {
    if (!g_legend) {
        return;
    }
    clear_box(g_legend);
    for (int i = 0; i < g_view.series_count; i++) {
        const br_series *s = &g_view.series[i];
        if (!s->name || !*s->name) {
            continue;
        }
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 5);
        /* A coloured square via Pango, so it tracks the theme's font instead of
         * needing a one-off Cairo surface per series. Scoped series are dimmed
         * to match the dashed line in the chart. */
        double dim = s->dashed ? 0.65 : 1.0;
        gtk_box_append(GTK_BOX(row), scaled_label("■", 1.0, FALSE,
                                                  s->rgb[0] * dim, s->rgb[1] * dim, s->rgb[2] * dim));
        gtk_box_append(GTK_BOX(row), scaled_label(s->name, s->dashed ? 0.85 : 1.0, FALSE, -1, -1, -1));
        gtk_box_append(GTK_BOX(g_legend), row);
    }
    gtk_widget_set_visible(g_legend, g_view.series_count > 0);
}

/* ---- pickers ------------------------------------------------------------- */

static void set_dropdown(GtkWidget *dd, char **items, int count, int selected) {
    if (!dd || count <= 0) {
        return;
    }
    GtkStringList *list = gtk_string_list_new(NULL);
    for (int i = 0; i < count; i++) {
        gtk_string_list_append(list, items[i] ? items[i] : "");
    }
    /* Replacing the model resets the selection, so restore it after. */
    gtk_drop_down_set_model(GTK_DROP_DOWN(dd), G_LIST_MODEL(list));
    g_object_unref(list);
    if (selected >= 0 && selected < count) {
        gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), (guint)selected);
    }
}

#define DROPDOWN_HANDLER(name, field)                                          \
    static void name(GObject *obj, GParamSpec *pspec, gpointer data) {         \
        (void)pspec; (void)data;                                               \
        g_query.field = (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(obj));  \
        notify_query();                                                        \
    }

DROPDOWN_HANDLER(on_range_changed, range)
DROPDOWN_HANDLER(on_metric_changed, metric)
DROPDOWN_HANDLER(on_provider_changed, provider)
DROPDOWN_HANDLER(on_label_changed, trend_label)

static void on_row_selected(GObject *obj, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    (void)data;
    GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(obj));
    if (!row) {
        return;
    }
    g_query.pane = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(row), "pane"));
    gtk_stack_set_visible_child_name(GTK_STACK(g_stack), PANE_NAMES[g_query.pane]);
    notify_query();
}

/* ---- chart drawing ------------------------------------------------------- */

static void set_source_rgb(cairo_t *cr, double r, double g, double b, double alpha) {
    cairo_set_source_rgba(cr, r, g, b, alpha);
}

#define PAD_L 46.0
#define PAD_R 12.0
#define PAD_T 10.0
#define PAD_B 20.0

/* Horizontal gridlines with 0/25/50/75/100 % labels, shared by both column
 * charts so they read as one system. */
static void draw_percent_grid(cairo_t *cr, double w, double h) {
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 11);
    for (int g = 0; g <= 100; g += 25) {
        double y = PAD_T + h * (1.0 - g / 100.0);
        cairo_set_source_rgb(cr, 0.85, 0.85, 0.85);
        cairo_set_line_width(cr, 1.0);
        cairo_move_to(cr, PAD_L, y);
        cairo_line_to(cr, PAD_L + w, y);
        cairo_stroke(cr);
        char label[8];
        g_snprintf(label, sizeof(label), "%d%%", g);
        cairo_set_source_rgb(cr, 0.45, 0.45, 0.45);
        cairo_move_to(cr, 4, y + 4);
        cairo_show_text(cr, label);
    }
}

static void draw_trend(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    (void)data;
    double w = width - PAD_L - PAD_R, h = height - PAD_T - PAD_B;
    if (w <= 0 || h <= 0) {
        return;
    }
    draw_percent_grid(cr, w, h);
    for (int i = 0; i < g_view.series_count; i++) {
        const br_series *s = &g_view.series[i];
        if (s->count <= 0) {
            continue;
        }
        cairo_set_line_width(cr, s->dashed ? 1.5 : 2.0);
        if (s->dashed) {
            const double dashes[] = {5.0, 4.0};
            cairo_set_dash(cr, dashes, 2, 0);
        } else {
            cairo_set_dash(cr, NULL, 0, 0);
        }
        set_source_rgb(cr, s->rgb[0], s->rgb[1], s->rgb[2], s->dashed ? 0.7 : 0.95);
        for (int j = 0; j < s->count; j++) {
            double x = PAD_L + w * CLAMP(s->pts[j].x, 0.0, 1.0);
            double y = PAD_T + h * (1.0 - CLAMP(s->pts[j].y, 0.0, 100.0) / 100.0);
            if (j == 0) {
                cairo_move_to(cr, x, y);
            } else {
                cairo_line_to(cr, x, y);
            }
        }
        cairo_stroke(cr);
    }
    cairo_set_dash(cr, NULL, 0, 0);
}

static void draw_daily(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    (void)data;
    if (g_view.day_count <= 0) {
        return;
    }
    double w = width - PAD_L - PAD_R, h = height - PAD_T - PAD_B;
    if (w <= 0 || h <= 0) {
        return;
    }
    /* One pass for the peak, so the stack is scaled to the data rather than a
     * fixed maximum. */
    double *tops = g_new0(double, g_view.day_count);
    double peak = 0;
    for (int i = 0; i < g_view.segment_count; i++) {
        int d = g_view.segments[i].day;
        if (d < 0 || d >= g_view.day_count) {
            continue;
        }
        tops[d] += g_view.segments[i].value;
        if (tops[d] > peak) {
            peak = tops[d];
        }
    }
    if (peak > 0) {
        draw_percent_grid(cr, w, h);
        double col = w / g_view.day_count;
        for (int d = 0; d < g_view.day_count; d++) {
            double base = PAD_T + h;
            for (int i = 0; i < g_view.segment_count; i++) {
                if (g_view.segments[i].day != d) {
                    continue;
                }
                double seg_h = h * (g_view.segments[i].value / peak);
                base -= seg_h;
                set_source_rgb(cr, g_view.segments[i].rgb[0], g_view.segments[i].rgb[1],
                               g_view.segments[i].rgb[2], 0.9);
                cairo_rectangle(cr, PAD_L + d * col + 1, base, MAX(col - 2, 1), seg_h);
                cairo_fill(cr);
            }
        }
    }
    g_free(tops);
}

static void draw_bars(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    (void)data;
    if (g_view.bar_count <= 0) {
        return;
    }
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 11);
    const double label_w = 150, value_w = 60, pad = 10;
    double bar_max = width - label_w - value_w - pad * 2;
    if (bar_max <= 0) {
        return;
    }
    double row_h = (double)height / g_view.bar_count;
    for (int i = 0; i < g_view.bar_count; i++) {
        const br_bar *b = &g_view.bars[i];
        double cy = i * row_h;
        double bar_h = MIN(row_h - 6, 16);
        cairo_set_source_rgb(cr, 0.25, 0.25, 0.25);
        cairo_move_to(cr, pad, cy + row_h / 2 + 4);
        cairo_show_text(cr, b->label ? b->label : "");
        set_source_rgb(cr, b->rgb[0], b->rgb[1], b->rgb[2], 0.9);
        cairo_rectangle(cr, pad + label_w, cy + (row_h - bar_h) / 2,
                        bar_max * CLAMP(b->value, 0.0, 1.0), bar_h);
        cairo_fill(cr);
    }
}

/* ---- panes --------------------------------------------------------------- */

static GtkWidget *build_usage_pane(void) {
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_top(outer, 10);
    gtk_widget_set_margin_bottom(outer, 10);
    gtk_widget_set_margin_start(outer, 12);
    gtk_widget_set_margin_end(outer, 12);

    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    /* GtkDropDown takes NULL-terminated arrays, so no count. */
    static const char *const ranges[] = {"24 hours", "7 days", "30 days", NULL};
    static const char *const metrics[] = {"Tokens", "Cost", NULL};
    static const char *const placeholder[] = {"All", NULL};
    g_range_dd = gtk_drop_down_new_from_strings(ranges);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(g_range_dd), g_query.range);
    g_signal_connect(g_range_dd, "notify::selected", G_CALLBACK(on_range_changed), NULL);
    g_metric_dd = gtk_drop_down_new_from_strings(metrics);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(g_metric_dd), g_query.metric);
    g_signal_connect(g_metric_dd, "notify::selected", G_CALLBACK(on_metric_changed), NULL);
    g_provider_dd = gtk_drop_down_new_from_strings(placeholder);
    g_label_dd = gtk_drop_down_new_from_strings(placeholder);
    struct { const char *caption; GtkWidget **dd; } fields[] = {
        {"Range", &g_range_dd}, {"Metric", &g_metric_dd},
        {"Provider", &g_provider_dd}, {"Window", &g_label_dd},
    };
    for (unsigned i = 0; i < G_N_ELEMENTS(fields); i++) {
        gtk_box_append(GTK_BOX(toolbar), gtk_label_new(fields[i].caption));
        gtk_box_append(GTK_BOX(toolbar), *fields[i].dd);
    }
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(toolbar), spacer);
    GtkWidget *refresh = gtk_button_new_with_label("Refresh");
    g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh_clicked), NULL);
    gtk_box_append(GTK_BOX(toolbar), refresh);
    gtk_box_append(GTK_BOX(outer), toolbar);

    g_signal_connect(g_provider_dd, "notify::selected", G_CALLBACK(on_provider_changed), NULL);
    g_signal_connect(g_label_dd, "notify::selected", G_CALLBACK(on_label_changed), NULL);

    g_status = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(g_status), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(g_status), TRUE);
    gtk_box_append(GTK_BOX(outer), g_status);

    g_diag = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(g_diag), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(g_diag), TRUE);
    gtk_box_append(GTK_BOX(outer), g_diag);

    g_cards = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(outer), g_cards);
    g_legend = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14);
    gtk_box_append(GTK_BOX(outer), g_legend);

    struct { const char *title; GtkWidget **area; GtkWidget **frame;
             GtkDrawingAreaDrawFunc draw; } charts[] = {
        {"Remaining over time", &g_trend, &g_trend_frame, draw_trend},
        {"Daily usage", &g_daily, &g_daily_frame, draw_daily},
        {"Top models", &g_bars, &g_bars_frame, draw_bars},
    };
    for (unsigned i = 0; i < G_N_ELEMENTS(charts); i++) {
        GtkWidget *area = gtk_drawing_area_new();
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), 190);
        gtk_widget_set_hexpand(area, TRUE);
        /* GTK4 has no "draw" signal — the draw func is set directly. */
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), charts[i].draw, NULL, NULL);
        GtkWidget *frame = gtk_frame_new(charts[i].title);
        gtk_frame_set_child(GTK_FRAME(frame), area);
        gtk_box_append(GTK_BOX(outer), frame);
        *charts[i].area = area;
        *charts[i].frame = frame;
    }

    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), outer);
    return scroller;
}

static GtkWidget *placeholder_pane(const char *message) {
    GtkWidget *scroller = gtk_scrolled_window_new();
    GtkWidget *label = gtk_label_new(message);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_widget_set_margin_top(label, 24);
    gtk_widget_set_margin_start(label, 16);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), label);
    return scroller;
}

/* ---- rendering ----------------------------------------------------------- */

static gboolean apply_view(gpointer data) {
    (void)data;
    br_view *view = NULL;
    g_mutex_lock(&g_pending_lock);
    view = g_pending;
    g_pending = NULL;
    g_mutex_unlock(&g_pending_lock);
    if (!view) {
        return G_SOURCE_REMOVE;
    }

    /* `g_view` is static, so clear it in place rather than freeing it. */
    view_clear(&g_view);
    g_view = *view;
    g_free(view);

    rebuild_cards();
    rebuild_legend();
    set_dropdown(g_provider_dd, g_view.providers, g_view.provider_count, g_query.provider);
    set_dropdown(g_label_dd, g_view.trend_labels, g_view.trend_label_count, g_query.trend_label);

    if (g_status) {
        gtk_label_set_text(GTK_LABEL(g_status), g_view.status ? g_view.status : "");
        gtk_widget_set_visible(g_status, g_view.status && *g_view.status);
    }
    if (g_diag) {
        gtk_label_set_text(GTK_LABEL(g_diag), g_view.diagnostics ? g_view.diagnostics : "");
        gtk_widget_set_visible(g_diag, g_view.diagnostics && *g_view.diagnostics);
    }
    if (g_legend) gtk_widget_set_visible(g_legend, g_view.series_count > 0);
    if (g_trend) {
        gtk_widget_set_visible(g_trend_frame, g_view.series_count > 0);
        gtk_widget_queue_draw(g_trend);
    }
    if (g_daily) {
        gtk_widget_set_visible(g_daily_frame, g_view.segment_count > 0);
        gtk_widget_queue_draw(g_daily);
    }
    if (g_bars) {
        gtk_widget_set_visible(g_bars_frame, g_view.bar_count > 0);
        gtk_widget_queue_draw(g_bars);
    }
    return G_SOURCE_REMOVE;
}

static gboolean on_timeout(gpointer data) {
    (void)data;
    if (g_refresh) {
        g_refresh(g_ctx);
    }
    return G_SOURCE_CONTINUE;
}

static void on_activate(GtkApplication *app, gpointer data) {
    (void)data;
    g_mutex_init(&g_pending_lock);

    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "BurnRate");
    gtk_window_set_default_size(GTK_WINDOW(window), 1000, 700);
    g_window = window;

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *header = gtk_header_bar_new();
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), gtk_label_new("BurnRate"));
    gtk_header_bar_set_show_title_buttons(GTK_HEADER_BAR(header), TRUE);
    gtk_box_append(GTK_BOX(root), header);

    g_stack = gtk_stack_new();
    gtk_stack_add_named(GTK_STACK(g_stack), build_usage_pane(), PANE_NAMES[BR_PANE_USAGE]);
    gtk_stack_add_named(GTK_STACK(g_stack),
                        placeholder_pane("Notification settings arrive in a follow-up."),
                        PANE_NAMES[BR_PANE_NOTIFICATIONS]);
    gtk_stack_add_named(GTK_STACK(g_stack),
                        placeholder_pane("Widget settings arrive in a follow-up."),
                        PANE_NAMES[BR_PANE_WIDGETS]);
    gtk_stack_add_named(GTK_STACK(g_stack), placeholder_pane("About arrives in a follow-up."),
                        PANE_NAMES[BR_PANE_ABOUT]);
    gtk_stack_set_visible_child_name(GTK_STACK(g_stack), PANE_NAMES[BR_PANE_USAGE]);

    g_list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(g_list), GTK_SELECTION_SINGLE);
    for (int i = 0; i < BR_PANE_COUNT; i++) {
        GtkWidget *row = gtk_list_box_row_new();
        GtkWidget *label = gtk_label_new(PANE_TITLES[i]);
        gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
        gtk_widget_set_margin_top(label, 8);
        gtk_widget_set_margin_bottom(label, 8);
        gtk_widget_set_margin_start(label, 12);
        gtk_widget_set_margin_end(label, 12);
        gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), label);
        g_object_set_data(G_OBJECT(row), "pane", GINT_TO_POINTER(i));
        gtk_list_box_append(GTK_LIST_BOX(g_list), row);
    }
    g_signal_connect(g_list, "row-selected", G_CALLBACK(on_row_selected), NULL);
    gtk_list_box_select_row(GTK_LIST_BOX(g_list),
                            gtk_list_box_get_row_at_index(GTK_LIST_BOX(g_list), 0));

    GtkWidget *paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_paned_set_start_child(GTK_PANED(paned), g_list);
    gtk_paned_set_resize_start_child(GTK_PANED(paned), FALSE);
    gtk_paned_set_end_child(GTK_PANED(paned), g_stack);
    gtk_paned_set_position(GTK_PANED(paned), 190);
    gtk_widget_set_vexpand(paned, TRUE);
    gtk_box_append(GTK_BOX(root), paned);
    gtk_window_set_child(GTK_WINDOW(window), root);
    gtk_window_present(GTK_WINDOW(window));

    /* Ask for data twice over: once for the default selection, so the window
     * has content immediately, and once for the first poll. */
    notify_query();
    if (g_refresh) {
        g_refresh(g_ctx);
    }
    g_timeout_add_seconds(300, on_timeout, NULL);
}

void br_ui_run(const char *title, br_query_cb on_query, br_void_cb on_refresh, void *ctx) {
    (void)title;
    g_on_query = on_query;
    g_refresh = on_refresh;
    g_ctx = ctx;
    g_app = gtk_application_new("com.burnrate.desktop", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(g_app, "activate", G_CALLBACK(on_activate), NULL);
    g_application_run(G_APPLICATION(g_app), 0, NULL);
    g_object_unref(g_app);
}

void br_ui_present(br_view *view) {
    if (!view) {
        return;
    }
    g_mutex_lock(&g_pending_lock);
    if (g_pending) {
        br_view_free(g_pending);
    }
    g_pending = view;
    g_mutex_unlock(&g_pending_lock);
    g_idle_add(apply_view, NULL);
}

void br_ui_show_pane(int pane) {
    if (pane < 0 || pane >= BR_PANE_COUNT || !g_stack) {
        return;
    }
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(GTK_LIST_BOX(g_list), pane);
    if (row) {
        gtk_list_box_select_row(GTK_LIST_BOX(g_list), row);
    }
    if (g_window) {
        gtk_window_present(GTK_WINDOW(g_window));
    }
}

void br_ui_quit(void) {
    if (g_app) {
        g_application_quit(G_APPLICATION(g_app));
    }
}

/* ---- settings window ----------------------------------------------------- */

static GtkWidget *g_settings_window = NULL;
static GtkWidget *g_settings_box = NULL;
static br_checkbox_cb g_settings_cb = NULL;
static br_spin_cb g_spin_cb = NULL;
static void *g_settings_ctx = NULL;

static void on_checkbox_toggled(GtkCheckButton *button, gpointer data) {
    int id = GPOINTER_TO_INT(data);
    if (g_settings_cb) {
        g_settings_cb(id, gtk_check_button_get_active(button), g_settings_ctx);
    }
}

static void on_spin_changed(GtkSpinButton *spin, gpointer data) {
    int id = GPOINTER_TO_INT(data);
    if (g_spin_cb) {
        g_spin_cb(id, gtk_spin_button_get_value(spin), g_settings_ctx);
    }
}

void br_settings_show(const char *title,
                      const br_checkbox *checks, int check_count,
                      const br_spin *spins, int spin_count,
                      br_checkbox_cb checkbox_callback, br_spin_cb spin_callback,
                      void *ctx) {
    g_settings_cb = checkbox_callback;
    g_spin_cb = spin_callback;
    g_settings_ctx = ctx;

    if (!g_settings_window) {
        g_settings_window = gtk_window_new();
        gtk_window_set_title(GTK_WINDOW(g_settings_window), title ? title : "Settings");
        gtk_window_set_default_size(GTK_WINDOW(g_settings_window), 380, 420);
        g_settings_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_widget_set_margin_top(g_settings_box, 14);
        gtk_widget_set_margin_bottom(g_settings_box, 14);
        gtk_widget_set_margin_start(g_settings_box, 14);
        gtk_widget_set_margin_end(g_settings_box, 14);
        gtk_window_set_child(GTK_WINDOW(g_settings_window), g_settings_box);
    } else {
        clear_box(g_settings_box);
    }

    for (int i = 0; i < check_count; i++) {
        GtkWidget *check = gtk_check_button_new_with_label(checks[i].label ? checks[i].label : "");
        gtk_check_button_set_active(GTK_CHECK_BUTTON(check), checks[i].checked ? TRUE : FALSE);
        g_signal_connect(check, "toggled", G_CALLBACK(on_checkbox_toggled),
                         GINT_TO_POINTER(checks[i].id));
        gtk_box_append(GTK_BOX(g_settings_box), check);
    }

    for (int i = 0; i < spin_count; i++) {
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *label = gtk_label_new(spins[i].label ? spins[i].label : "");
        gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
        gtk_widget_set_hexpand(label, TRUE);
        gtk_box_append(GTK_BOX(row), label);
        GtkWidget *spin = gtk_spin_button_new_with_range(spins[i].minimum, spins[i].maximum, 1);
        gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), spins[i].value);
        g_signal_connect(spin, "value-changed", G_CALLBACK(on_spin_changed),
                         GINT_TO_POINTER(spins[i].id));
        gtk_box_append(GTK_BOX(row), spin);
        gtk_box_append(GTK_BOX(g_settings_box), row);
    }

    gtk_window_present(GTK_WINDOW(g_settings_window));
}
