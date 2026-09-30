//! BurnRate desktop app (Tauri v2).
//!
//! The shell owns: the tray (main item + per-plan widgets), the window and its
//! panes, settings persistence, and the poll loop. All the logic — menu
//! contents, icon state, alert rules — comes from `burnrate-core`, so this file
//! is the "host decides how to perform an action" half of
//! `StatusItemPresenting`.
//!
//! Two constraints learned the hard way, both on Linux:
//!   - a tray menu cannot be swapped once set, only edited, so the menu is
//!     built once and its items' text is rewritten every poll;
//!   - the items must each have a menu, or the icon does not appear at all.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::image::Image;
use tauri::menu::{Menu, MenuBuilder, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

mod swift_import;

use burnrate_core::alerts::{BurnAlert, CostAlert, Milestone};
use burnrate_core::charts::{axis_label, metric_value, ChartRange, Metric, TrendChartData};
use burnrate_core::dial;
use burnrate_core::formatting::TokenFormat;
use burnrate_core::menu::{StatusMenuAction, StatusMenuBuilder, StatusMenuEntry, StatusMenuModel};
use burnrate_core::model::ProviderUsage;
use burnrate_core::paths::AppPaths;
use burnrate_core::poller::{local_start_of_day, local_utc_offset_seconds};
use burnrate_core::poller::{PollResult, Poller};
use burnrate_core::settings::Settings;
use burnrate_core::usage::{DailyModelUsage, ModelUsageAggregator, ModelUsageEntry};

/// Menu item ids. Fixed strings, because a Linux tray menu cannot be replaced
/// once set — rows are reused and only their text changes.
const ID_DASHBOARD: &str = "open-dashboard";
const ID_CHARTS: &str = "open-charts";
const ID_UPDATE: &str = "check-updates";
const ID_SETTINGS: &str = "open-settings";
const ID_QUIT: &str = "quit";
/// Widget rows are per provider, so their ids are built as `widget-<provider>`.
const ID_WIDGET_PREFIX: &str = "widget-";

/// Shared state: settings, the poller, and the last result.
struct AppState {
    settings: Mutex<Settings>,
    poller: Mutex<Poller>,
    last: Mutex<Option<PollResult>>,
    /// Set while a notification is being delivered, so a burst cannot stack.
    notified: AtomicU64,
    core_version: String,
    /// Providers detected at least once this session.
    ///
    /// A widget is only created for one of these. A configured provider whose CLI
    /// is not installed used to get a menu-bar item that could never show a
    /// figure — the permanently empty "Codex" widget. Tracking what has been
    /// *seen* rather than what is in the latest poll keeps a widget from
    /// disappearing during a transient API failure.
    seen_providers: Mutex<std::collections::BTreeSet<String>>,
}

impl AppState {
    fn settings(&self) -> Settings {
        self.settings.lock().expect("settings lock").clone()
    }

    fn seen_providers(&self) -> std::collections::BTreeSet<String> {
        self.seen_providers.lock().expect("seen lock").clone()
    }

    fn note_providers(&self, usage: &[ProviderUsage]) {
        let mut seen = self.seen_providers.lock().expect("seen lock");
        for provider in usage {
            seen.insert(provider.provider_name.clone());
        }
    }

    fn usage(&self) -> Vec<ProviderUsage> {
        self.last
            .lock()
            .expect("result lock")
            .as_ref()
            .map(|result| result.usage.clone())
            .unwrap_or_default()
    }
}

/// Tray handles kept so every poll can rewrite them in place.
///
/// Only the rows whose *text or enabled state* changes are held. The Settings
/// and Quit rows are owned by the menu itself and are dispatched by id, so
/// keeping a handle to them would be dead weight.
struct TrayHandles<R: tauri::Runtime> {
    /// One item per usage row — a provider header or a window. Swift's menu is
    /// laid out this way; folding them into a single item put every figure on
    /// one line.
    rows: Vec<RowItem<R>>,
    /// The shape the rows were built for, so a rebuild happens only when the
    /// provider or window count actually changes.
    row_kinds: Vec<RowKind>,
    /// Bumped on each rebuild, so row ids never collide.
    generation: u64,
    dashboard: MenuItem<R>,
    charts: MenuItem<R>,
    update: MenuItem<R>,
    main: tauri::tray::TrayIcon<R>,
    /// Per provider: the tray icon plus the widget menu's status row.
    widgets: Vec<WidgetHandles<R>>,
    /// Widget rows the last render asked for, so new ones can be added.
    known_widgets: Vec<String>,
}

struct WidgetHandles<R: tauri::Runtime> {
    provider: String,
    icon: tauri::tray::TrayIcon<R>,
    status: MenuItem<R>,
}

/// What the window shows.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AppPane {
    Usage,
    Notifications,
    Widgets,
    About,
}

/// A chart point in the units the Swift Charts plot used, so the frontend only
/// turns x/y into pixels and never does arithmetic of its own.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Point {
    x: i64,
    y: f64,
}

/// One line on the trend chart.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Series {
    key: String,
    name: String,
    provider: String,
    /// Model-scoped windows (Claude's Fable) draw dashed and faded.
    scoped: bool,
    points: Vec<Point>,
}

/// A gridline or tick label on either axis.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Tick {
    at: i64,
    label: String,
}

/// How the X axis should be labelled, chosen from the *visible* span.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum XAxisStyle {
    /// Hourly marks, striding by `stride_hours`.
    Hourly { stride_hours: i64 },
    /// Midnight (weekday) and noon (12pm) per day.
    Daily,
}

/// One bar in the daily or ranking chart.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Bar {
    /// Which model or provider the colour comes from.
    key: String,
    provider: String,
    label: String,
    value: f64,
    cost: f64,
    /// Token total. The breakdown table shows the four channels below instead,
    /// which is why they travel separately — the first version of that table put
    /// this total in the INPUT column and left the rest as dashes.
    tokens: i64,
    input: i64,
    output: i64,
    /// Cache reads plus cache writes, as `ModelsView` sums them into one column.
    cache: i64,
    reasoning: i64,
    requests: i64,
    /// `axisLabel(value, metric)` — "1.2m", "$12.5". Pre-formatted because the
    /// frontend formatting its own copy is exactly how the axes drifted from the
    /// Swift build the first time round.
    value_text: String,
    /// The ranking chart's trailing annotation: "1.2m tok" or "$12.50".
    annotation: String,
}

