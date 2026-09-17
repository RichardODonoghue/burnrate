#include "burnrate_win32.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>

#define BR_WM_POST (WM_APP + 2)
#define BR_WM_TRAY (WM_APP + 1)
#define BR_TIMER_ID 1
#define BR_MAX_TRAYS 16

static HWND g_hwnd = NULL;
static HWND g_refresh_button = NULL;
static HWND g_quit_button = NULL;
static br_void_cb g_refresh = NULL;
static void *g_ctx = NULL;
static char *g_body = NULL;
static CRITICAL_SECTION g_lock;

static char *br_strdup(const char *text) {
    if (!text) text = "";
    size_t n = strlen(text) + 1;
    char *copy = (char *)malloc(n);
    if (copy) memcpy(copy, text, n);
    return copy;
}

/* ---- charts storage ----------------------------------------------------- */

static br_trend_point *g_trend_points = NULL;
static int g_trend_count = 0;
static double *g_trend_rgb = NULL;
static int g_trend_series = 0;

static double *g_bar_values = NULL;
static double *g_bar_rgb = NULL;
static int g_bar_count = 0;
static char *g_bar_labels = NULL;

static br_bar_segment *g_daily = NULL;
static int g_daily_count = 0;
static int g_daily_days = 0;

void br_chart_set_trend(const br_trend_point *points, int point_count,
                        const double *series_rgb, int series_count) {
    EnterCriticalSection(&g_lock);
    free(g_trend_points);
    free(g_trend_rgb);
    g_trend_points = NULL;
    g_trend_rgb = NULL;
    g_trend_count = 0;
    g_trend_series = series_count;
    if (point_count > 0) {
        g_trend_points = (br_trend_point *)malloc(sizeof(br_trend_point) * point_count);
        memcpy(g_trend_points, points, sizeof(br_trend_point) * point_count);
        g_trend_count = point_count;
    }
    if (series_count > 0) {
        g_trend_rgb = (double *)malloc(sizeof(double) * series_count * 3);
        memcpy(g_trend_rgb, series_rgb, sizeof(double) * series_count * 3);
    }
    LeaveCriticalSection(&g_lock);
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, TRUE);
}

void br_chart_set_bars(const double *values, const double *bar_rgb, int count,
                       const char *labels) {
    EnterCriticalSection(&g_lock);
    free(g_bar_values);
    free(g_bar_rgb);
    free(g_bar_labels);
    g_bar_values = NULL;
    g_bar_rgb = NULL;
    g_bar_labels = NULL;
    g_bar_count = count;
    if (count > 0) {
        g_bar_values = (double *)malloc(sizeof(double) * count);
        memcpy(g_bar_values, values, sizeof(double) * count);
        g_bar_rgb = (double *)malloc(sizeof(double) * count * 3);
        memcpy(g_bar_rgb, bar_rgb, sizeof(double) * count * 3);
    }
    g_bar_labels = br_strdup(labels);
    LeaveCriticalSection(&g_lock);
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, TRUE);
}

void br_chart_set_daily(const br_bar_segment *segments, int count, int day_count) {
    EnterCriticalSection(&g_lock);
    free(g_daily);
    g_daily = NULL;
    g_daily_count = 0;
    g_daily_days = day_count;
    if (count > 0) {
        g_daily = (br_bar_segment *)malloc(sizeof(br_bar_segment) * count);
        memcpy(g_daily, segments, sizeof(br_bar_segment) * count);
        g_daily_count = count;
    }
    LeaveCriticalSection(&g_lock);
    if (g_hwnd) InvalidateRect(g_hwnd, NULL, TRUE);
}

/* ---- tray --------------------------------------------------------------- */

typedef struct {
    BOOL used;
    char *title;
    br_tray_action_cb callback;
    void *ctx;
    br_tray_item *items;
    int item_count;
    HICON icon;
} tray_state;

static tray_state g_trays[BR_MAX_TRAYS];
static int g_tray_high = 0;

static COLORREF rgb_to_colorref(double r, double g, double b) {
    return RGB((int)(r * 255), (int)(g * 255), (int)(b * 255));
}

static void tray_menu_command(int id) {
    for (int t = 0; t < g_tray_high; t++) {
        if (!g_trays[t].used) continue;
        if (id >= 0 && id < g_trays[t].item_count) {
            br_tray_item *item = &g_trays[t].items[id];
            if (item->action_id >= 0 && g_trays[t].callback) {
                g_trays[t].callback(t, item->action_id, g_trays[t].ctx);
            }
            return;
        }
    }
}

