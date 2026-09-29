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
use tauri::menu::{Menu, MenuBuilder, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

use burnrate_core::alerts::{BurnAlert, CostAlert, Milestone};
use burnrate_core::charts::{metric_value, ChartRange, Metric, TrendChartData};
use burnrate_core::dial;
use burnrate_core::icon::StatusIcon;
use burnrate_core::menu::{StatusMenuAction, StatusMenuBuilder, StatusMenuEntry, StatusMenuModel};
use burnrate_core::model::ProviderUsage;
use burnrate_core::paths::AppPaths;
use burnrate_core::poller::local_utc_offset_seconds;
use burnrate_core::poller::{PollResult, Poller};
use burnrate_core::settings::Settings;
use burnrate_core::usage::{DailyModelUsage, ModelUsageAggregator, ModelUsageEntry};

/// Menu item ids. Fixed strings, because a Linux tray menu cannot be replaced
/// once set — rows are reused and only their text changes.
const ID_STATUS: &str = "status";
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
}

impl AppState {
    fn settings(&self) -> Settings {
        self.settings.lock().expect("settings lock").clone()
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
    status: MenuItem<R>,
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
    tokens: i64,
    requests: i64,
}

/// Everything the Usage pane draws. The Swift layout, section for section:
/// snapshot cards, remaining over time, daily usage by model, top models,
/// breakdown table.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Dashboard {
    range: ChartRange,
    metric: Metric,
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

