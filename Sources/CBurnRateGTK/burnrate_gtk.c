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

void *br_alloc(size_t bytes) {
    return g_malloc0(bytes);
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
    for (int i = 0; i < view->row_count; i++) {
        for (int c = 0; c < view->rows[i].cell_count; c++) {
            g_free(view->rows[i].cells[c]);
        }
    }
    g_free(view->rows);
    for (int i = 0; i < view->provider_count; i++) {
        g_free(view->providers[i]);
    }
    g_free(view->providers);
    for (int i = 0; i < view->trend_label_count; i++) {
        g_free(view->trend_labels[i]);
    }
    g_free(view->trend_labels);
    for (int i = 0; i < view->x_label_count; i++) {
        g_free(view->x_labels[i]);
    }
    g_free(view->x_labels);
    for (int i = 0; i < view->day_label_count; i++) {
        g_free(view->day_labels[i]);
    }
    g_free(view->day_labels);
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
static GtkWidget *g_range_group = NULL;
static GtkWidget *g_metric_group = NULL;
static GtkWidget *g_label_group = NULL;
static GtkWidget *g_trend_title = NULL;
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
static GtkWidget *g_table_frame = NULL;
static GtkWidget *g_status = NULL;
static GtkWidget *g_diag = NULL;
static GtkWidget *g_empty = NULL;
static GtkWidget *g_table_grid = NULL;

/* Hover state, in pixels. Resolved to a datum at draw time so a tooltip always
 * describes the data currently on screen, and kept out of the query so moving
 * the pointer never triggers a host round-trip. */
static double g_trend_hover_x = -1;
static double g_daily_hover_x = -1;
static double g_bars_hover_y = -1;

/* Set while `apply_view` writes widget state programmatically.
 *
 * Without this the window livelocks: `set_dropdown` replaces the model, which
 * resets the selection and emits `notify::selected`, whose handler raises a
 * query, which schedules another `apply_view` — thousands of redraws a second
 * and no user input ever processed. Declared up here because the segmented
 * controls' handlers consult it too. */
static gboolean g_syncing = FALSE;

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
    /* `gtk_widget_unparent` rather than `gtk_box_remove`: this also empties the
     * breakdown GtkGrid, and gtk_box_remove asserts on a non-Box container. */
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_widget_unparent(child);
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

/* ---- segmented control ---------------------------------------------------
 *
 * GTK4 has no stock segmented control, and the macOS Metric/Range filters are
 * segmented (`.pickerStyle(.segmented)`), so they are built from a row of
 * linked toggle buttons here rather than approximating with a dropdown.
 */

static void add_segment_css(void) {
    static gboolean done = FALSE;
    if (done) {
        return;
    }
    done = TRUE;
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(
        provider,
        ".br-segment > togglebutton { padding: 4px 12px; border-radius: 0;"
        "  border: 1px solid alpha(currentColor, 0.25); margin: 0; }"
        ".br-segment > togglebutton:first-child { border-top-left-radius: 6px;"
        "  border-bottom-left-radius: 6px; }"
        ".br-segment > togglebutton:last-child { border-top-right-radius: 6px;"
        "  border-bottom-right-radius: 6px; }"
        ".br-segment > togglebutton:checked { background-image: none;"
        "  background-color: alpha(currentColor, 0.18); font-weight: bold; }");
    gtk_style_context_add_provider_for_display(
        gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
}

static GtkWidget *build_segment(const char *const *items, int count, int active,
                                GCallback changed) {
    add_segment_css();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(box, "br-segment");
    for (int i = 0; i < count; i++) {
        GtkWidget *button = gtk_toggle_button_new_with_label(items[i]);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button), i == active);
        g_object_set_data(G_OBJECT(button), "segment-index", GINT_TO_POINTER(i));
        g_signal_connect(button, "toggled", changed, box);
        gtk_box_append(GTK_BOX(box), button);
    }
    return box;
}