/// Everything the Usage pane draws. The Swift layout, section for section:
/// snapshot cards, remaining over time, daily usage by model, top models,
/// breakdown table.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Dashboard {
    range: ChartRange,
    /// `ChartRange.label()` — "24h", "7d", "30d". The card titles read this, and
    /// read `rangeLabel` for two releases before the field existed, so both
    /// charts were titled "Top models (undefined)".
    range_label: String,
    metric: Metric,
    /// `Metric.label()` — "Tokens", "Cost". The titles capitalise these, and
    /// `Metric` itself serialises lowercase, so the chart read "(tokens)".
    metric_label: String,
    window_label: String,
    provider_filter: Option<String>,
    /// Window labels actually present, for the picker.
    window_labels: Vec<String>,
    provider_names: Vec<String>,

    // snapshot cards
    rolling: Vec<Figure>,
    tokens_today: Option<i64>,
    requests_today: i64,
    cost_today: f64,

    // trend
    series: Vec<Series>,
    x_domain: (i64, i64),
    x_style: XAxisStyle,
    x_ticks: Vec<Tick>,
    y_domain: (f64, f64),
    y_ticks: Vec<f64>,

    // daily stacked bars
    daily: Vec<DailyBar>,
    daily_y_ticks: Vec<f64>,
    /// `daily_y_ticks` as `axisLabel` renders them, so the axis needs no
    /// formatting in the frontend.
    daily_y_labels: Vec<String>,
    /// The tallest day, for the daily chart's Y domain.
    daily_maximum: f64,

    /// Whether the 30-day history has any entries for the current filter. The
    /// Swift view branches on `filteredDaily.isEmpty` and shows an
    /// unavailable-view instead of the cards; an empty chart series is not the
    /// same condition, because the trend history outlives the model history.
    has_data: bool,

    // ranking + table
    ranking: Vec<Bar>,
    /// The ranking chart's value axis. Only drawn for the token metric, as in
    /// `ModelsView`, where a dollar axis under eight bars is noise.
    ranking_ticks: Vec<f64>,
    ranking_tick_labels: Vec<String>,
    table: Vec<Bar>,
    /// Models with no entry in the LiteLLM price table. Their COST cell reads
    /// "—" because the figure is genuinely unknown, and saying so is better than
    /// a confident zero — or than a silently empty column.
    unpriced_models: Vec<String>,
}

/// A labelled figure for the snapshot cards.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Figure {
    key: String,
    label: String,
    value: String,
}

/// One day in the stacked chart: its bars and its total.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DailyBar {
    day: i64,
    total: f64,
    total_text: String,
    bars: Vec<Bar>,
    /// Today, or yesterday if the day has not finished: drawn faded, because a
    /// part-day beside complete days reads as a cliff.
    partial: bool,
}

/// The full state the frontend renders from, in one payload.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    pane: AppPane,
    settings: Settings,
    usage: Vec<ProviderUsage>,
    missing: Vec<String>,
    /// Percent remaining for the icon severity, from the Rolling windows.
    remaining: Option<f64>,
    app_version: String,
    core_version: String,
    last_poll_unix: u64,
    poll_count: u64,
    platforms: PlatformInfo,
    dashboard: Dashboard,
    spend_today: std::collections::HashMap<String, f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlatformInfo {
    os: &'static str,
    /// Linux needs WebKitGTK / libayatana at runtime; say so up front.
    runtime_dependencies: Vec<&'static str>,
}

fn platform_info() -> PlatformInfo {
    let (os, deps): (&'static str, Vec<&'static str>) = if cfg!(target_os = "macos") {
        ("macOS", vec![])
    } else if cfg!(target_os = "windows") {
        ("Windows", vec!["WebView2 (preinstalled on Windows 11)"])
    } else {
        (
            "Linux",
            vec!["libwebkit2gtk-4.1-0", "libayatana-appindicator3-1"],
        )
    };
    PlatformInfo {
        os,
        runtime_dependencies: deps,
    }
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The tray glyph as raw RGBA — Tauri wants pixels, not a PNG.
fn tray_image(remaining: Option<f64>, edge: u32) -> Image<'static> {
    let canvas = dial::menu_bar_image(remaining, edge);
    Image::new_owned(canvas.pixels, edge, edge)
}

fn widget_id(provider: &str) -> String {
    format!("{ID_WIDGET_PREFIX}{provider}")
}

/// A menu item paired with the id the event handler dispatches on.
/// The kind of a usage row, so a menu rebuild can be limited to the polls where
/// the *shape* changed rather than every poll.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum RowKind {
    Header,
    Window,
    Text,
    Separator,
}