int br_tray_add(const char *title, br_tray_action_cb callback, void *ctx) {
    int index = -1;
    for (int i = 0; i < g_tray_high; i++) {
        if (!g_trays[i].used) { index = i; break; }
    }
    if (index < 0) {
        if (g_tray_high >= BR_MAX_TRAYS) return -1;
        index = g_tray_high++;
    }
    tray_state *tray = &g_trays[index];
    memset(tray, 0, sizeof(*tray));
    tray->used = TRUE;
    tray->title = br_strdup(title);
    tray->callback = callback;
    tray->ctx = ctx;
    tray->icon = LoadIcon(NULL, IDI_APPLICATION);

    NOTIFYICONDATAA nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hwnd;
    nid.uID = 100 + index;
    nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = BR_WM_TRAY;
    nid.hIcon = tray->icon;
    strncpy(nid.szTip, title ? title : "BurnRate", sizeof(nid.szTip) - 1);
    Shell_NotifyIconA(NIM_ADD, &nid);
    return index;
}

void br_tray_set_items(int tray_index, const br_tray_item *items, int count) {
    if (tray_index < 0 || tray_index >= g_tray_high || !g_trays[tray_index].used) return;
    tray_state *tray = &g_trays[tray_index];
    if (tray->items) {
        for (int i = 0; i < tray->item_count; i++) free((void *)tray->items[i].label);
        free(tray->items);
    }
    tray->items = NULL;
    tray->item_count = 0;
    if (count > 0) {
        tray->items = (br_tray_item *)calloc(count, sizeof(br_tray_item));
        for (int i = 0; i < count; i++) {
            tray->items[i].label = br_strdup(items[i].label);
            tray->items[i].action_id = items[i].action_id;
            tray->items[i].enabled = items[i].enabled;
        }
        tray->item_count = count;
    }
}

void br_tray_set_title(int tray_index, const char *title) {
    if (tray_index < 0 || tray_index >= g_tray_high || !g_trays[tray_index].used) return;
    free(g_trays[tray_index].title);
    g_trays[tray_index].title = br_strdup(title);
    NOTIFYICONDATAA nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hwnd;
    nid.uID = 100 + tray_index;
    nid.uFlags = NIF_TIP;
    strncpy(nid.szTip, title ? title : "BurnRate", sizeof(nid.szTip) - 1);
    Shell_NotifyIconA(NIM_MODIFY, &nid);
}

void br_tray_remove(int tray_index) {
    if (tray_index < 0 || tray_index >= g_tray_high || !g_trays[tray_index].used) return;
    tray_state *tray = &g_trays[tray_index];
    NOTIFYICONDATAA nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hwnd;
    nid.uID = 100 + tray_index;
    Shell_NotifyIconA(NIM_DELETE, &nid);
    if (tray->items) {
        for (int i = 0; i < tray->item_count; i++) free((void *)tray->items[i].label);
        free(tray->items);
    }
    free(tray->title);
    memset(tray, 0, sizeof(*tray));
}

void br_tray_stop_all(void) {
    for (int i = 0; i < g_tray_high; i++) br_tray_remove(i);
    g_tray_high = 0;
}

void br_notify(const char *title, const char *body) {
    if (g_tray_high <= 0) return;
    NOTIFYICONDATAA nid;
    memset(&nid, 0, sizeof(nid));
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hwnd;
    nid.uID = 100; /* main tray */
    nid.uFlags = NIF_INFO;
    nid.dwInfoFlags = NIIF_INFO;
    strncpy(nid.szInfoTitle, title ? title : "", sizeof(nid.szInfoTitle) - 1);
    strncpy(nid.szInfo, body ? body : "", sizeof(nid.szInfo) - 1);
    Shell_NotifyIconA(NIM_MODIFY, &nid);
}

void br_open_url(const char *url) {
    if (!url) return;
    ShellExecuteA(NULL, "open", url, NULL, NULL, SW_SHOWNORMAL);
}

/* ---- painting ----------------------------------------------------------- */