/* Reads the active index out of a segment group. */
static int segment_selected(GtkWidget *group) {
    GtkWidget *child = gtk_widget_get_first_child(group);
    while (child) {
        if (gtk_widget_get_visible(child)
            && gtk_widget_get_sensitive(child)
            && gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(child))) {
            return GPOINTER_TO_INT(g_object_get_data(G_OBJECT(child), "segment-index"));
        }
        child = gtk_widget_get_next_sibling(child);
    }
    return -1;
}

static void on_segment_toggled(GtkToggleButton *button, gpointer group) {
    if (g_syncing) {
        return;
    }
    int index = segment_selected(GTK_WIDGET(group));
    if (index < 0) {
        return;
    }
    /* A toggle group must never end up with nothing selected. */
    if (!gtk_toggle_button_get_active(button)) {
        gtk_toggle_button_set_active(button, TRUE);
        return;
    }
    /* Enforce single selection: activating one clears the rest. */
    GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(group));
    while (child) {
        if (child != GTK_WIDGET(button)
            && gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(child))) {
            gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(child), FALSE);
        }
        child = gtk_widget_get_next_sibling(child);
    }
    g_object_set_data(G_OBJECT(group), "segment-active", GINT_TO_POINTER(index));
    if (group == g_metric_group) {
        g_query.metric = index;
    } else if (group == g_range_group) {
        g_query.range = index;
    } else if (group == g_label_group) {
        g_query.trend_label = index;
    } else {
        return;
    }
    notify_query();
}

/* ---- pickers ------------------------------------------------------------- */

static void set_dropdown(GtkWidget *dd, char **items, int count, int selected) {
    if (!dd || count <= 0) {
        return;
    }
    /* Leave the model alone when the labels are unchanged, so the user's
     * selection survives a poll and no spurious notify is emitted. */
    GListModel *model = gtk_drop_down_get_model(GTK_DROP_DOWN(dd));
    if (model && g_list_model_get_n_items(model) == (guint)count) {
        gboolean same = TRUE;
        for (int i = 0; i < count && same; i++) {
            GtkStringObject *object = g_list_model_get_item(model, (guint)i);
            same = g_strcmp0(object ? gtk_string_object_get_string(object) : NULL,
                             items[i] ? items[i] : "") == 0;
            if (object) {
                g_object_unref(object);
            }
        }
        if (same) {
            if (selected >= 0 && selected < count
                && (int)gtk_drop_down_get_selected(GTK_DROP_DOWN(dd)) != selected) {
                gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), (guint)selected);
            }
            return;
        }
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
        if (g_syncing) {                                                       \
            return;                                                           \
        }                                                                      \
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

#define PAD_L 46.0
#define PAD_R 12.0
#define PAD_T 10.0
#define PAD_B 20.0

static void set_source_rgb(cairo_t *cr, double r, double g, double b, double alpha) {
    cairo_set_source_rgba(cr, r, g, b, alpha);
}

/* ---- in-canvas tooltip ---------------------------------------------------
 *
 * Drawn into the chart's own surface rather than a popover: a GtkPopover per
 * pointer move would be both slower and harder to keep anchored than a rounded
 * box painted at a clamped offset.
 */