/// A row of the usage block: either a text row or a separator.
enum RowItem<R: tauri::Runtime> {
    Text(MenuItem<R>),
    /// Held so the separator outlives the builder; the field is not read.
    Separator(#[allow(dead_code)] PredefinedMenuItem<R>),
}

/// The rows the usage block should contain, in order.
///
/// Swift renders each provider header and each window as its **own** `NSMenuItem`
/// (`menu.addItem(NSMenuItem(title: "  \(label): \(detail)"))`). This used to
/// fold the whole block into one item's text with embedded newlines, which macOS
/// does not render as lines — so every provider and window arrived on a single
/// line.
fn row_plan(model: &StatusMenuModel) -> Vec<(RowKind, String)> {
    model
        .entries
        .iter()
        .filter_map(|entry| match entry {
            StatusMenuEntry::ProviderHeader { title } => Some((RowKind::Header, title.clone())),
            // The two leading spaces are Swift's, and are what indents a window
            // row under its provider.
            StatusMenuEntry::WindowRow { label, detail } => {
                Some((RowKind::Window, format!("  {label}: {detail}")))
            }
            StatusMenuEntry::Text { text } => Some((RowKind::Text, text.clone())),
            StatusMenuEntry::Separator => Some((RowKind::Separator, String::new())),
            StatusMenuEntry::Action { .. } => None,
        })
        .collect()
}

/// A built menu with the handles the next render needs.
struct BuiltMenu<R: tauri::Runtime> {
    menu: Menu<R>,
    rows: Vec<RowItem<R>>,
    dashboard: MenuItem<R>,
    charts: MenuItem<R>,
    update: MenuItem<R>,
}

/// Builds the menu for a given row plan.
fn build_menu<R: tauri::Runtime>(
    app: &AppHandle<R>,
    plan: &[(RowKind, String)],
    generation: u64,
) -> tauri::Result<BuiltMenu<R>> {
    let dashboard = MenuItem::with_id(app, ID_DASHBOARD, "Usage Dashboard…", true, None::<&str>)?;
    let charts = MenuItem::with_id(app, ID_CHARTS, "Charts…", true, None::<&str>)?;
    let update = MenuItem::with_id(app, ID_UPDATE, "Check for Updates…", true, None::<&str>)?;
    let settings_item = MenuItem::with_id(app, ID_SETTINGS, "Settings…", true, None::<&str>)?;
    // A plain item, not PredefinedMenuItem::quit: on Linux the predefined Quit
    // reports itself disabled through DBusMenu, so the row is greyed out and
    // never dispatches — the app becomes unquittable from its own menu.
    let quit = MenuItem::with_id(app, ID_QUIT, "Quit", true, None::<&str>)?;

    // Row ids are namespaced by generation: the old menu is discarded on a
    // rebuild but its ids may still be registered.
    let mut rows: Vec<RowItem<R>> = Vec::with_capacity(plan.len());
    let mut builder = MenuBuilder::new(app);
    for (index, (kind, text)) in plan.iter().enumerate() {
        match kind {
            RowKind::Separator => {
                let separator = PredefinedMenuItem::separator(app)?;
                builder = builder.item(&separator);
                rows.push(RowItem::Separator(separator));
            }
            _ => {
                let item = MenuItem::with_id(
                    app,
                    format!("row-{generation}-{index}"),
                    text.as_str(),
                    false,
                    None::<&str>,
                )?;
                builder = builder.item(&item);
                rows.push(RowItem::Text(item));
            }
        }
    }
    let menu = builder
        .separator()
        .item(&dashboard)
        .item(&charts)
        .item(&update)
        .separator()
        .item(&settings_item)
        .item(&quit)
        .build()?;
    Ok(BuiltMenu {
        menu,
        rows,
        dashboard,
        charts,
        update,
    })
}

fn install_trays(app: &AppHandle<Wry>) -> tauri::Result<TrayHandles<Wry>> {
    // The menu starts with no usage rows: the first poll fills them in and the
    // shape is rebuilt then. One "Loading usage…" row stands in until it arrives,
    // which is what the Swift menu shows too.
    let plan = vec![(RowKind::Text, "Loading usage…".to_string())];
    let BuiltMenu {
        menu,
        rows,
        dashboard,
        charts,
        update,
    } = build_menu(app, &plan, 0)?;
    let main = TrayIconBuilder::with_id("main")
        .icon(tray_image(None, 22))
        .icon_as_template(true)
        .tooltip("BurnRate")
        .menu(&menu)
        .build(app)?;

    Ok(TrayHandles {
        rows,
        row_kinds: plan.iter().map(|(kind, _)| *kind).collect(),
        generation: 0,
        dashboard,
        charts,
        update,
        main,
        widgets: Vec::new(),
        known_widgets: Vec::new(),
    })
}

fn install_widget(app: &AppHandle<Wry>, provider: &str) -> tauri::Result<WidgetHandles<Wry>> {
    let status = MenuItem::with_id(
        app,
        format!("{ID_WIDGET_PREFIX}{provider}-status"),
        provider,
        false,
        None::<&str>,
    )?;
    let remove = MenuItem::with_id(
        app,
        format!("{ID_WIDGET_PREFIX}{provider}-remove"),
        "Remove widget",
        true,
        None::<&str>,
    )?;
    let menu = MenuBuilder::new(app)
        .item(&status)
        .separator()
        .item(&remove)
        .build()?;
    let icon = TrayIconBuilder::with_id(widget_id(provider))
        .icon(tray_image(None, 22))
        .icon_as_template(true)
        .title(provider)
        .tooltip(provider)
        .menu(&menu)
        .build(app)?;
    Ok(WidgetHandles {
        provider: provider.to_string(),
        icon,
        status,
    })
}

/// Renders one poll's worth of state onto the tray, in place.
fn render_tray(app: &AppHandle<Wry>) -> tauri::Result<()> {
    let app_state = app.state::<Arc<AppState>>();
    let tray_state = app.state::<Mutex<TrayHandles<Wry>>>();
    let mut handles = tray_state.lock().expect("tray lock");

    let settings = app_state.settings();
    let usage = app_state.usage();
    let remaining = StatusMenuBuilder::worst_rolling_remaining(&usage);
    let now = now_unix() as i64;

    // The icon carries the severity, so it is redrawn on every poll.
    handles.main.set_icon(Some(tray_image(remaining, 22))).ok();

    let model = StatusMenuBuilder::main_menu(&usage, None, false, settings.includes_charts, now);
    let plan = row_plan(&model);
    let kinds: Vec<RowKind> = plan.iter().map(|(kind, _)| *kind).collect();

    // Rebuild only when the shape changes — a provider appearing, or a window
    // count moving. On Linux a tray menu cannot be replaced once set, so this is
    // a no-op there and the text rewrite below is what carries the update.
    if kinds != handles.row_kinds {
        let generation = handles.generation + 1;
        match build_menu(app, &plan, generation) {
            Ok(built) => {
                if handles.main.set_menu(Some(built.menu)).is_ok() {
                    handles.rows = built.rows;
                    handles.row_kinds = kinds;
                    handles.generation = generation;
                    handles.dashboard = built.dashboard;
                    handles.charts = built.charts;
                    handles.update = built.update;
                }
            }
            Err(error) => eprintln!("burnrate: menu rebuild failed: {error}"),
        }
    }

    // Text is rewritten every poll: the figures change, the shape does not.
    for (item, (_, text)) in handles.rows.iter_mut().zip(plan.iter()) {
        if let RowItem::Text(item) = item {
            let _ = item.set_text(text);
        }
    }
    let _ = handles.dashboard.set_enabled(true);
    let has_charts = model.entries.iter().any(|entry| {
        matches!(
            entry,
            StatusMenuEntry::Action {
                action: StatusMenuAction::OpenCharts,
                ..
            }
        )
    });
    let _ = handles.charts.set_enabled(has_charts);
    let _ = handles.update.set_enabled(true);

    // Widgets: only for providers this app has actually detected. A configured
    // provider whose CLI is not installed used to get a menu-bar item that could
    // never show a figure — a permanently empty "Codex" widget.
    let detected = app_state.seen_providers();
    for provider in &settings.widget_providers {
        if !detected.contains(provider) {
            continue;
        }
        if handles.known_widgets.iter().any(|name| name == provider) {
            continue;
        }
        match install_widget(app, provider) {
            Ok(widget) => {
                handles.widgets.push(widget);
                handles.known_widgets.push(provider.clone());
            }
            Err(error) => eprintln!("burnrate: widget {provider} failed: {error}"),
        }
    }
    handles
        .widgets
        .retain(|widget| settings.widget_providers.contains(&widget.provider));

    let mut alive = Vec::new();
    for widget in &handles.widgets {
        let provider_usage = usage.iter().find(|u| u.provider_name == widget.provider);
        let widget_model = StatusMenuBuilder::widget(&widget.provider, provider_usage, now);
        if let Some(entry) = widget_model
            .menu
            .entries
            .iter()
            .find_map(|entry| match entry {
                StatusMenuEntry::WindowRow { label, detail } => Some(format!("{label}: {detail}")),
                _ => None,
            })
        {
            let _ = widget.status.set_text(entry);
        }
        let _ = widget.icon.set_title(Some(widget_model.title.clone()));
        alive.push(widget.provider.clone());
    }
    handles.known_widgets = alive;
    Ok(())
}

// MARK: - Commands

/// Everything the window renders, in one call. All chart arithmetic happens
/// here and in `burnrate_core::charts`, so the axes cannot drift from the Swift
/// build's.
#[tauri::command]
fn snapshot(
    app: AppHandle<Wry>,
    pane: Option<AppPane>,
    range: Option<String>,
    metric: Option<String>,
    window_label: Option<String>,
    provider_filter: Option<String>,
) -> Snapshot {
    let state = app.state::<Arc<AppState>>();
    let last = state.last.lock().expect("result lock").clone();
    let usage = last
        .as_ref()
        .map(|result| result.usage.clone())
        .unwrap_or_default();
    let missing = last
        .as_ref()
        .map(|result| result.missing.clone())
        .unwrap_or_default();
    let remaining = StatusMenuBuilder::worst_rolling_remaining(&usage);
    let poller = state.poller.lock().expect("poller lock");

    let now = now_unix() as i64;
    let offset = local_utc_offset_seconds();
    let range = range
        .as_deref()
        .and_then(ChartRange::from_label)
        .unwrap_or(ChartRange::Week);
    let metric = match metric.as_deref() {
        Some("cost") => Metric::Cost,
        _ => Metric::Tokens,
    };

    // --- trend ------------------------------------------------------------
    let history = poller.remaining_history().to_vec();
    let cutoff = TrendChartData::trend_cutoff(range, now);
    // Claude's model-scoped weekly folds into Weekly, so the picker offers
    // whichever canonical labels the visible data actually contains, in
    // canonical order (Rolling, Weekly, Monthly) — not alphabetical.
    let window_labels: Vec<String> =
        TrendChartData::trend_labels(&history, provider_filter.as_deref(), cutoff);
    let requested = window_label.unwrap_or_else(|| "Rolling".to_string());
    let window_label = if window_labels.contains(&requested) {
        requested
    } else {
        window_labels.first().cloned().unwrap_or(requested)
    };

    let built = TrendChartData::build_trend_series(
        &history,
        &window_label,
        provider_filter.as_deref(),
        cutoff,
    );
    let series: Vec<Series> = built
        .iter()
        .map(|line| Series {
            key: line.key.clone(),
            name: line.name.clone(),
            provider: line.provider.clone(),
            scoped: line.scoped,
            points: line
                .samples
                .iter()
                .map(|(x, y)| Point { x: *x, y: *y })
                .collect(),
        })
        .collect();

    let (x_low, x_high) = TrendChartData::trend_x_domain(&built, cutoff, now);
    let span = x_high - x_low;
    let (x_style, x_ticks) = if TrendChartData::trend_x_hourly(span) {
        // Hourly marks, snapped to the hour so the grid is regular.
        let stride = TrendChartData::trend_hour_stride(span) * 3600;
        let first = x_low.div_euclid(3600) * 3600;
        let mut ticks = Vec::new();
        let mut at = first;
        while at <= x_high {
            if at >= x_low {
                ticks.push(Tick {
                    at,
                    label: hour_label(at, offset),
                });
            }
            at += stride;
        }
        (
            XAxisStyle::Hourly {
                stride_hours: stride / 3600,
            },
            ticks,
        )
    } else {
        let ticks = TrendChartData::trend_tick_dates(x_low, x_high, offset)
            .into_iter()
            .map(|at| Tick {
                at,
                label: TrendChartData::trend_tick_label(at, offset),
            })
            .collect();
        (XAxisStyle::Daily, ticks)
    };

    let y_domain = TrendChartData::remaining_domain(&built);
    let y_ticks = TrendChartData::y_ticks(y_domain);

    // --- daily and ranking, scoped to the selected range --------------------
    let daily_all = last
        .as_ref()
        .map(|result| result.model_daily.clone())
        .unwrap_or_default();
    let daily_start = now - range.span_seconds();
    // Each slot is computed with the offset in effect **on that day**, not with
    // today's. New Zealand moved from +12 to +13 on 27 September, so building
    // every slot with the current offset put each earlier slot an hour off —
    // matching no stored bucket at all. The chart showed four days of bars and
    // five empty slots, which is the "quite bare" graph with no usage before the
    // 26th.
    let today_start = local_start_of_day(now);
    // A slot per calendar day in the range, up to and including today.
    //
    // The first version emitted only the days that had data. That made the axis
    // index-based, so a day with no samples silently closed up and looked
    // identical to a day that was fully spent, and the last slot was whatever
    // partial day the poll happened to land in. Both read as artifacting on the
    // right-hand end of the chart. Days are calendar slots now, gaps are gaps,
    // and today is flagged so the renderer can fade it.
    let by_day: HashMap<i64, &DailyModelUsage> =
        daily_all.iter().map(|day| (day.day, day)).collect();
    let mut daily: Vec<DailyBar> = Vec::new();
    for cursor in daily_slots(daily_start, now, &local_start_of_day) {
        let bars: Vec<Bar> = by_day
            .get(&cursor)
            .map(|day| {
                day.entries
                    .iter()
                    .filter(|entry| {
                        provider_filter
                            .as_deref()
                            .map(|filter| entry.provider == filter)
                            .unwrap_or(true)
                    })
                    .map(|entry| bar_for(entry, metric))
                    .collect()
            })
            .unwrap_or_default();
        let total = bars.iter().map(|bar| bar.value).sum();
        daily.push(DailyBar {
            day: cursor,
            total,
            total_text: axis_label(total, metric),
            bars,
            partial: cursor == today_start,
        });
    }
    let daily_max = daily.iter().map(|day| day.total).fold(0.0_f64, f64::max);
    let daily_ticks = nice_ticks(0.0, daily_max);
    let daily_y_labels: Vec<String> = daily_ticks
        .iter()
        .map(|value| axis_label(*value, metric))
        .collect();

    // Whether there is anything at all for this filter over the full 30 days —
    // the Swift view's `filteredDaily.isEmpty` check.
    let has_data = daily_all.iter().any(|day| {
        day.entries.iter().any(|entry| {
            provider_filter
                .as_deref()
                .is_none_or(|f| entry.provider == f)
        })
    });

    // Totals are aggregated from the in-range buckets, not the full 30 days:
    // otherwise a narrow range would list models it is not showing.
    let in_range: Vec<DailyModelUsage> = daily_all
        .iter()
        .filter(|day| day.day >= daily_start)
        .cloned()
        .collect();
    let mut totals = ModelUsageAggregator::totals_from_daily(&in_range);
    if let Some(filter) = provider_filter.as_deref() {
        totals.retain(|entry| entry.provider == filter);
    }
    let table: Vec<Bar> = totals.iter().map(|entry| bar_for(entry, metric)).collect();
    let ranking: Vec<Bar> = table.iter().take(8).cloned().collect();
    // The ranking's value axis, from the same nice-number rule as the daily
    // chart, and empty for cost (as Swift draws it).
    let ranking_max = ranking.iter().map(|bar| bar.value).fold(0.0_f64, f64::max);
    let ranking_ticks = if metric == Metric::Tokens {
        nice_ticks(0.0, ranking_max)
    } else {
        Vec::new()
    };
    let ranking_tick_labels: Vec<String> = ranking_ticks
        .iter()
        .map(|value| axis_label(*value, metric))
        .collect();

    // --- snapshot cards ---------------------------------------------------
    remember_models(&totals);

    let rolling: Vec<Figure> = TrendChartData::latest_rolling(&history, provider_filter.as_deref())
        .into_iter()
        .map(|(provider, percent)| Figure {
            key: provider.clone(),
            label: provider,
            value: format!("{percent:.0}%"),
        })
        .collect();

    let today_entries: Vec<&ModelUsageEntry> = daily_all
        .iter()
        .find(|day| day.day == today_start)
        .map(|day| day.entries.iter().collect())
        .unwrap_or_default();
    let tokens_today: i64 = today_entries.iter().map(|entry| entry.total_tokens()).sum();
    let requests_today: i64 = today_entries.iter().map(|entry| entry.requests).sum();
    let cost_today: f64 = today_entries.iter().map(|entry| entry.cost).sum();

    // Models the price table could not resolve, so the breakdown can say why a
    // cost is missing instead of leaving a column of dashes unexplained.
    //
    // Reuses the poller guard opened at the top of this function. Taking the lock
    // again here is a self-deadlock — `std::sync::Mutex` is not reentrant, and
    // `snapshot` runs on the main thread, so the whole app hangs rather than just
    // this command. The Linux tray smoke test caught it: with the main thread
    // blocked, the D-Bus property call stopped answering.
    let unpriced_models: Vec<String> = poller.pricing_state().1;

    let provider_names: Vec<String> = {
        let mut names: Vec<String> = totals.iter().map(|entry| entry.provider.clone()).collect();
        names.sort();
        names.dedup();
        names
    };

    Snapshot {
        pane: pane.unwrap_or(AppPane::Usage),
        settings: state.settings(),
        usage,
        missing,
        remaining,
        app_version: app.package_info().version.to_string(),
        core_version: state.core_version.clone(),
        last_poll_unix: last.as_ref().map(|result| result.at as u64).unwrap_or(0),
        poll_count: poller.poll_count(),
        platforms: platform_info(),
        dashboard: Dashboard {
            range,
            range_label: range.label().to_string(),
            metric,
            metric_label: metric.label().to_string(),
            window_label,
            provider_filter: provider_filter.clone(),
            window_labels,
            provider_names,
            rolling,
            tokens_today: (tokens_today > 0).then_some(tokens_today),
            requests_today,
            cost_today,
            series,
            x_domain: (x_low, x_high),
            x_style,
            x_ticks,
            y_domain,
            y_ticks,
            daily,
            daily_y_ticks: daily_ticks,
            daily_y_labels,
            daily_maximum: daily_max,
            has_data,
            ranking,
            ranking_ticks,
            ranking_tick_labels,
            table,
            unpriced_models,
        },
        spend_today: last
            .as_ref()
            .map(|result| result.spend_today.clone())
            .unwrap_or_default(),
    }
}

/// Recorded so `model_colours` can return the palette for every model on screen.
///
/// A process-wide lock, not a `thread_local`: `snapshot` fills this and
/// `model_colours` reads it, and those are two separate commands with no promise
/// of landing on the same thread. It works today only because both happen to be
/// dispatched on the main thread — a change to either would silently strip every
/// chart of its model colours.
fn remember_models(entries: &[ModelUsageEntry]) {
    let mut models = MODELS_SEEN.lock().expect("models lock");
    models.clear();
    models.extend(entries.iter().map(|entry| entry.display_name()));
}

fn bar_for(entry: &ModelUsageEntry, metric: Metric) -> Bar {
    let value = metric_value(metric, entry.total_tokens(), entry.cost);
    Bar {
        key: entry.display_name(),
        provider: entry.provider.clone(),
        label: entry.display_name(),
        value,
        cost: entry.cost,
        tokens: entry.total_tokens(),
        input: entry.tokens.input,
        output: entry.tokens.output,
        cache: entry.tokens.cache_read + entry.tokens.cache_write,
        reasoning: entry.tokens.reasoning,
        requests: entry.requests,
        value_text: axis_label(value, metric),
        // Matches `ModelUsageEntry.annotation(_:)`: tokens carry a " tok" unit,
        // cost is bare dollars to the cent. The unit is not decoration — the bar
        // is unlabelled by an axis on the cost metric, so "$12.50" alone has to
        // say what it is.
        annotation: match metric {
            Metric::Tokens => format!("{} tok", TokenFormat::format(entry.total_tokens())),
            Metric::Cost => format!("${:.2}", entry.cost),
        },
    }
}

/// One epoch per local calendar day from `daily_start` to `now`, inclusive.
///
/// Each slot is that day's local midnight, which is the same value the day
/// buckets are keyed by — using today's offset for every slot is what left the
/// chart with four bars and five empty slots, because New Zealand moved from +12
/// to +13 on 27 September and every earlier slot was an hour off.
///
/// The walk steps to the *following noon* before asking for a midnight. A local
/// day is 23 or 25 hours across a daylight-saving change, so stepping by a fixed
/// 86,400 is ambiguous; aiming at noon is twelve hours from either midnight and
/// cannot land in a neighbouring day or repeat one.
///
/// `day_start` is a parameter rather than a direct call so a transition can be
/// tested without depending on the machine's timezone.
fn daily_slots(daily_start: i64, now: i64, day_start: &dyn Fn(i64) -> i64) -> Vec<i64> {
    let today_start = day_start(now);
    let mut slots = Vec::new();
    let mut probe = day_start(daily_start);
    loop {
        let day = day_start(probe);
        if day > today_start {
            break;
        }
        slots.push(day);
        probe = day + 86_400 + 43_200;
    }
    slots
}

/// Gridlines for a token or cost axis, at "nice" magnitudes.
///
/// This was a ladder of fixed steps (500k, 50k, 5k, …) chosen by span. It reads
/// like it scales, but every branch is a *small* number, so a large span landed
/// on 500k and produced a tick every 500k — 7,306 gridlines and labels on a real
/// 3.65e9 day, 176 on a 8.8e7 one. Thousands of SVG nodes, which is why the
/// chart looked cooked rather than merely dense.
///
/// Steps now scale with the span: 1, 2 or 5 times a power of ten, sized to land
/// on roughly five gridlines whatever the magnitude.
fn nice_ticks(low: f64, high: f64) -> Vec<f64> {
    const TARGET_TICKS: f64 = 5.0;
    if !high.is_finite() || !low.is_finite() || high <= low {
        return vec![low];
    }
    let span = high - low;
    let raw = span / TARGET_TICKS;
    let magnitude = 10f64.powf(raw.log10().floor());
    let normalised = raw / magnitude;
    // 1, 2, 5, 10 — the "nice" multipliers, so labels read 1e9 / 2e9 rather
    // than 1.37e9.
    let step = magnitude
        * if normalised <= 1.0 {
            1.0
        } else if normalised <= 2.0 {
            2.0
        } else if normalised <= 5.0 {
            5.0
        } else {
            10.0
        };
    if step <= 0.0 || !step.is_finite() {
        return vec![low];
    }
    let mut ticks = Vec::new();
    let mut value = (low / step).ceil() * step;
    // A cap as a backstop: the step is derived from the span, so this cannot
    // trip, but a degenerate input should draw nothing rather than hang.
    while value <= high && ticks.len() < 64 {
        ticks.push(value);
        value += step;
    }
    ticks
}

/// "14:00" in the machine's local time.
fn hour_label(at: i64, offset: i64) -> String {
    let local = at + offset;
    let minutes = (local.rem_euclid(3600)) / 60;
    let hour = (local.div_euclid(3600)) % 24;
    format!("{hour:02}:{minutes:02}")
}

#[tauri::command]
fn save_settings(app: AppHandle<Wry>, settings: Settings) -> Result<Settings, String> {
    let state = app.state::<Arc<AppState>>();
    let settings = settings.normalised();
    let paths = AppPaths::detect();
    paths.ensure_app_directory().map_err(|error| {
        format!(
            "could not create {}: {error}",
            paths.app_directory().display()
        )
    })?;
    settings
        .save(&paths.settings_file())
        .map_err(|error| format!("could not save settings: {error}"))?;
    *state.settings.lock().expect("settings lock") = settings.clone();
    render_tray(&app).ok();
    Ok(settings)
}

/// The app icon as a `data:` URL, rendered from the same geometry the
/// bundler uses. The window cannot use a relative path: the icons ship in
/// `src-tauri/icons`, outside the served `ui/app`.
#[tauri::command]
fn app_icon_data_url(edge: Option<u32>) -> String {
    dial::app_icon(edge.unwrap_or(128)).to_data_url()
}

/// The model palette, so every platform colours a model the same way. The
/// Swift build hashed with `hashValue`, which is seeded per process, so its
/// colours changed between launches; this is a fixed FNV-1a and is stable.
#[tauri::command]
fn model_colours() -> std::collections::BTreeMap<String, String> {
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for entry in state_snapshot_entries() {
        seen.insert(entry);
    }
    seen.into_iter()
        .map(|model| {
            let (red, green, blue) = burnrate_core::charts::colour_for_model(&model);
            (model, format!("rgb({red}, {green}, {blue})"))
        })
        .collect()
}

/// Model names the app has seen, so the palette can be returned for all of them.
fn state_snapshot_entries() -> Vec<String> {
    MODELS_SEEN.lock().expect("models lock").clone()
}

/// Model names seen in the last snapshot, filled in by `snapshot`.
static MODELS_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Delivers a test banner and reports whether the platform accepted it. Used to
/// confirm notification permission, which is otherwise invisible until a real
/// milestone fires.
#[tauri::command]
fn send_test_notification(app: AppHandle<Wry>) -> Result<(), String> {
    use tauri_plugin_notification::NotificationExt;
    app.notification()
        .builder()
        .title("BurnRate test")
        .body("If you can read this, notifications are working.")
        .show()
        .map_err(|error| error.to_string())
}

/// Forces an immediate poll, skipping the throttle — the tray's Refresh.
#[tauri::command]
fn refresh_now(app: AppHandle<Wry>) {
    {
        let state = app.state::<Arc<AppState>>();
        let mut poller = state.poller.lock().expect("poller lock");
        poller.invalidate_caches();
    }
    poll_once(&app);
}

#[tauri::command]
fn settings_file_path() -> String {
    AppPaths::detect().settings_file().display().to_string()
}

#[tauri::command]
fn upsert_milestone(
    app: AppHandle<Wry>,
    provider: String,
    window_label: String,
    step: f64,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.upsert_milestone(Milestone::new(&provider, &window_label, step));
    save_settings(app, settings)
}

#[tauri::command]
fn remove_milestone(
    app: AppHandle<Wry>,
    provider: String,
    window_label: String,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.remove_milestone(&provider, &window_label);
    save_settings(app, settings)
}

#[tauri::command]
fn upsert_burn_alert(
    app: AppHandle<Wry>,
    provider: String,
    window_label: String,
    percent_drop: f64,
    minutes: i64,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.upsert_burn_alert(BurnAlert::new(
        &provider,
        &window_label,
        percent_drop,
        minutes,
    ));
    save_settings(app, settings)
}

#[tauri::command]
fn remove_burn_alert(
    app: AppHandle<Wry>,
    provider: String,
    window_label: String,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.remove_burn_alert(&provider, &window_label);
    save_settings(app, settings)
}

#[tauri::command]
fn upsert_cost_alert(
    app: AppHandle<Wry>,
    provider: String,
    daily_limit_usd: f64,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings
        .cost_alerts
        .retain(|alert| alert.provider != provider);
    if daily_limit_usd > 0.0 {
        settings
            .cost_alerts
            .push(CostAlert::new(&provider, daily_limit_usd));
    }
    save_settings(app, settings)
}

#[tauri::command]
fn toggle_widget(app: AppHandle<Wry>, provider: String) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.toggle_widget(&provider);
    save_settings(app, settings)
}

