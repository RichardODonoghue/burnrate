#include "burnrate_tray.h"
#include <gio/gio.h>
#include <glib.h>
#include <string.h>
#include <unistd.h>

#define SNI_PATH "/StatusNotifierItem"
#define MENU_PATH "/MenuBar"
#define SNI_INTERFACE "org.kde.StatusNotifierItem"
#define MENU_INTERFACE "com.canonical.dbusmenu"
#define MAX_TRAYS 16

static const gchar *SNI_XML =
    "<node>"
    "<interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/>"
    "<property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<property name='ItemIsMenu' type='b' access='read'/>"
    "<method name='Activate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/></method>"
    "<method name='Scroll'><arg name='delta' type='i' direction='in'/><arg name='orientation' type='s' direction='in'/></method>"
    "<signal name='NewIcon'/>"
    "<signal name='NewTitle'/>"
    "<signal name='NewStatus'><arg name='status' type='s'/></signal>"
    "</interface>"
    "</node>";

static const gchar *MENU_XML =
    "<node>"
    "<interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/>"
    "<property name='TextDirection' type='s' access='read'/>"
    "<property name='Status' type='s' access='read'/>"
    "<property name='IconThemePath' type='as' access='read'/>"
    "<method name='GetLayout'>"
    "<arg name='parentId' type='i' direction='in'/>"
    "<arg name='recursionDepth' type='i' direction='in'/>"
    "<arg name='propertyNames' type='as' direction='in'/>"
    "<arg name='revision' type='u' direction='out'/>"
    "<arg name='layout' type='(ia{sv}av)' direction='out'/>"
    "</method>"
    "<method name='GetGroupProperties'>"
    "<arg name='ids' type='ai' direction='in'/>"
    "<arg name='propertyNames' type='as' direction='in'/>"
    "<arg name='properties' type='a(ia{sv})' direction='out'/>"
    "</method>"
    "<method name='GetProperty'>"
    "<arg name='id' type='i' direction='in'/>"
    "<arg name='name' type='s' direction='in'/>"
    "<arg name='value' type='v' direction='out'/>"
    "</method>"
    "<method name='Event'>"
    "<arg name='id' type='i' direction='in'/>"
    "<arg name='eventId' type='s' direction='in'/>"
    "<arg name='data' type='v' direction='in'/>"
    "<arg name='timestamp' type='u' direction='in'/>"
    "</method>"
    "<method name='AboutToShow'><arg name='id' type='i' direction='in'/><arg name='needUpdate' type='b' direction='out'/></method>"
    "<signal name='LayoutUpdated'><arg name='revision' type='u'/><arg name='parent' type='i'/></signal>"
    "<signal name='ItemsPropertiesUpdated'>"
    "<arg name='updatedProps' type='a(ia{sv})'/>"
    "<arg name='removedProps' type='a(ias)'/>"
    "</signal>"
    "</interface>"
    "</node>";

typedef struct {
    gchar *label;
    gint action;
    gboolean enabled;
} tray_row;

typedef struct {
    GDBusConnection *bus;
    guint owner_id;
    guint sni_reg;
    guint menu_reg;
    gchar *service_name;
    gchar *icon_name;
    gchar *title;
    tray_row *rows;
    gint row_count;
    guint32 revision;
    gint index;
    br_tray_action_cb callback;
    gpointer ctx;
} tray_instance;

static tray_instance *g_trays[MAX_TRAYS];
static gint g_tray_count = 0;
static GMutex g_lock;

static tray_instance *tray_at(int index) {
    if (index < 0 || index >= g_tray_count) return NULL;
    return g_trays[index];
}

/* ---- menu helpers ------------------------------------------------------- */

static GVariant *row_properties(tray_instance *tray, gint index) {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
    tray_row *row = &tray->rows[index];
    if (row->action == -2) {
        g_variant_builder_add(&builder, "{sv}", "type", g_variant_new_string("separator"));
    } else if (row->action == -1) {
        g_variant_builder_add(&builder, "{sv}", "label", g_variant_new_string(row->label ? row->label : ""));
        g_variant_builder_add(&builder, "{sv}", "enabled", g_variant_new_boolean(FALSE));
        g_variant_builder_add(&builder, "{sv}", "visible", g_variant_new_boolean(TRUE));
        g_variant_builder_add(&builder, "{sv}", "type", g_variant_new_string("standard"));
    } else {
        g_variant_builder_add(&builder, "{sv}", "label", g_variant_new_string(row->label ? row->label : ""));
        g_variant_builder_add(&builder, "{sv}", "enabled", g_variant_new_boolean(row->enabled));
        g_variant_builder_add(&builder, "{sv}", "visible", g_variant_new_boolean(TRUE));
        g_variant_builder_add(&builder, "{sv}", "type", g_variant_new_string("standard"));
    }
    return g_variant_builder_end(&builder);
}