static void draw_tooltip(cairo_t *cr, double surface_w, double anchor_x, double anchor_y,
                         const char *title, const char *detail) {
    if (!title || !*title) {
        return;
    }
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 12);
    cairo_text_extents_t te;
    cairo_text_extents(cr, title, &te);
    double title_w = te.x_advance, title_h = 13;

    double detail_w = 0, detail_h = 0;
    if (detail && *detail) {
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 11);
        cairo_text_extents(cr, detail, &te);
        detail_w = te.x_advance;
        detail_h = 14;
    }
    double box_w = MAX(title_w, detail_w) + 18;
    double box_h = title_h + detail_h + 12;

    /* Prefer above the anchor; flip below when there is no room. */
    double bx = anchor_x - box_w / 2;
    double by = anchor_y - box_h - 10;
    if (by < 4) {
        by = anchor_y + 14;
    }
    /* Clamp to the widget, not to `cairo_image_surface_get_width` — the draw
     * context's target is not guaranteed to be an image surface, and that call
     * returns 0 there, which would push the box clean off the canvas. */
    if (bx < 2) bx = 2;
    if (bx + box_w > surface_w - 2) bx = surface_w - box_w - 2;
    if (by + box_h > PAD_T + 200) by = PAD_T + 200 - box_h;

    cairo_save(cr);
    cairo_set_source_rgba(cr, 0.10, 0.11, 0.13, 0.94);
    cairo_new_path(cr);
    cairo_arc(cr, bx + box_w - 6, by + box_h - 6, 6, 0, 2 * G_PI);
    cairo_rectangle(cr, bx, by, box_w - 6, box_h - 6);
    cairo_fill(cr);

    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD);
    cairo_set_font_size(cr, 12);
    cairo_move_to(cr, bx + 9, by + 6 + title_h - 3);
    cairo_show_text(cr, title);
    if (detail && *detail) {
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
        cairo_set_font_size(cr, 11);
        cairo_set_source_rgba(cr, 1, 1, 1, 0.78);
        cairo_move_to(cr, bx + 9, by + 6 + title_h + detail_h - 4);
        cairo_show_text(cr, detail);
    }
    cairo_restore(cr);
}

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

/* Evenly spaced tick captions along the bottom axis. */
static void draw_x_labels(cairo_t *cr, double w, double h) {
    if (g_view.x_label_count <= 0) {
        return;
    }
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10);
    cairo_set_source_rgb(cr, 0.45, 0.45, 0.45);
    cairo_text_extents_t te;
    for (int i = 0; i < g_view.x_label_count; i++) {
        const char *label = g_view.x_labels[i];
        if (!label || !*label) {
            continue;
        }
        cairo_text_extents(cr, label, &te);
        double frac = (double)i / (double)(g_view.x_label_count - 1);
        double x = PAD_L + w * frac - te.x_advance / 2;
        double y = PAD_T + h + 14;
        if (x < 2) x = 2;
        if (x + te.x_advance > PAD_L + w) x = PAD_L + w - te.x_advance;
        cairo_move_to(cr, x, y);
        cairo_show_text(cr, label);
    }
}

