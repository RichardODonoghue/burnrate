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

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::image::Image;
use tauri::menu::{Menu, MenuBuilder, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

use burnrate_core::alerts::{BurnAlert, CostAlert, Milestone};
use burnrate_core::dial;
use burnrate_core::icon::StatusIcon;
use burnrate_core::menu::{
    StatusMenuAction, StatusMenuBuilder, StatusMenuEntry, StatusMenuModel,
};
use burnrate_core::model::ProviderUsage;
use burnrate_core::paths::AppPaths;
use burnrate_core::settings::Settings;

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

/// Shared state: settings, the latest usage snapshot, and the poll counter.
#[derive(Default)]
struct AppState {
    settings: Mutex<Settings>,
    usage: Mutex<Vec<ProviderUsage>>,
    missing: Mutex<Vec<String>>,
    tick: AtomicU64,
    last_poll_unix: AtomicU64,
    core_version: String,
}

impl AppState {
    fn settings(&self) -> Settings {
        self.settings.lock().expect("settings lock").clone()
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
    tick: u64,
    platforms: PlatformInfo,
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
    PlatformInfo { os, runtime_dependencies: deps }
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

fn build_menu<R: tauri::Runtime>(app: &AppHandle<R>) -> tauri::Result<(Menu<R>, Vec<(&'static str, MenuItem<R>)>)> {
    let status = MenuItem::with_id(app, ID_STATUS, "Starting…", false, None::<&str>)?;
    let dashboard = MenuItem::with_id(app, ID_DASHBOARD, "Usage Dashboard…", true, None::<&str>)?;
    let charts = MenuItem::with_id(app, ID_CHARTS, "Charts…", true, None::<&str>)?;
    let update = MenuItem::with_id(app, ID_UPDATE, "Check for Updates…", true, None::<&str>)?;
    let settings_item =
        MenuItem::with_id(app, ID_SETTINGS, "Settings…", true, None::<&str>)?;
    let quit = PredefinedMenuItem::quit(app, Some("Quit"))?;
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

fn install_widget(
    app: &AppHandle<Wry>,
    provider: &str,
) -> tauri::Result<WidgetHandles<Wry>> {
    let status = MenuItem::with_id(
        app,
        &format!("{ID_WIDGET_PREFIX}{provider}-status"),
        provider,
        false,
        None::<&str>,
    )?;
    let remove = MenuItem::with_id(
        app,
        &format!("{ID_WIDGET_PREFIX}{provider}-remove"),
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
    Ok(WidgetHandles { provider: provider.to_string(), icon, status })
}

/// Renders one poll's worth of state onto the tray, in place.
fn render_tray(app: &AppHandle<Wry>) -> tauri::Result<()> {
    let app_state = app.state::<Arc<AppState>>();
    let tray_state = app.state::<Mutex<TrayHandles<Wry>>>();
    let mut handles = tray_state.lock().expect("tray lock");

    let settings = app_state.settings();
    let usage = app_state.usage.lock().expect("usage lock").clone();
    let remaining = StatusMenuBuilder::worst_rolling_remaining(&usage);
    let now = now_unix() as i64;

    // The icon carries the severity, so it is redrawn on every poll.
    handles
        .main
        .set_icon(Some(tray_image(remaining, 22)))
        .ok();

    let model = StatusMenuBuilder::main_menu(
        &usage,
        None,
        false,
        settings.includes_charts,
        now,
    );
    write_menu(&model, &handles.status, &handles.dashboard, &handles.charts, &handles.update);

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
        matches!(entry, StatusMenuEntry::Action { action: StatusMenuAction::OpenCharts, .. })
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

#[tauri::command]
fn snapshot(app: AppHandle<Wry>, pane: Option<AppPane>) -> Snapshot {
    let state = app.state::<Arc<AppState>>();
    let usage = state.usage.lock().expect("usage lock").clone();
    let missing = state.missing.lock().expect("missing lock").clone();
    let remaining = StatusMenuBuilder::worst_rolling_remaining(&usage);
    Snapshot {
        pane: pane.unwrap_or(AppPane::Usage),
        settings: state.settings(),
        usage,
        missing,
        remaining,
        app_version: app.package_info().version.to_string(),
        core_version: state.core_version.clone(),
        last_poll_unix: state.last_poll_unix.load(Ordering::Relaxed),
        tick: state.tick.load(Ordering::Relaxed),
        platforms: platform_info(),
    }
}

#[tauri::command]
fn save_settings(app: AppHandle<Wry>, settings: Settings) -> Result<Settings, String> {
    let state = app.state::<Arc<AppState>>();
    let settings = settings.normalised();
    let paths = AppPaths::detect();
    paths
        .ensure_app_directory()
        .map_err(|error| format!("could not create {}: {error}", paths.app_directory().display()))?;
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
    settings.upsert_burn_alert(BurnAlert::new(&provider, &window_label, percent_drop, minutes));
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
    settings.cost_alerts.retain(|alert| alert.provider != provider);
    if daily_limit_usd > 0.0 {
        settings.cost_alerts.push(CostAlert::new(&provider, daily_limit_usd));
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
    let usage = state.usage.lock().expect("usage lock");
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

pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(AppState {
            core_version: burnrate_core::VERSION.to_string(),
            ..AppState::default()
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
            match Settings::load(&paths.settings_file()) {
                Ok(settings) => {
                    eprintln!("burnrate: settings from {}", paths.settings_file().display());
                    *handle.state::<Arc<AppState>>().settings.lock().expect("lock") = settings;
                }
                Err(error) => {
                    eprintln!(
                        "burnrate: using default settings ({paths:?}: {error})"
                    );
                }
            }

            {
                let state = handle.state::<Arc<AppState>>().inner().clone();
                let ticker = handle.clone();
                std::thread::spawn(move || loop {
                    // Until the providers land, this is the shell's heartbeat:
                    // it drives the menu text and the icon, so both mechanisms
                    // are exercised end to end.
                    let seconds = state.settings().poll_interval_seconds.max(5);
                    std::thread::sleep(Duration::from_secs(seconds.min(5)));
                    let tick = state.tick.fetch_add(1, Ordering::Relaxed) + 1;
                    state.last_poll_unix.store(now_unix(), Ordering::Relaxed);
                    let inner = ticker.clone();
                    let runner = ticker.clone();
                    let _ = runner.run_on_main_thread(move || {
                        render_tray(&inner).ok();
                    });
                    let _ = tick;
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
                ID_UPDATE => {
                    // Opens the releases page, as the Swift build's updater does.
                    let _ = open_window(app.clone(), Some(AppPane::About));
                }
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