static GVariant *empty_properties(void) {
    GVariantBuilder builder;
    g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
    return g_variant_builder_end(&builder);
}

/* layout node: (i id, a{sv} properties, av children) */
static GVariant *build_layout(tray_instance *tray, gint parent) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (parent == 0) {
        for (gint i = 0; i < tray->row_count; i++) {
            GVariantBuilder empty;
            g_variant_builder_init(&empty, G_VARIANT_TYPE("av"));
            GVariant *node =
                g_variant_new("(i@a{sv}@av)", i + 1, row_properties(tray, i), g_variant_builder_end(&empty));
            g_variant_builder_add(&children, "v", node);
        }
    }
    return g_variant_new("(i@a{sv}@av)", parent, empty_properties(), g_variant_builder_end(&children));
}

/* ---- com.canonical.dbusmenu -------------------------------------------- */

static GVariant *menu_get_property(GDBusConnection *connection, const gchar *sender,
                                   const gchar *path, const gchar *interface_name,
                                   const gchar *property_name, GError **error, gpointer user_data) {
    (void)connection; (void)sender; (void)path; (void)interface_name; (void)error; (void)user_data;
    if (g_strcmp0(property_name, "Version") == 0) return g_variant_new_uint32(3);
    if (g_strcmp0(property_name, "TextDirection") == 0) return g_variant_new_string("ltr");
    if (g_strcmp0(property_name, "Status") == 0) return g_variant_new_string("normal");
    if (g_strcmp0(property_name, "IconThemePath") == 0) return g_variant_new_strv(NULL, 0);
    return NULL;
}

static void menu_method_call(GDBusConnection *connection, const gchar *sender, const gchar *path,
                             const gchar *interface_name, const gchar *method_name, GVariant *parameters,
                             GDBusMethodInvocation *invocation, gpointer user_data) {
    (void)connection; (void)sender; (void)path; (void)interface_name;
    tray_instance *tray = (tray_instance *)user_data;

    if (g_strcmp0(method_name, "GetLayout") == 0) {
        gint parent = 0;
        gint depth = 0;
        GVariant *names = NULL;
        g_variant_get(parameters, "(ii@as)", &parent, &depth, &names);
        if (names) g_variant_unref(names);
        g_mutex_lock(&g_lock);
        GVariant *root = build_layout(tray, parent);
        guint32 revision = tray->revision;
        g_mutex_unlock(&g_lock);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(u@(ia{sv}av))", revision, root));
        return;
    }

    if (g_strcmp0(method_name, "GetGroupProperties") == 0) {
        GVariantBuilder out;
        g_variant_builder_init(&out, G_VARIANT_TYPE("a(ia{sv})"));
        g_mutex_lock(&g_lock);
        for (gint i = 0; i < tray->row_count; i++) {
            g_variant_builder_add(&out, "(i@a{sv})", i + 1, row_properties(tray, i));
        }
        g_mutex_unlock(&g_lock);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(@a(ia{sv}))", g_variant_builder_end(&out)));
        return;
    }

    if (g_strcmp0(method_name, "GetProperty") == 0) {
        gint id = 0;
        const gchar *name = NULL;
        g_variant_get(parameters, "(i&s)", &id, &name);
        GVariant *value = NULL;
        g_mutex_lock(&g_lock);
        if (id >= 1 && id <= tray->row_count) {
            GVariant *props = row_properties(tray, id - 1);
            value = g_variant_lookup_value(props, name, NULL);
            g_variant_unref(props);
        }
        g_mutex_unlock(&g_lock);
        if (value) {
            g_dbus_method_invocation_return_value(invocation, g_variant_new("(v)", value));
        } else {
            g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                                                  "unknown property");
        }
        return;
    }

    if (g_strcmp0(method_name, "Event") == 0) {
        gint id = 0;
        const gchar *event_id = NULL;
        GVariant *data = NULL;
        g_variant_get(parameters, "(i&s@vu)", &id, &event_id, &data, NULL);
        if (data) g_variant_unref(data);
        if (g_strcmp0(event_id, "clicked") == 0 && id >= 1 && id <= tray->row_count) {
            g_mutex_lock(&g_lock);
            gint action = tray->rows[id - 1].action;
            br_tray_action_cb callback = tray->callback;
            gpointer ctx = tray->ctx;
            g_mutex_unlock(&g_lock);
            if (action >= 0 && callback) {
                callback(tray->index, action, ctx);
            }
        }
        g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
        return;
    }

    if (g_strcmp0(method_name, "AboutToShow") == 0) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("(b)", FALSE));
        return;
    }

    if (g_strcmp0(method_name, "AboutToShowGroup") == 0) {
        GVariantBuilder updates;
        g_variant_builder_init(&updates, G_VARIANT_TYPE("ai"));
        g_dbus_method_invocation_return_value(
            invocation,
            g_variant_new("(@ai@ai)", g_variant_builder_end(&updates), g_variant_builder_end(&updates)));
        return;
    }

    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "unsupported method");
}