#[tauri::command]
fn set_poll_interval(app: AppHandle<Wry>, seconds: u64) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.poll_interval_seconds = seconds.clamp(30, 3600);
    save_settings(app, settings)
}

#[tauri::command]
fn set_notify_on_reset(app: AppHandle<Wry>, enabled: bool) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.notify_on_reset = enabled;
    save_settings(app, settings)
}

/// Providers the tray already knows about, for the widget toggles.
#[tauri::command]
fn known_providers(app: AppHandle<Wry>) -> Vec<String> {
    let state = app.state::<Arc<AppState>>();
    // Providers this app has detected, not every provider it could support: the
    // widgets pane offered a Codex toggle to someone with no Codex credentials,
    // and the tray then showed an empty "Codex" item.
    let mut names: Vec<String> = state.seen_providers().into_iter().collect();
    for alert in &state.settings().milestones {
        if !names.contains(&alert.provider) {
            names.push(alert.provider.clone());
        }
    }
    names.sort();
    names.dedup();
    names
}

#[tauri::command]
fn open_window(app: AppHandle<Wry>, pane: Option<AppPane>) {
    let label = match pane.unwrap_or(AppPane::Usage) {
        AppPane::Usage => "usage",
        AppPane::Notifications => "notifications",
        AppPane::Widgets => "widgets",
        AppPane::About => "about",
    };
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        let _ = window.emit_to("main", "navigate", label);
    }
}