/* Column captions for the daily chart, one per day. */
static void draw_day_labels(cairo_t *cr, double w, double h) {
    if (g_view.day_count <= 0 || g_view.day_label_count <= 0) {
        return;
    }
    double col = w / g_view.day_count;
    cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 9);
    cairo_text_extents_t te;
    for (int d = 0; d < g_view.day_count && d < g_view.day_label_count; d++) {
        const char *label = g_view.day_labels[d];
        if (!label || !*label) {
            continue;
        }
        cairo_text_extents(cr, label, &te);
        /* Too many days to caption legibly: label every other one. */
        if (te.x_advance > col - 2 && (d % 2) == 1) {
            continue;
        }
        cairo_set_source_rgb(cr, 0.45, 0.45, 0.45);
        double x = PAD_L + d * col + (col - te.x_advance) / 2;
        if (x < 2) x = 2;
        cairo_move_to(cr, x, PAD_T + h + 13);
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
    draw_x_labels(cr, w, h);

    /* Tooltip: the datum nearest the pointer, across all series. */
    if (g_trend_hover_x >= PAD_L) {
        int best_series = -1, best_index = -1;
        double best_dx = 1e9;
        for (int i = 0; i < g_view.series_count; i++) {
            const br_series *s = &g_view.series[i];
            for (int j = 0; j < s->count; j++) {
                double px = PAD_L + w * CLAMP(s->pts[j].x, 0.0, 1.0);
                double dx = fabs(px - g_trend_hover_x);
                if (dx < best_dx) {
                    best_dx = dx;
                    best_series = i;
                    best_index = j;
                }
            }
        }
        if (best_series >= 0 && best_dx < 24) {
            const br_series *s = &g_view.series[best_series];
            double px = PAD_L + w * CLAMP(s->pts[best_index].x, 0.0, 1.0);
            double py = PAD_T + h * (1.0 - CLAMP(s->pts[best_index].y, 0.0, 100.0) / 100.0);
            cairo_set_source_rgba(cr, s->rgb[0], s->rgb[1], s->rgb[2], 0.35);
            cairo_set_line_width(cr, 1.0);
            cairo_move_to(cr, px, PAD_T);
            cairo_line_to(cr, px, PAD_T + h);
            cairo_stroke(cr);
            cairo_set_source_rgba(cr, s->rgb[0], s->rgb[1], s->rgb[2], 1.0);
            cairo_arc(cr, px, py, 3.5, 0, 2 * G_PI);
            cairo_fill(cr);
            char title[64], detail[64];
            g_snprintf(title, sizeof(title), "%s · %.0f%%",
                       s->name ? s->name : "", s->pts[best_index].y);
            const char *tick = "";
            int slot = g_view.x_label_count > 1
                           ? (int)(CLAMP(s->pts[best_index].x, 0, 1)
                                    * (g_view.x_label_count - 1) + 0.5)
                           : 0;
            if (slot >= 0 && slot < g_view.x_label_count && g_view.x_labels[slot]) {
                tick = g_view.x_labels[slot];
            }
            g_snprintf(detail, sizeof(detail), "%s", tick);
            draw_tooltip(cr, width, px, py, title, detail);
        }
    }
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
        draw_day_labels(cr, w, h);

        if (g_daily_hover_x >= PAD_L) {
            int day = (int)((g_daily_hover_x - PAD_L) / col);
            if (day >= 0 && day < g_view.day_count) {
                /* Outline the hovered column, then total it for the caption. */
                cairo_set_source_rgba(cr, 0, 0, 0, 0.25);
                cairo_set_line_width(cr, 1.5);
                cairo_rectangle(cr, PAD_L + day * col + 0.5, PAD_T + 0.5,
                                MAX(col - 1, 1), h - 1);
                cairo_stroke(cr);
                double total = 0;
                for (int i = 0; i < g_view.segment_count; i++) {
                    if (g_view.segments[i].day == day) {
                        total += g_view.segments[i].value;
                    }
                }
                char title[64];
                g_snprintf(title, sizeof(title), "%.0f", total);
                const char *label = (day < g_view.day_label_count && g_view.day_labels[day])
                                        ? g_view.day_labels[day] : "";
                draw_tooltip(cr, width, PAD_L + day * col + col / 2, PAD_T + h / 2,
                             title, label);
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
        int hovered = g_bars_hover_y >= cy && g_bars_hover_y < cy + row_h;
        if (hovered) {
            cairo_set_source_rgba(cr, 0, 0, 0, 0.06);
            cairo_rectangle(cr, 0, cy, width, row_h);
            cairo_fill(cr);
        }
        cairo_set_source_rgb(cr, 0.25, 0.25, 0.25);
        cairo_move_to(cr, pad, cy + row_h / 2 + 4);
        cairo_show_text(cr, b->label ? b->label : "");
        set_source_rgb(cr, b->rgb[0], b->rgb[1], b->rgb[2], hovered ? 1.0 : 0.9);
        cairo_rectangle(cr, pad + label_w, cy + (row_h - bar_h) / 2,
                        bar_max * CLAMP(b->value, 0.0, 1.0), bar_h);
        cairo_fill(cr);
        if (hovered) {
            draw_tooltip(cr, width,
                         MIN(pad + label_w + bar_max * CLAMP(b->value, 0, 1) / 2,
                             (double)width - 90),
                         cy + (row_h - bar_h) / 2,
                         b->label ? b->label : "", NULL);
        }
    }
}

/* ---- pointer tracking ---------------------------------------------------- */

/* One controller per chart. Hover stays entirely on the C side: routing a
 * pointer move through the query seam would mean a host round-trip per frame
 * to redraw a box whose text C already has. */
static gboolean on_trend_motion(GtkEventControllerMotion *c, double x, double y,
                                gpointer data) {
    (void)c; (void)y; (void)data;
    g_trend_hover_x = x;
    gtk_widget_queue_draw(g_trend);
    return TRUE;
}

static gboolean on_daily_motion(GtkEventControllerMotion *c, double x, double y,
                                gpointer data) {
    (void)c; (void)y; (void)data;
    g_daily_hover_x = x;
    gtk_widget_queue_draw(g_daily);
    return TRUE;
}

static gboolean on_bars_motion(GtkEventControllerMotion *c, double x, double y,
                               gpointer data) {
    (void)c; (void)x; (void)data;
    g_bars_hover_y = y;
    gtk_widget_queue_draw(g_bars);
    return TRUE;
}

/* GTK4 has no `GtkEventControllerMotionFunc`; the "motion" signal is
 * gboolean (*)(controller, x, y, user_data). */
typedef gboolean (*br_motion_cb)(GtkEventControllerMotion *controller, double x,
                                 double y, gpointer data);

static void on_chart_leave(GtkEventControllerMotion *c, gpointer data) {
    GtkWidget *area = GTK_WIDGET(data);
    if (area == g_trend) g_trend_hover_x = -1;
    if (area == g_daily) g_daily_hover_x = -1;
    if (area == g_bars) g_bars_hover_y = -1;
    (void)c;
    gtk_widget_queue_draw(area);
}

static void track_hover(GtkWidget *area, br_motion_cb motion) {
    GtkEventController *motion_ctl = gtk_event_controller_motion_new();
    g_signal_connect(motion_ctl, "motion", G_CALLBACK(motion), NULL);
    gtk_widget_add_controller(area, motion_ctl);
    g_signal_connect(motion_ctl, "leave", G_CALLBACK(on_chart_leave), area);
}

/* ---- breakdown table ----------------------------------------------------- */

static void rebuild_table(void) {
    if (!g_table_grid) {
        return;
    }
    clear_box(g_table_grid);
    if (g_view.row_count <= 0) {
        gtk_widget_set_visible(g_table_grid, FALSE);
        return;
    }
    for (int r = 0; r < g_view.row_count; r++) {
        for (int c = 0; c < g_view.rows[r].cell_count; c++) {
            const char *text = g_view.rows[r].cells[c];
            gboolean header = (r == 0);
            GtkWidget *label = scaled_label(text ? text : "", header ? 0.8 : 1.0, header,
                                            header ? 0.45 : -1, header ? 0.45 : -1,
                                            header ? 0.45 : -1);
            if (header) {
                gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
            } else if (c > 0) {
                gtk_label_set_xalign(GTK_LABEL(label), 1.0f);
                gtk_widget_set_size_request(label, 110, -1);
            }
            gtk_grid_attach(GTK_GRID(g_table_grid), label, c, r, 1, 1);
        }
    }
    gtk_widget_set_visible(g_table_grid, TRUE);
}

/* ---- panes --------------------------------------------------------------- */

static GtkWidget *build_usage_pane(void) {
    GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_top(outer, 10);
    gtk_widget_set_margin_bottom(outer, 10);
    gtk_widget_set_margin_start(outer, 12);
    gtk_widget_set_margin_end(outer, 12);

    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_top(toolbar, 10);
    gtk_widget_set_margin_bottom(toolbar, 4);
    /* Mirrors the macOS toolbar: title, then provider menu, then the segmented
     * Metric and Range filters, then Refresh. */
    GtkWidget *title = gtk_label_new("Usage Dashboard");
    PangoAttrList *headline = pango_attr_list_new();
    pango_attr_list_insert(headline, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
    pango_attr_list_insert(headline, pango_attr_scale_new(1.15));
    gtk_label_set_attributes(GTK_LABEL(title), headline);
    pango_attr_list_unref(headline);
    gtk_box_append(GTK_BOX(toolbar), title);

    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(toolbar), spacer);

    /* Provider stays a menu, as on macOS. */
    static const char *const placeholder[] = {"All", NULL};
    g_provider_dd = gtk_drop_down_new_from_strings(placeholder);
    g_signal_connect(g_provider_dd, "notify::selected", G_CALLBACK(on_provider_changed), NULL);
    gtk_box_append(GTK_BOX(toolbar), gtk_label_new("Provider"));
    gtk_box_append(GTK_BOX(toolbar), g_provider_dd);

    static const char *const metrics[] = {"Tokens", "Cost", NULL};
    g_metric_group = build_segment(metrics, 2, g_query.metric, G_CALLBACK(on_segment_toggled));
    gtk_box_append(GTK_BOX(toolbar), g_metric_group);

    /* `ChartRange` raw values, as the macOS segmented picker shows them. The
     * spelled-out "24 hours" is both a parity break and wide enough to push the
     * toolbar past the window. */
    static const char *const ranges[] = {"24h", "7d", "30d", NULL};
    g_range_group = build_segment(ranges, 3, g_query.range, G_CALLBACK(on_segment_toggled));
    gtk_box_append(GTK_BOX(toolbar), g_range_group);

    GtkWidget *refresh = gtk_button_new_with_label("Refresh");
    g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh_clicked), NULL);
    gtk_box_append(GTK_BOX(toolbar), refresh);
    gtk_box_append(GTK_BOX(outer), toolbar);

    g_label_dd = gtk_drop_down_new_from_strings(placeholder);
    g_signal_connect(g_label_dd, "notify::selected", G_CALLBACK(on_label_changed), NULL);

    /* A wrapping label still reports its full text as its natural width, so a
     * long diagnostic line inflates the pane's minimum and pushes the toolbar
     * and charts off the right edge. Capping the wrap width keeps the content
     * inside the window instead. */
    g_status = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(g_status), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(g_status), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(g_status), 90);
    gtk_box_append(GTK_BOX(outer), g_status);

    g_diag = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(g_diag), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(g_diag), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(g_diag), 90);
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
        GtkWidget *frame;
        if (charts[i].area == &g_trend) {
            /* macOS puts the heading and the segmented Window filter in the
             * card header, not in the toolbar. */
            GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
            GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
            g_trend_title = scaled_label(charts[i].title, 1.05, TRUE, -1, -1, -1);
            gtk_box_append(GTK_BOX(header), g_trend_title);
            GtkWidget *gap = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_set_hexpand(gap, TRUE);
            gtk_box_append(GTK_BOX(header), gap);
            g_label_group = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_box_append(GTK_BOX(header), g_label_group);
            gtk_box_append(GTK_BOX(box), header);
            gtk_box_append(GTK_BOX(box), area);
            frame = gtk_frame_new(NULL);
            gtk_frame_set_child(GTK_FRAME(frame), box);
        } else {
            frame = gtk_frame_new(charts[i].title);
            gtk_frame_set_child(GTK_FRAME(frame), area);
        }
        gtk_box_append(GTK_BOX(outer), frame);
        *charts[i].area = area;
        *charts[i].frame = frame;
    }
    track_hover(g_trend, on_trend_motion);
    track_hover(g_daily, on_daily_motion);
    track_hover(g_bars, on_bars_motion);

    g_table_grid = gtk_grid_new();
    gtk_grid_set_row_spacing(GTK_GRID(g_table_grid), 4);
    gtk_grid_set_column_spacing(GTK_GRID(g_table_grid), 16);
    GtkWidget *table_frame = gtk_frame_new("Per-model breakdown");
    gtk_frame_set_child(GTK_FRAME(table_frame), g_table_grid);
    gtk_widget_set_margin_top(table_frame, 4);
    gtk_box_append(GTK_BOX(outer), table_frame);
    g_table_frame = table_frame;

    /* Loading/empty state, centred in place of the charts. */
    g_empty = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(g_empty), TRUE);
    gtk_label_set_justify(GTK_LABEL(g_empty), GTK_JUSTIFY_CENTER);
    gtk_widget_set_margin_top(g_empty, 48);
    gtk_box_append(GTK_BOX(outer), g_empty);

    GtkWidget *scroller = gtk_scrolled_window_new();
    /* Scroll horizontally as a safety net: a long model name or a wide chart
     * legend must never be able to push content off the window. */
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller),
                                   GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
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