/* ---- org.kde.StatusNotifierItem ---------------------------------------- */

static GVariant *sni_get_property(GDBusConnection *connection, const gchar *sender, const gchar *path,
                                  const gchar *interface_name, const gchar *property_name,
                                  GError **error, gpointer user_data) {
    (void)connection; (void)sender; (void)path; (void)interface_name; (void)error;
    tray_instance *tray = (tray_instance *)user_data;
    if (g_strcmp0(property_name, "Category") == 0) return g_variant_new_string("ApplicationStatus");
    if (g_strcmp0(property_name, "Id") == 0) return g_variant_new_string("BurnRate");
    if (g_strcmp0(property_name, "Title") == 0) return g_variant_new_string(tray->title ? tray->title : "BurnRate");
    if (g_strcmp0(property_name, "Status") == 0) return g_variant_new_string("Active");
    if (g_strcmp0(property_name, "IconName") == 0) {
        return g_variant_new_string(tray->icon_name ? tray->icon_name : "utilities-system-monitor");
    }
    if (g_strcmp0(property_name, "Menu") == 0) return g_variant_new_object_path(MENU_PATH);
    if (g_strcmp0(property_name, "ItemIsMenu") == 0) return g_variant_new_boolean(TRUE);
    return NULL;
}

static void sni_method_call(GDBusConnection *connection, const gchar *sender, const gchar *path,
                            const gchar *interface_name, const gchar *method_name, GVariant *parameters,
                            GDBusMethodInvocation *invocation, gpointer user_data) {
    (void)connection; (void)sender; (void)path; (void)interface_name; (void)parameters;
    (void)method_name; (void)user_data;
    g_dbus_method_invocation_return_value(invocation, NULL);
}

/* ---- lifecycle ---------------------------------------------------------- */

