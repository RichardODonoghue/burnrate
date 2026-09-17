#include "burnrate_gtk.h"
#include <gtk/gtk.h>
#include <string.h>

static GtkWidget *g_window = NULL;
static GtkWidget *g_label = NULL;
static br_void_cb g_refresh = NULL;
static void *g_ctx = NULL;

typedef struct {
    char *text;
} br_post_t;

static gboolean set_body_idle(gpointer data) {
    br_post_t *post = (br_post_t *)data;
    if (g_label) {
        gtk_label_set_text(GTK_LABEL(g_label), post->text);
    }
    g_free(post->text);
    g_free(post);
    return G_SOURCE_REMOVE;
}

static gboolean on_timeout(gpointer data) {
    (void)data;
    if (g_refresh) {
        g_refresh(g_ctx);
    }
    return G_SOURCE_CONTINUE;
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

static void on_activate(GtkApplication *app, gpointer data) {
    (void)data;
    GtkWidget *window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "BurnRate");
    gtk_window_set_default_size(GTK_WINDOW(window), 440, 380);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_top(box, 14);
    gtk_widget_set_margin_bottom(box, 14);
    gtk_widget_set_margin_start(box, 14);
    gtk_widget_set_margin_end(box, 14);

    g_label = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(g_label), 0.0f);
    gtk_label_set_yalign(GTK_LABEL(g_label), 0.0f);
    gtk_label_set_selectable(GTK_LABEL(g_label), TRUE);
    gtk_widget_set_vexpand(g_label, TRUE);
    gtk_widget_set_halign(g_label, GTK_ALIGN_FILL);
    gtk_box_append(GTK_BOX(box), g_label);

    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *refresh = gtk_button_new_with_label("Refresh");
    g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh_clicked), NULL);
    gtk_box_append(GTK_BOX(buttons), refresh);

    GtkWidget *quit = gtk_button_new_with_label("Quit");
    g_signal_connect(quit, "clicked", G_CALLBACK(on_quit_clicked), NULL);
    gtk_box_append(GTK_BOX(buttons), quit);

    gtk_box_append(GTK_BOX(box), buttons);
    gtk_window_set_child(GTK_WINDOW(window), box);

    g_window = window;
    gtk_window_present(GTK_WINDOW(window));
    if (g_refresh) {
        g_refresh(g_ctx);
    }
    g_timeout_add_seconds(300, on_timeout, NULL);
}

void br_ui_run(const char *title, const char *body, br_void_cb on_refresh, void *ctx) {
    (void)title;
    g_refresh = on_refresh;
    g_ctx = ctx;
    GtkApplication *app = gtk_application_new("com.burnrate.desktop", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    g_application_run(G_APPLICATION(app), 0, NULL);
    g_object_unref(app);
    if (body) {
        /* Nothing: the label starts empty and the host posts immediately. */
    }
}

void br_ui_post(const char *body) {
    if (!body) {
        return;
    }
    br_post_t *post = g_new0(br_post_t, 1);
    post->text = g_strdup(body);
    g_idle_add(set_body_idle, post);
}

void br_ui_quit(void) {
    if (g_window) {
        GtkApplication *app = gtk_window_get_application(GTK_WINDOW(g_window));
        if (app) {
            g_application_quit(G_APPLICATION(app));
        }
    }
}

/* ---- settings window ---------------------------------------------------- */

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
        GtkWidget *child = gtk_widget_get_first_child(g_settings_box);
        while (child) {
            GtkWidget *next = gtk_widget_get_next_sibling(child);
            gtk_box_remove(GTK_BOX(g_settings_box), child);
            child = next;
        }
    }

    for (int i = 0; i < check_count; i++) {
        GtkWidget *check = gtk_check_button_new_with_label(checks[i].label ? checks[i].label : "");
        gtk_check_button_set_active(GTK_CHECK_BUTTON(check), checks[i].checked ? TRUE : FALSE);
        g_signal_connect(check, "toggled", G_CALLBACK(on_checkbox_toggled), GINT_TO_POINTER(checks[i].id));
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
        g_signal_connect(spin, "value-changed", G_CALLBACK(on_spin_changed), GINT_TO_POINTER(spins[i].id));
        gtk_box_append(GTK_BOX(row), spin);
        gtk_box_append(GTK_BOX(g_settings_box), row);
    }

    gtk_window_present(GTK_WINDOW(g_settings_window));
}

/* ---- charts ------------------------------------------------------------- */

#include <cairo.h>

static GtkWidget *g_chart_window = NULL;
static GtkWidget *g_trend_area = NULL;
static GtkWidget *g_bars_area = NULL;

static br_trend_point *g_trend_points = NULL;
static int g_trend_count = 0;
static double *g_trend_rgb = NULL;
static int g_trend_series = 0;

static double *g_bar_values = NULL;
static double *g_bar_rgb = NULL;
static int g_bar_count = 0;
static char *g_bar_labels = NULL;

static void set_source_rgb(cairo_t *cr, const double *rgb, double alpha) {
    cairo_set_source_rgba(cr, rgb[0], rgb[1], rgb[2], alpha);
}