/* The Window filter's items come from the data, so it is rebuilt when they
 * change rather than updated in place. */
static void rebuild_window_segment(void) {
    if (!g_label_group) {
        return;
    }
    clear_box(g_label_group);
    for (int i = 0; i < g_view.trend_label_count; i++) {
        GtkWidget *button = gtk_toggle_button_new_with_label(
            g_view.trend_labels[i] ? g_view.trend_labels[i] : "");
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button), i == g_query.trend_label);
        g_object_set_data(G_OBJECT(button), "segment-index", GINT_TO_POINTER(i));
        g_signal_connect(button, "toggled", G_CALLBACK(on_segment_toggled), g_label_group);
        gtk_box_append(GTK_BOX(g_label_group), button);
    }
    if (g_trend_title) {
        const char *label = (g_query.trend_label >= 0
                             && g_query.trend_label < g_view.trend_label_count
                             && g_view.trend_labels[g_query.trend_label])
            ? g_view.trend_labels[g_query.trend_label] : "";
        char text[96];
        g_snprintf(text, sizeof(text), "Remaining over time — %s", label);
        gtk_label_set_text(GTK_LABEL(g_trend_title), text);
    }
}

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
    rebuild_table();
    g_syncing = TRUE;
    set_dropdown(g_provider_dd, g_view.providers, g_view.provider_count, g_query.provider);
    rebuild_window_segment();
    g_syncing = FALSE;

    /* A new view invalidates whatever the pointer was pointing at. */
    g_trend_hover_x = g_daily_hover_x = g_bars_hover_y = -1;

    if (g_status) {
        gtk_label_set_text(GTK_LABEL(g_status), g_view.status ? g_view.status : "");
        gtk_widget_set_visible(g_status, g_view.status && *g_view.status);
    }
    if (g_diag) {
        gtk_label_set_text(GTK_LABEL(g_diag), g_view.diagnostics ? g_view.diagnostics : "");
        gtk_widget_set_visible(g_diag, g_view.diagnostics && *g_view.diagnostics);
    }
    gboolean any_chart = g_view.series_count > 0 || g_view.segment_count > 0
                         || g_view.bar_count > 0;
    if (g_empty) {
        gtk_label_set_text(GTK_LABEL(g_empty), g_view.status ? g_view.status : "");
        gtk_widget_set_visible(g_empty, !any_chart);
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
    if (g_table_frame) {
        gtk_widget_set_visible(g_table_frame, g_view.row_count > 1);
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

    /* No header bar of our own: a GtkApplicationWindow already provides one
     * with the window controls, and adding a second stacks a duplicate close
     * button on top of it. The macOS toolbar title lives in the content. */
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);

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

/// Points the window at a themed icon and makes sure the theme can find it.
///
/// GTK 4.14 has no texture-based window icon, and using the theme name has a
/// side benefit: the window and the `.desktop` entry resolve the same `Icon=`
/// name, so they can never disagree. The containing hicolor directory is added
/// to the search path because a freshly installed icon is otherwise invisible
/// until the icon cache is rebuilt.
void br_ui_set_icon(const char *theme_name, const char *icon_dir) {
    if (!g_window || !theme_name || !*theme_name) {
        return;
    }
    GdkDisplay *display = gdk_display_get_default();
    if (display && icon_dir && *icon_dir) {
        GtkIconTheme *theme = gtk_icon_theme_get_for_display(display);
        gtk_icon_theme_add_search_path(theme, icon_dir);
    }
    gtk_window_set_icon_name(GTK_WINDOW(g_window), theme_name);
}

void br_ui_show_pane(int pane) {    if (pane < 0 || pane >= BR_PANE_COUNT || !g_stack) {
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