    // ranking + table
    ranking: Vec<Bar>,
    table: Vec<Bar>,
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
type Row<R> = (&'static str, MenuItem<R>);

fn build_menu<R: tauri::Runtime>(app: &AppHandle<R>) -> tauri::Result<(Menu<R>, Vec<Row<R>>)> {
    let status = MenuItem::with_id(app, ID_STATUS, "Starting…", false, None::<&str>)?;
    let dashboard = MenuItem::with_id(app, ID_DASHBOARD, "Usage Dashboard…", true, None::<&str>)?;
    let charts = MenuItem::with_id(app, ID_CHARTS, "Charts…", true, None::<&str>)?;
    let update = MenuItem::with_id(app, ID_UPDATE, "Check for Updates…", true, None::<&str>)?;
    let settings_item = MenuItem::with_id(app, ID_SETTINGS, "Settings…", true, None::<&str>)?;
    // A plain item, not PredefinedMenuItem::quit: on Linux the predefined Quit
    // reports itself disabled through DBusMenu, so the row is greyed out and
    // never dispatches — the app becomes unquittable from its own menu. The
    // Swift build used a plain NSMenuItem with an action, and so does this.
    let quit = MenuItem::with_id(app, ID_QUIT, "Quit", true, None::<&str>)?;
    let items = vec![
        (ID_STATUS, status.clone()),
        (ID_DASHBOARD, dashboard.clone()),
        (ID_CHARTS, charts.clone()),
        (ID_UPDATE, update.clone()),
        (ID_SETTINGS, settings_item.clone()),
    ];
    let menu = MenuBuilder::new(app)
        .item(&status)
        .separator()
        .item(&dashboard)
        .item(&charts)
        .item(&update)
        .separator()
        .item(&settings_item)
        .item(&quit)
        .build()?;
    Ok((menu, items))
}

fn install_trays(app: &AppHandle<Wry>) -> tauri::Result<TrayHandles<Wry>> {
    let (menu, items) = build_menu(app)?;
    let lookup = |id: &str| {
        items
            .iter()
            .find(|(key, _)| *key == id)
            .map(|(_, item)| item.clone())
            .expect("menu item")
    };
    let main = TrayIconBuilder::with_id("main")
        .icon(tray_image(None, 22))
        .icon_as_template(true)
        .tooltip("BurnRate")
        .menu(&menu)
        .build(app)?;

    Ok(TrayHandles {
        status: lookup(ID_STATUS),
        dashboard: lookup(ID_DASHBOARD),
        charts: lookup(ID_CHARTS),
        update: lookup(ID_UPDATE),
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
    write_menu(
        &model,
        &handles.status,
        &handles.dashboard,
        &handles.charts,
        &handles.update,
    );

    // Widgets: add the ones the settings ask for, drop the rest.
    for provider in &settings.widget_providers {
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

/// Rewrites the fixed rows of an already-created menu.
fn write_menu(
    model: &StatusMenuModel,
    status: &MenuItem<Wry>,
    dashboard: &MenuItem<Wry>,
    charts: &MenuItem<Wry>,
    update: &MenuItem<Wry>,
) {
    // Everything between the header and the actions is rendered as one summary
    // line: a fixed menu cannot grow rows, and the dashboard carries the detail.
    let summary = menu_summary(model);
    let _ = status.set_text(summary);
    let _ = dashboard.set_enabled(true);
    let _ = charts.set_enabled(model_has_charts(model));
    let _ = update.set_enabled(true);
}

fn menu_has_charts_row(model: &StatusMenuModel) -> bool {
    model.entries.iter().any(|entry| {
        matches!(
            entry,
            StatusMenuEntry::Action {
                action: StatusMenuAction::OpenCharts,
                ..
            }
        )
    })
}

fn model_has_charts(model: &StatusMenuModel) -> bool {
    menu_has_charts_row(model)
}

fn menu_summary(model: &StatusMenuModel) -> String {
    let mut lines: Vec<String> = Vec::new();
    for entry in &model.entries {
        match entry {
            StatusMenuEntry::ProviderHeader { title } => lines.push(title.clone()),
            StatusMenuEntry::WindowRow { label, detail } => {
                lines.push(format!("  {label}: {detail}"))
            }
            StatusMenuEntry::Text { text } => lines.push(text.clone()),
            _ => {}
        }
    }
    if lines.is_empty() {
        return "No providers found".to_string();
    }
    lines.join("\n")
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
    let today_start = burnrate_core::usage::start_of_day(now, offset);
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
    let first_day = burnrate_core::usage::start_of_day(daily_start, offset);
    let mut daily: Vec<DailyBar> = Vec::new();
    let mut cursor = first_day;
    while cursor <= today_start {
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
            bars,
            partial: cursor == today_start,
        });
        cursor += 86_400;
    }
    let daily_max = daily.iter().map(|day| day.total).fold(0.0_f64, f64::max);
    let daily_ticks = daily_ticks(0.0, daily_max);

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
            metric,
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
            ranking,
            table,
        },
        spend_today: last
            .as_ref()
            .map(|result| result.spend_today.clone())
            .unwrap_or_default(),
    }
}

/// Recorded so `model_colours` can return the palette for every model on screen.
fn remember_models(entries: &[ModelUsageEntry]) {
    MODELS_SEEN.with(|models| {
        let mut models = models.borrow_mut();
        models.clear();
        models.extend(entries.iter().map(|entry| entry.display_name()));
    });
}

fn bar_for(entry: &ModelUsageEntry, metric: Metric) -> Bar {
    Bar {
        key: entry.display_name(),
        provider: entry.provider.clone(),
        label: entry.display_name(),
        value: metric_value(metric, entry.total_tokens(), entry.cost),
        cost: entry.cost,
        tokens: entry.total_tokens(),
        requests: entry.requests,
    }
}

/// Gridlines for a token or cost axis, at the Swift build's magnitudes.
fn daily_ticks(low: f64, high: f64) -> Vec<f64> {
    if high <= low {
        return vec![low];
    }
    let span = high - low;
    let step = if span > 1_000_000.0 {
        500_000.0
    } else if span > 100_000.0 {
        50_000.0
    } else if span > 10_000.0 {
        5_000.0
    } else if span > 1_000.0 {
        500.0
    } else {
        100.0
    };
    let mut ticks = Vec::new();
    let mut value = (low / step).ceil() * step;
    while value <= high {
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
    MODELS_SEEN.with(|models| models.borrow().clone())
}

thread_local! {
    /// Model names seen in the last snapshot, filled in by `snapshot`.
    static MODELS_SEEN: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
}

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
fn icon_states() -> Vec<IconState> {
    // The full severity ramp, so the settings pane can show the icon states
    // exactly as the menu bar will render them.
    [100.0f64, 70.0, 55.0, 45.0, 30.0, 20.0, 5.0]
        .iter()
        .map(|remaining| IconState {
            remaining: *remaining,
            needle_degrees: StatusIcon::needle_angle(Some(*remaining)),
            tint: StatusIcon::tint(Some(*remaining)).top.to_hex(),
            matches_app_icon: (*remaining - 45.0).abs() < f64::EPSILON,
        })
        .collect()
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct IconState {
    remaining: f64,
    needle_degrees: f64,
    tint: String,
    /// True for the pose the shipped app icon is drawn at.
    matches_app_icon: bool,
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
    let usage = state.usage();
    let mut names: Vec<String> = usage.iter().map(|u| u.provider_name.clone()).collect();
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
        poller.poll(&settings)
    };
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
        }))
        .setup(|app| {
            let handle = app.handle().clone();
            let handles = install_trays(&handle)?;
            eprintln!(
                "burnrate: tray installed ({} item(s))",
                1 + handles.widgets.len()
            );
            app.manage(Mutex::new(handles));

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

            // Kick off pricing in the background: cost is a nicety and must not
            // delay the first usage figures.
            {
                let state = handle.state::<Arc<AppState>>().inner().clone();
                std::thread::spawn(move || {
                    let mut poller = state.poller.lock().expect("poller lock");
                    poller.load_pricing_cache();
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
            icon_states,
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