static void draw_trend(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    GdkRGBA fg;
    gtk_widget_get_color(GTK_WIDGET(area), &fg);

    const double left = 38, right = 8, top = 8, bottom = 14;
    double w = width - left - right;
    double h = height - top - bottom;
    if (w <= 1 || h <= 1) return;

    cairo_select_font_face(cr, "sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 9);
    cairo_set_line_width(cr, 1);
    for (int p = 0; p <= 100; p += 25) {
        double y = top + h * (1 - p / 100.0);
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.18);
        cairo_move_to(cr, left, y);
        cairo_line_to(cr, left + w, y);
        cairo_stroke(cr);
        char label[8];
        snprintf(label, sizeof(label), "%d%%", p);
        cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.75);
        cairo_move_to(cr, 3, y + 3);
        cairo_show_text(cr, label);
    }

    if (!g_trend_points || g_trend_count == 0) return;
    cairo_set_line_width(cr, 2);
    for (int s = 0; s < g_trend_series; s++) {
        const double *rgb = &g_trend_rgb[s * 3];
        cairo_set_source_rgba(cr, rgb[0], rgb[1], rgb[2], 1.0);
        gboolean started = FALSE;
        for (int i = 0; i < g_trend_count; i++) {
            if (g_trend_points[i].series != s) continue;
            double x = left + w * g_trend_points[i].x;
            double y = top + h * (1 - g_trend_points[i].y / 100.0);
            if (!started) { cairo_move_to(cr, x, y); started = TRUE; }
            else { cairo_line_to(cr, x, y); }
        }
        cairo_stroke(cr);
    }
}

static void draw_bars(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    GdkRGBA fg;
    gtk_widget_get_color(GTK_WIDGET(area), &fg);
    cairo_select_font_face(cr, "sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 10);

    if (g_bar_count <= 0) return;
    double row = (double)height / g_bar_count;
    double bar_area = width * 0.6;
    double x0 = width - bar_area - 6;
    for (int i = 0; i < g_bar_count; i++) {
        double y = row * i + row * 0.2;
        double bh = row * 0.6;
        const double *rgb = &g_bar_rgb[i * 3];
        cairo_set_source_rgba(cr, rgb[0], rgb[1], rgb[2], 0.9);
        double bw = bar_area * (g_bar_values[i] < 0 ? 0 : (g_bar_values[i] > 1 ? 1 : g_bar_values[i]));
        cairo_rectangle(cr, x0, y, bw, bh);
        cairo_fill(cr);
        if (g_bar_labels) {
            const char *label = g_bar_labels;
            for (int k = 0; k < i && label; k++) {
                label = strchr(label, '\n');
                if (label) label++;
            }
            if (label) {
                char buf[128];
                size_t n = strcspn(label, "\n");
                if (n >= sizeof(buf)) n = sizeof(buf) - 1;
                memcpy(buf, label, n);
                buf[n] = '\0';
                cairo_set_source_rgba(cr, fg.red, fg.green, fg.blue, 0.9);
                cairo_move_to(cr, 6, y + bh * 0.7);
                cairo_show_text(cr, buf);
            }
        }
    }
}

void br_chart_show(const char *title) {
    if (!g_chart_window) {
        g_chart_window = gtk_window_new();
        gtk_window_set_title(GTK_WINDOW(g_chart_window), title ? title : "BurnRate Charts");
        gtk_window_set_default_size(GTK_WINDOW(g_chart_window), 640, 460);
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
        gtk_widget_set_margin_top(box, 12);
        gtk_widget_set_margin_bottom(box, 12);
        gtk_widget_set_margin_start(box, 12);
        gtk_widget_set_margin_end(box, 12);

        g_trend_area = gtk_drawing_area_new();
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(g_trend_area), 240);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(g_trend_area), draw_trend, NULL, NULL);
        gtk_box_append(GTK_BOX(box), g_trend_area);

        g_bars_area = gtk_drawing_area_new();
        gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(g_bars_area), 200);
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(g_bars_area), draw_bars, NULL, NULL);
        gtk_box_append(GTK_BOX(box), g_bars_area);

        gtk_window_set_child(GTK_WINDOW(g_chart_window), box);
    }
    gtk_window_present(GTK_WINDOW(g_chart_window));
}

void br_chart_set_trend(const br_trend_point *points, int point_count,
                        const double *series_rgb, int series_count) {
    g_free(g_trend_points);
    g_free(g_trend_rgb);
    g_trend_points = NULL;
    g_trend_rgb = NULL;
    g_trend_count = 0;
    g_trend_series = series_count;
    if (point_count > 0) {
        g_trend_points = g_new0(br_trend_point, point_count);
        memcpy(g_trend_points, points, sizeof(br_trend_point) * point_count);
        g_trend_count = point_count;
    }
    if (series_count > 0) {
        g_trend_rgb = g_new0(double, series_count * 3);
        memcpy(g_trend_rgb, series_rgb, sizeof(double) * series_count * 3);
    }
    if (g_trend_area) gtk_widget_queue_draw(g_trend_area);
}

void br_chart_set_bars(const double *values, const double *bar_rgb, int bar_count,
                       const char *labels) {
    g_free(g_bar_values);
    g_free(g_bar_rgb);
    g_free(g_bar_labels);
    g_bar_values = NULL;
    g_bar_rgb = NULL;
    g_bar_labels = NULL;
    g_bar_count = bar_count;
    if (bar_count > 0) {
        g_bar_values = g_new0(double, bar_count);
        memcpy(g_bar_values, values, sizeof(double) * bar_count);
        g_bar_rgb = g_new0(double, bar_count * 3);
        memcpy(g_bar_rgb, bar_rgb, sizeof(double) * bar_count * 3);
    }
    if (labels) g_bar_labels = g_strdup(labels);
    if (g_bars_area) gtk_widget_queue_draw(g_bars_area);
}