/// Runs one poll on the UI thread, stores the result, redraws the tray and
/// delivers any notifications the notifier decided on.
fn poll_once(app: &AppHandle<Wry>) {
    let state = app.state::<Arc<AppState>>();
    let settings = state.settings();
    let result = {
        let mut poller = state.poller.lock().expect("poller lock");
        let result = poller.poll(&settings);
        // Persist the trend history with each poll, as the Swift build does, so
        // the chart has data immediately on the next launch rather than after
        // hours of polling.
        poller.save_history();
        poller.save_model_history();
        result
    };
    state.note_providers(&result.usage);
    let notifications = result.notifications.clone();
    let providers = result.usage.len();
    let missing = result.missing.len();
    *state.last.lock().expect("result lock") = Some(result);
    render_tray(app).ok();
    eprintln!(
        "burnrate: poll #{providers} providers, {missing} unexplained, \
         {} widget(s), {} notification(s)",
        app.state::<Mutex<TrayHandles<Wry>>>()
            .lock()
            .expect("tray lock")
            .widgets
            .len(),
        notifications.len()
    );
    if !notifications.is_empty() {
        deliver(app, &notifications);
    }
}

/// Delivers notifications natively. The plugin is a no-op where the platform
/// refuses permission, so a failure is logged rather than fatal: usage figures
/// matter more than banners.
fn deliver(app: &AppHandle<Wry>, notifications: &[burnrate_core::notifier::Notification]) {
    use tauri_plugin_notification::NotificationExt;
    for notification in notifications {
        let delivered = app
            .notification()
            .builder()
            .title(&notification.title)
            .body(&notification.body)
            .show();
        if let Err(error) = delivered {
            eprintln!(
                "burnrate: notification failed ({error}): {}",
                notification.title
            );
        }
    }
    let state = app.state::<Arc<AppState>>();
    state
        .notified
        .fetch_add(notifications.len() as u64, Ordering::Relaxed);
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .manage(Arc::new(AppState {
            settings: Mutex::new(Settings::default()),
            poller: Mutex::new(Poller::new()),
            last: Mutex::new(None),
            notified: AtomicU64::new(0),
            core_version: burnrate_core::VERSION.to_string(),
            seen_providers: Mutex::new(std::collections::BTreeSet::new()),
        }))
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // BurnRate lives in the menu bar. Closing the dashboard window
                // used to quit the app and take the tray icon with it; the window
                // is hidden instead and the tray keeps polling.
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .setup(|app| {
            // A menu-bar app has no Dock icon, as the Swift build's LSUIElement
            // gives it. Without this the app shows up in the Dock and the app
            // switcher while it is only a tray icon.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let handle = app.handle().clone();
            let handles = install_trays(&handle)?;
            eprintln!(
                "burnrate: tray installed ({} item(s))",
                1 + handles.widgets.len()
            );
            app.manage(Mutex::new(handles));

            // Reload the persisted trend history before the first poll, so the
            // chart has a line on launch instead of only a "collecting" hint.
            // On a fresh install this is also where the Swift app's history is
            // imported from `UserDefaults`, once.
            {
                let state = handle.state::<Arc<AppState>>();
                let mut poller = state.poller.lock().expect("poller lock");
                let now = burnrate_core::poller::now_unix();
                poller.load_history(now);
                poller.load_model_history(now);
                if let Some(summary) =
                    swift_import::import_swift_history_if_needed(&mut poller, now)
                {
                    eprintln!("burnrate: {summary}");
                }
                eprintln!(
                    "burnrate: trend history {} sample(s), {} day(s) of model history",
                    poller.remaining_history().len(),
                    poller.model_history_len()
                );
            }

            // Settings from disk, or defaults; a bad file must not stop launch.
            let paths = AppPaths::detect();
            let settings_path = paths.settings_file();
            let existed = settings_path.exists();
            match Settings::load(&settings_path) {
                Ok(settings) => {
                    eprintln!(
                        "burnrate: settings {}",
                        if existed {
                            format!("loaded from {}", settings_path.display())
                        } else {
                            format!("not found at {}, using defaults", settings_path.display())
                        }
                    );
                    *handle
                        .state::<Arc<AppState>>()
                        .settings
                        .lock()
                        .expect("lock") = settings;
                }
                Err(error) => {
                    // A corrupt file must not stop launch, but it must be
                    // visible: silently replacing someone's settings is worse
                    // than starting with none.
                    eprintln!(
                        "burnrate: settings unreadable ({}): {error}",
                        settings_path.display()
                    );
                }
            }

            // The cached price table is a local file read, and it has to be in
            // place *before* the first poll: Claude's logs report no cost, so
            // without it the first poll prices nothing and every Claude row reads
            // "—" until the next one. Only the network refresh is backgrounded.
            {
                let state = handle.state::<Arc<AppState>>();
                let mut poller = state.poller.lock().expect("poller lock");
                poller.load_pricing_cache();
                let (prices, unpriced) = poller.pricing_state();
                eprintln!("burnrate: pricing table {prices} entries");
                if !unpriced.is_empty() {
                    eprintln!("burnrate: no list price for {}", unpriced.join(", "));
                }
            }

            // Fetch a fresh table in the background: a failure here is not fatal,
            // the cache above is still in use.
            {
                let state = handle.state::<Arc<AppState>>().inner().clone();
                std::thread::spawn(move || {
                    let mut poller = state.poller.lock().expect("poller lock");
                    poller.refresh_pricing(&burnrate_core::providers::UreqClient::default());
                });
            }

            // Notification permission is asked for once, on first launch. A
            // refusal is not fatal: usage figures matter more than banners.
            {
                let ask = handle.clone();
                let runner = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(3));
                    let _ = runner.run_on_main_thread(move || {
                        use tauri_plugin_notification::NotificationExt;
                        let handle = ask.clone();
                        // `show` is what triggers the macOS permission prompt,
                        // so its result is the only way to tell "delivered" from
                        // "the platform refused".
                        match handle
                            .notification()
                            .builder()
                            .title("BurnRate")
                            .body("Notifications are on. Milestones, resets, burn rate and daily spend appear here.")
                            .show()
                        {
                            Ok(()) => eprintln!("burnrate: welcome notification accepted"),
                            Err(error) => eprintln!("burnrate: welcome notification refused: {error}"),
                        }
                    });
                });
            }

            // First poll immediately, so the window is never empty on open.
            poll_once(&handle);

            // The poll loop. Interval comes from settings, re-read every tick
            // so changing it takes effect without a restart.
            {
                let ticker = handle.clone();
                std::thread::spawn(move || loop {
                    let interval = ticker
                        .state::<Arc<AppState>>()
                        .settings()
                        .poll_interval_seconds
                        .clamp(30, 3600);
                    std::thread::sleep(Duration::from_secs(interval));
                    let inner = ticker.clone();
                    let runner = ticker.clone();
                    let _ = runner.run_on_main_thread(move || {
                        poll_once(&inner);
                    });
                });
            }

            render_tray(&handle).ok();
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
            }
            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            match id {
                ID_QUIT => app.exit(0),
                ID_DASHBOARD => open_window(app.clone(), Some(AppPane::Usage)),
                ID_CHARTS => open_window(app.clone(), Some(AppPane::Usage)),
                ID_SETTINGS => open_window(app.clone(), Some(AppPane::Notifications)),
                // The About pane carries the update affordance, as in Swift.
                ID_UPDATE => open_window(app.clone(), Some(AppPane::About)),
                other if other.starts_with(ID_WIDGET_PREFIX) => {
                    if let Some(provider) = other
                        .strip_prefix(ID_WIDGET_PREFIX)
                        .and_then(|rest| rest.strip_suffix("-remove"))
                    {
                        let _ = toggle_widget(app.clone(), provider.to_string());
                    }
                }
                _ => {}
            }
        })
        .invoke_handler(tauri::generate_handler![
            snapshot,
            save_settings,
            settings_file_path,
            send_test_notification,
            model_colours,
            refresh_now,
            app_icon_data_url,
            upsert_milestone,
            remove_milestone,
            upsert_burn_alert,
            remove_burn_alert,
            upsert_cost_alert,
            toggle_widget,
            set_poll_interval,
            set_notify_on_reset,
            known_providers,
            open_window,
        ])
        .run(tauri::generate_context!())
        .expect("error while running BurnRate");
}