static void on_name_acquired(GDBusConnection *connection, const gchar *name, gpointer user_data) {
    (void)connection;
    tray_instance *tray = (tray_instance *)user_data;
    g_dbus_connection_call(tray->bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                           "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
                           g_variant_new("(s)", name), NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

int br_tray_add(const char *icon_name, const char *title, br_tray_action_cb callback, void *ctx) {
    if (g_tray_count >= MAX_TRAYS) return -1;
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) {
        if (error) g_error_free(error);
        return -1;
    }
    tray_instance *tray = g_new0(tray_instance, 1);
    tray->bus = bus;
    tray->icon_name = g_strdup(icon_name);
    tray->title = g_strdup(title);
    tray->callback = callback;
    tray->ctx = ctx;
    tray->revision = 1;

    GDBusNodeInfo *sni_info = g_dbus_node_info_new_for_xml(SNI_XML, NULL);
    GDBusNodeInfo *menu_info = g_dbus_node_info_new_for_xml(MENU_XML, NULL);
    static GDBusInterfaceVTable sni_vtable = { sni_method_call, sni_get_property, NULL };
    static GDBusInterfaceVTable menu_vtable = { menu_method_call, menu_get_property, NULL };

    tray->sni_reg = g_dbus_connection_register_object(bus, SNI_PATH, sni_info->interfaces[0],
                                                      &sni_vtable, tray, NULL, NULL);
    tray->menu_reg = g_dbus_connection_register_object(bus, MENU_PATH, menu_info->interfaces[0],
                                                       &menu_vtable, tray, NULL, NULL);
    g_dbus_node_info_unref(sni_info);
    g_dbus_node_info_unref(menu_info);

    gint index = -1;
    for (gint i = 0; i < g_tray_count; i++) {
        if (!g_trays[i]) { index = i; break; }
    }
    if (index < 0) {
        if (g_tray_count >= MAX_TRAYS) {
            g_free(tray->icon_name);
            g_free(tray->title);
            g_clear_object(&tray->bus);
            g_free(tray);
            return -1;
        }
        index = g_tray_count++;
    }
    tray->index = index;
    g_trays[index] = tray;

    tray->service_name = g_strdup_printf("org.kde.StatusNotifierItem-%d-%d", (int)getpid(), index);
    tray->owner_id = g_bus_own_name_on_connection(bus, tray->service_name, G_BUS_NAME_OWNER_FLAGS_NONE,
                                                  on_name_acquired, NULL, tray, NULL);
    return index;
}

void br_tray_set_items(int tray_index, const br_tray_item *items, int count) {
    tray_instance *tray = tray_at(tray_index);
    if (!tray) return;
    g_mutex_lock(&g_lock);
    for (gint i = 0; i < tray->row_count; i++) g_free(tray->rows[i].label);
    g_free(tray->rows);
    tray->rows = NULL;
    tray->row_count = 0;
    if (count > 0) {
        tray->rows = g_new0(tray_row, count);
        for (gint i = 0; i < count; i++) {
            tray->rows[i].label = g_strdup(items[i].label ? items[i].label : "");
            tray->rows[i].action = items[i].action_id;
            tray->rows[i].enabled = items[i].enabled ? TRUE : FALSE;
        }
        tray->row_count = count;
    }
    guint32 revision = ++tray->revision;
    g_mutex_unlock(&g_lock);

    g_dbus_connection_emit_signal(tray->bus, NULL, MENU_PATH, MENU_INTERFACE, "LayoutUpdated",
                                  g_variant_new("(ui)", revision, 0), NULL);
}

void br_tray_set_title(int tray_index, const char *title) {
    tray_instance *tray = tray_at(tray_index);
    if (!tray) return;
    g_mutex_lock(&g_lock);
    g_free(tray->title);
    tray->title = g_strdup(title ? title : "BurnRate");
    g_mutex_unlock(&g_lock);
    g_dbus_connection_emit_signal(tray->bus, NULL, SNI_PATH, SNI_INTERFACE, "NewTitle", NULL, NULL);
}

void br_tray_remove(int tray_index) {
    tray_instance *tray = tray_at(tray_index);
    if (!tray) return;
    if (tray->owner_id) g_bus_unown_name(tray->owner_id);
    if (tray->sni_reg) g_dbus_connection_unregister_object(tray->bus, tray->sni_reg);
    if (tray->menu_reg) g_dbus_connection_unregister_object(tray->bus, tray->menu_reg);
    for (gint i = 0; i < tray->row_count; i++) g_free(tray->rows[i].label);
    g_free(tray->rows);
    g_free(tray->service_name);
    g_free(tray->icon_name);
    g_free(tray->title);
    g_clear_object(&tray->bus);
    g_free(tray);
    g_trays[tray_index] = NULL;
    while (g_tray_count > 0 && !g_trays[g_tray_count - 1]) g_tray_count--;
}

void br_tray_stop_all(void) {
    for (gint t = 0; t < g_tray_count; t++) {
        tray_instance *tray = g_trays[t];
        if (!tray) continue;
        if (tray->owner_id) g_bus_unown_name(tray->owner_id);
        if (tray->sni_reg) g_dbus_connection_unregister_object(tray->bus, tray->sni_reg);
        if (tray->menu_reg) g_dbus_connection_unregister_object(tray->bus, tray->menu_reg);
        for (gint i = 0; i < tray->row_count; i++) g_free(tray->rows[i].label);
        g_free(tray->rows);
        g_free(tray->service_name);
        g_free(tray->icon_name);
        g_free(tray->title);
        g_clear_object(&tray->bus);
        g_free(tray);
        g_trays[t] = NULL;
    }
    g_tray_count = 0;
}
