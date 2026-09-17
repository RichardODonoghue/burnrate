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