#[cfg(test)]
mod tests {
    use super::{daily_slots, nice_ticks};

    /// A synthetic +12 → +13 transition at 03:00 local, which is when New
    /// Zealand actually shifts, so the walk is tested against a real-shaped
    /// boundary rather than whatever timezone the machine is in.
    const TRANSITION: i64 = 1_790_431_200; // 2026-09-27T03:00+13:00
    fn shifting_offset(at: i64) -> i64 {
        if at >= TRANSITION {
            13 * 3600
        } else {
            12 * 3600
        }
    }
    /// A faithful stand-in for `local_start_of_day` under that rule: the local
    /// calendar date, then that date's midnight under the offset in effect *at
    /// the midnight*.
    ///
    /// Getting this model right matters — the first version guessed the midnight
    /// from the instant's own offset, which for a time just after the shift lands
    /// an hour back, and re-deriving from there walks back a whole day. That made
    /// the walk stall, which is how the mistake surfaced.
    fn shifting_day_start(at: i64) -> i64 {
        let date = (at + shifting_offset(at)).div_euclid(86_400);
        let candidate = date * 86_400 - shifting_offset(at);
        date * 86_400 - shifting_offset(candidate)
    }

    /// The bug: every slot built with today's offset matched no stored bucket for
    /// any day before the daylight-saving change, so the chart showed four days of
    /// bars and five empty slots.
    #[test]
    fn daily_slots_use_each_days_own_midnight() {
        let now = TRANSITION + 3 * 86_400;
        let slots = daily_slots(now - 7 * 86_400, now, &shifting_day_start);

        assert_eq!(slots.len(), 8, "one slot per calendar day, inclusive");
        for slot in &slots {
            assert_eq!(
                *slot,
                shifting_day_start(*slot),
                "slot {slot} is not that day's local midnight"
            );
        }
        let before: Vec<i64> = slots.iter().copied().filter(|s| *s < TRANSITION).collect();
        let after: Vec<i64> = slots.iter().copied().filter(|s| *s >= TRANSITION).collect();
        assert!(
            !before.is_empty() && !after.is_empty(),
            "both sides present"
        );
        // A +12 midnight lands at UTC noon (mod 43,200), a +13 one at 11:00.
        assert!(before.iter().all(|s| s.rem_euclid(86_400) == 43_200));
        assert!(after.iter().all(|s| s.rem_euclid(86_400) == 39_600));
        let mut sorted = slots.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, slots, "slots ascend");
    }

    /// The walk must not repeat or skip a day across a 23-hour day.
    #[test]
    fn daily_slots_do_not_repeat_or_skip_across_a_transition() {
        let now = TRANSITION + 2 * 86_400;
        let slots = daily_slots(now - 3 * 86_400, now, &shifting_day_start);
        let mut unique = slots.clone();
        unique.dedup();
        assert_eq!(unique.len(), slots.len(), "no repeated day: {slots:?}");
        assert_eq!(slots.len(), 4, "inclusive of both ends: {slots:?}");
        // The day containing the transition is short, not duplicated.
        for pair in slots.windows(2) {
            let gap = pair[1] - pair[0];
            assert!(
                (82_800..=90_000).contains(&gap),
                "consecutive slots {gap}s apart, expected 23-25h"
            );
        }
    }

    /// snake_case to the camelCase the wire uses.
    fn camel(name: &str) -> String {
        let mut out = String::new();
        let mut upper = false;
        for character in name.chars() {
            if character == '_' {
                upper = true;
            } else if upper {
                out.extend(character.to_uppercase());
                upper = false;
            } else {
                out.push(character);
            }
        }
        out
    }

    /// The frontend reads `dashboard.<field>` by name, and nothing checks that
    /// the field exists. `rangeLabel` was read for two releases while `Dashboard`
    /// had no such field, so both charts were titled "Top models (undefined)" —
    /// and a hand-written test fixture that *did* set `rangeLabel` hid it.
    ///
    /// This parses the struct's field list out of this file and every
    /// `dashboard.<name>` out of the frontend, and fails on anything unmatched.
    #[test]
    fn the_frontend_only_reads_dashboard_fields_that_exist() {
        let source = include_str!("lib.rs");
        let start = source.find("struct Dashboard {").expect("Dashboard struct");
        let body = &source[start..];
        let body = &body[..body.find("\n}").expect("end of struct")];
        let declared: Vec<String> = body
            .lines()
            .map(str::trim)
            .filter(|line| !line.starts_with("//") && !line.starts_with('#'))
            .filter_map(|line| line.split_once(':').map(|(name, _)| name.trim()))
            .filter(|name| {
                !name.is_empty()
                    && name
                        .chars()
                        .all(|character| character.is_ascii_lowercase() || character == '_')
            })
            .map(camel)
            .collect();
        assert!(
            declared.len() > 15,
            "parsed only {} fields, so the parse is wrong: {declared:?}",
            declared.len()
        );

        let mut missing: Vec<String> = Vec::new();
        for (file, source) in [
            ("usage.js", include_str!("../../ui/app/usage.js")),
            ("app.js", include_str!("../../ui/app/app.js")),
        ] {
            for line in source.lines() {
                // Comments talk about these names too.
                let line = line.split("//").next().unwrap_or("");
                let mut rest = line;
                while let Some(at) = rest.find("dashboard.") {
                    rest = &rest[at + "dashboard.".len()..];
                    let name: String = rest
                        .chars()
                        .take_while(|c| c.is_ascii_alphanumeric())
                        .collect();
                    if name.is_empty() {
                        continue;
                    }
                    if !declared.contains(&name) {
                        missing.push(format!("{file}: dashboard.{name}"));
                    }
                }
            }
        }
        missing.sort();
        missing.dedup();
        assert!(
            missing.is_empty(),
            "the frontend reads dashboard fields that Dashboard does not send, which \
             renders as `undefined`: {missing:?}"
        );
    }

    /// The bug this replaced: a ladder of fixed small steps meant a large span
    /// landed on 500k and produced a gridline every 500k — 7,306 of them on a
    /// real day. Thousands of SVG nodes is why the chart looked cooked.
    #[test]
    fn tick_count_stays_small_at_every_magnitude() {
        for maximum in [
            12.0,
            850.0,
            42_000.0,
            1_200_000.0,
            87_801_324.0,
            3_652_595_073.0,
            1.0e13,
        ] {
            let ticks = nice_ticks(0.0, maximum);
            assert!(
                (2..=12).contains(&ticks.len()),
                "max {maximum} produced {} ticks",
                ticks.len()
            );
        }
    }

    /// The axis must land on round numbers, not on whatever the span divided by
    /// five happens to be.
    #[test]
    fn ticks_are_round_numbers_in_range() {
        let ticks = nice_ticks(0.0, 3_652_595_073.0);
        assert_eq!(
            ticks,
            vec![0.0, 1_000_000_000.0, 2_000_000_000.0, 3_000_000_000.0]
        );
        for tick in &ticks {
            assert!(*tick <= 3_652_595_073.0, "{tick} is above the data");
        }
    }

    #[test]
    fn degenerate_spans_do_not_hang_or_panic() {
        assert_eq!(nice_ticks(5.0, 5.0), vec![5.0]);
        assert_eq!(nice_ticks(10.0, 1.0), vec![10.0]);
        assert_eq!(nice_ticks(0.0, f64::NAN), vec![0.0]);
        assert_eq!(nice_ticks(0.0, f64::INFINITY), vec![0.0]);
    }

    /// A zero-maximum day (nothing used) still gets an axis rather than none.
    #[test]
    fn a_flat_zero_series_still_has_an_axis() {
        assert_eq!(nice_ticks(0.0, 0.0), vec![0.0]);
    }
}