static void draw_trend(HDC dc, RECT area) {
    int width = area.right - area.left;
    int height = area.bottom - area.top;
    int left = 38, right = 8, top = 8, bottom = 14;
    int w = width - left - right;
    int h = height - top - bottom;
    if (w <= 1 || h <= 1) return;

    for (int p = 0; p <= 100; p += 25) {
        int y = area.top + top + (int)(h * (1 - p / 100.0));
        HPEN pen = CreatePen(PS_SOLID, 1, RGB(200, 200, 200));
        HGDIOBJ old = SelectObject(dc, pen);
        MoveToEx(dc, area.left + left, y, NULL);
        LineTo(dc, area.left + left + w, y);
        SelectObject(dc, old);
        DeleteObject(pen);
        char label[8];
        wsprintfA(label, "%d%%", p);
        TextOutA(dc, area.left + 3, y - 6, label, (int)strlen(label));
    }

    if (!g_trend_points || g_trend_count == 0) return;
    for (int s = 0; s < g_trend_series; s++) {
        COLORREF color = rgb_to_colorref(g_trend_rgb[s * 3], g_trend_rgb[s * 3 + 1], g_trend_rgb[s * 3 + 2]);
        HPEN pen = CreatePen(PS_SOLID, 2, color);
        HGDIOBJ old = SelectObject(dc, pen);
        BOOL started = FALSE;
        for (int i = 0; i < g_trend_count; i++) {
            if (g_trend_points[i].series != s) continue;
            int x = area.left + left + (int)(w * g_trend_points[i].x);
            int y = area.top + top + (int)(h * (1 - g_trend_points[i].y / 100.0));
            if (!started) { MoveToEx(dc, x, y, NULL); started = TRUE; }
            else LineTo(dc, x, y);
        }
        SelectObject(dc, old);
        DeleteObject(pen);
    }
}

static void draw_bars(HDC dc, RECT area) {
    int width = area.right - area.left;
    int height = area.bottom - area.top;
    if (g_bar_count <= 0) return;
    int row = height / g_bar_count;
    int bar_area = (int)(width * 0.6);
    int x0 = area.right - bar_area - 6;
    for (int i = 0; i < g_bar_count; i++) {
        int y = area.top + row * i + (int)(row * 0.2);
        int bh = (int)(row * 0.6);
        double value = g_bar_values[i];
        if (value < 0) value = 0;
        if (value > 1) value = 1;
        int bw = (int)(bar_area * value);
        HBRUSH brush = CreateSolidBrush(rgb_to_colorref(g_bar_rgb[i * 3], g_bar_rgb[i * 3 + 1], g_bar_rgb[i * 3 + 2]));
        RECT bar = { x0, y, x0 + bw, y + bh };
        FillRect(dc, &bar, brush);
        DeleteObject(brush);
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
                TextOutA(dc, area.left + 6, y + (int)(bh * 0.2), buf, (int)strlen(buf));
            }
        }
    }
}

static void draw_daily(HDC dc, RECT area) {
    int width = area.right - area.left;
    int height = area.bottom - area.top;
    if (g_daily_count <= 0 || g_daily_days <= 0) return;
    int left = 38, right = 8, top = 8, bottom = 14;
    int w = width - left - right;
    int h = height - top - bottom;
    if (w <= 1 || h <= 1) return;

    double max_total = 1;
    for (int day = 0; day < g_daily_days; day++) {
        double total = 0;
        for (int i = 0; i < g_daily_count; i++) if (g_daily[i].day == day) total += g_daily[i].value;
        if (total > max_total) max_total = total;
    }
    double column = (double)w / g_daily_days;
    int bar_w = (int)(column * 0.7);
    for (int day = 0; day < g_daily_days; day++) {
        int x = area.left + left + (int)(column * day) + (int)((column - bar_w) / 2);
        int y = area.top + top + h;
        for (int i = 0; i < g_daily_count; i++) {
            if (g_daily[i].day != day) continue;
            int bh = (int)(h * (g_daily[i].value / max_total));
            y -= bh;
            HBRUSH brush = CreateSolidBrush(rgb_to_colorref(g_daily[i].red, g_daily[i].green, g_daily[i].blue));
            RECT bar = { x, y, x + bar_w, y + bh };
            FillRect(dc, &bar, brush);
            DeleteObject(brush);
        }
    }
}

static void paint(HWND hwnd) {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(hwnd, &ps);
    RECT client;
    GetClientRect(hwnd, &client);
    HBRUSH background = CreateSolidBrush(GetSysColor(COLOR_WINDOW));
    FillRect(dc, &client, background);
    DeleteObject(background);
    SetBkMode(dc, TRANSPARENT);

    RECT text_area = { 12, 44, client.right - 12, 44 + 170 };
    char *body = NULL;
    EnterCriticalSection(&g_lock);
    body = g_body ? br_strdup(g_body) : NULL;
    LeaveCriticalSection(&g_lock);
    if (body) {
        DrawTextA(dc, body, -1, &text_area, DT_LEFT | DT_WORDBREAK);
        free(body);
    }

    RECT trend = { 12, 224, client.right - 12, 224 + 200 };
    RECT bars = { 12, 432, client.right - 12, 432 + 190 };
    RECT daily = { 12, 628, client.right - 12, 628 + 160 };
    EnterCriticalSection(&g_lock);
    draw_trend(dc, trend);
    draw_bars(dc, bars);
    draw_daily(dc, daily);
    LeaveCriticalSection(&g_lock);

    EndPaint(hwnd, &ps);
}

/* ---- window ------------------------------------------------------------- */

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_CREATE:
        g_refresh_button = CreateWindowA("BUTTON", "Refresh", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                         12, 8, 90, 28, hwnd, (HMENU)1, NULL, NULL);
        g_quit_button = CreateWindowA("BUTTON", "Quit", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                      110, 8, 90, 28, hwnd, (HMENU)2, NULL, NULL);
        SetTimer(hwnd, BR_TIMER_ID, 300000, NULL);
        return 0;
    case WM_COMMAND:
        if (LOWORD(wparam) == 1 && g_refresh) g_refresh(g_ctx);
        else if (LOWORD(wparam) == 2) PostMessage(hwnd, WM_CLOSE, 0, 0);
        else tray_menu_command((int)LOWORD(wparam));
        return 0;
    case WM_TIMER:
        if (wparam == BR_TIMER_ID && g_refresh) g_refresh(g_ctx);
        return 0;
    case BR_WM_POST: {
        char *text = (char *)lparam;
        EnterCriticalSection(&g_lock);
        free(g_body);
        g_body = text;
        LeaveCriticalSection(&g_lock);
        InvalidateRect(hwnd, NULL, TRUE);
        return 0;
    }
    case BR_WM_TRAY:
        if (lparam == WM_RBUTTONUP || lparam == WM_LBUTTONUP) {
            POINT cursor;
            GetCursorPos(&cursor);
            for (int t = 0; t < g_tray_high; t++) {
                if (!g_trays[t].used) continue;
                HMENU menu = CreatePopupMenu();
                for (int i = 0; i < g_trays[t].item_count; i++) {
                    br_tray_item *item = &g_trays[t].items[i];
                    if (item->action_id == -2) {
                        AppendMenuA(menu, MF_SEPARATOR, 0, NULL);
                    } else {
                        UINT flags = MF_STRING;
                        if (item->action_id < 0 || !item->enabled) flags |= MF_GRAYED;
                        AppendMenuA(menu, flags, (UINT_PTR)i, item->label);
                    }
                }
                SetForegroundWindow(hwnd);
                TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, hwnd, NULL);
                DestroyMenu(menu);
                return 0;
            }
        }
        return 0;
    case WM_PAINT:
        paint(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, BR_TIMER_ID);
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcA(hwnd, message, wparam, lparam);
    }
}

int br_win_run(const char *title, const char *body, br_void_cb on_refresh, void *ctx) {
    InitializeCriticalSection(&g_lock);
    g_refresh = on_refresh;
    g_ctx = ctx;
    g_body = br_strdup(body);

    HINSTANCE instance = GetModuleHandleA(NULL);
    WNDCLASSA wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = instance;
    wc.lpszClassName = "BurnRateWindow";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowA("BurnRateWindow", title ? title : "BurnRate",
                              WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              CW_USEDEFAULT, CW_USEDEFAULT, 720, 840,
                              NULL, NULL, instance, NULL);
    g_hwnd = hwnd;
    if (!hwnd) return 1;

    if (on_refresh) on_refresh(ctx);

    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    return (int)msg.wParam;
}

void br_win_post(const char *body) {
    if (!g_hwnd) return;
    char *copy = br_strdup(body);
    PostMessage(g_hwnd, BR_WM_POST, 0, (LPARAM)copy);
}

void br_win_quit(void) {
    if (g_hwnd) PostMessage(g_hwnd, WM_CLOSE, 0, 0);
}
