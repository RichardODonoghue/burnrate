use std::sync::Arc;

use tauri::{AppHandle, Emitter, Manager, Wry};

use burnrate_core::alerts::{BurnAlert, CostAlert, Milestone};
use burnrate_core::dial;
use burnrate_core::paths::AppPaths;
use burnrate_core::settings::Settings;

use crate::dashboard::state_snapshot_entries;
use crate::tray::render_tray;
use crate::wire::AppPane;
use crate::{notification_permission, poll_once, post_banner, updater, AppState};

#[tauri::command]
pub(crate) fn save_settings(app: AppHandle<Wry>, settings: Settings) -> Result<Settings, String> {
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
pub(crate) fn app_icon_data_url(edge: Option<u32>) -> String {
    dial::app_icon(edge.unwrap_or(128)).to_data_url()
}

/// The model palette, so every platform colours a model the same way. A seeded
/// hash changes colours between launches, so this is a fixed FNV-1a and is stable.
#[tauri::command]
pub(crate) fn model_colours() -> std::collections::BTreeMap<String, String> {
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

/// Delivers a test banner and reports what the platform actually did.
///
/// A bare `Ok(())` is not the whole truth. The plugin routes notifications
/// through `notify-rust`, which on macOS sets the *sending* application to
/// `com.apple.Terminal` whenever `tauri::is_dev()` is true — so under
/// `tauri dev` a banner is attributed to Terminal rather than to BurnRate, and
/// commonly does not appear at all. Reporting that is the difference between
/// "notifications are broken" and "notifications cannot be tested this way".
#[tauri::command]
pub(crate) fn send_test_notification(app: AppHandle<Wry>) -> Result<String, String> {
    post_banner(
        &app,
        "BurnRate test",
        "If you can read this, notifications are working.",
    )?;
    Ok(format!(
        "Sent, permission {}",
        notification_permission(&app)
    ))
}

/// Opens an external link.
///
/// Restricted to this project's GitHub rather than taking any URL, so the command
/// cannot become a general-purpose launcher reachable from the webview.
#[tauri::command]
pub(crate) fn open_url(url: String) -> Result<(), String> {
    const ALLOWED: &str = "https://github.com/RichardODonoghue/burnrate";
    if !url.starts_with(ALLOWED) {
        return Err(format!("refusing to open {url}"));
    }
    #[cfg(target_os = "macos")]
    let opener = "open";
    #[cfg(target_os = "windows")]
    let opener = "explorer";
    #[cfg(all(unix, not(target_os = "macos")))]
    let opener = "xdg-open";

    std::process::Command::new(opener)
        .arg(&url)
        .spawn()
        .map(|_| ())
        .map_err(|error| error.to_string())
}

/// Forces an immediate poll, skipping the throttle — the tray's Refresh.
/// Checks GitHub for a newer release.
///
/// `async` deliberately: the body is a network call, and a synchronous command
/// would run it on the UI thread and freeze the window.
#[tauri::command]
pub(crate) async fn check_for_updates(
    app: AppHandle<Wry>,
) -> Result<updater::UpdateStatus, String> {
    {
        let state = app.state::<Arc<AppState>>();
        state.set_update_status(updater::UpdateStatus {
            available: state.update_status().available,
            busy: true,
            state: "checking…".to_string(),
            can_install: updater::CAN_INSTALL,
        });
    }

    let current = updater::current_version();
    let result = tauri::async_runtime::spawn_blocking(move || updater::check(&current))
        .await
        .map_err(|error| error.to_string())?;

    let state = app.state::<Arc<AppState>>();
    state.set_update_status(result.clone());
    render_tray(&app).ok();
    Ok(result)
}

/// Downloads, verifies and installs the offered update, then relaunches.
///
/// Never returns on success: the replacement is in place and this process has to
/// go, because the relaunch waits for its pid to disappear.
#[tauri::command]
pub(crate) async fn install_update(app: AppHandle<Wry>) -> Result<(), String> {
    let version = {
        let state = app.state::<Arc<AppState>>();
        let status = state.update_status();
        let Some(version) = status.available else {
            return Err("no update is available".to_string());
        };
        state.set_update_status(updater::UpdateStatus {
            available: Some(version.clone()),
            busy: true,
            state: format!("downloading {version}…"),
            can_install: updater::CAN_INSTALL,
        });
        version
    };

    let target = version.clone();
    let installed = tauri::async_runtime::spawn_blocking(move || updater::install_version(&target))
        .await
        .map_err(|error| error.to_string())?;

    match installed {
        Ok(()) => {
            eprintln!("burnrate: {version} installed; relaunching");
            app.exit(0);
            Ok(())
        }
        Err(error) => {
            eprintln!("burnrate: update failed: {error}");
            let state = app.state::<Arc<AppState>>();
            state.set_update_status(updater::UpdateStatus {
                available: Some(version),
                busy: false,
                state: format!("install failed: {error}"),
                can_install: updater::CAN_INSTALL,
            });
            render_tray(&app).ok();
            Err(error)
        }
    }
}

#[tauri::command]
pub(crate) fn refresh_now(app: AppHandle<Wry>) {
    {
        let state = app.state::<Arc<AppState>>();
        let mut poller = state.poller.lock().expect("poller lock");
        poller.invalidate_caches();
    }
    poll_once(&app);
}

#[tauri::command]
pub(crate) fn upsert_milestone(
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
pub(crate) fn remove_milestone(
    app: AppHandle<Wry>,
    provider: String,
    window_label: String,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.remove_milestone(&provider, &window_label);
    save_settings(app, settings)
}

#[tauri::command]
pub(crate) fn upsert_burn_alert(
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
pub(crate) fn remove_burn_alert(
    app: AppHandle<Wry>,
    provider: String,
    window_label: String,
) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.remove_burn_alert(&provider, &window_label);
    save_settings(app, settings)
}

#[tauri::command]
pub(crate) fn upsert_cost_alert(
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
pub(crate) fn toggle_widget(app: AppHandle<Wry>, provider: String) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.toggle_widget(&provider);
    save_settings(app, settings)
}

#[tauri::command]
pub(crate) fn set_poll_interval(app: AppHandle<Wry>, seconds: u64) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.poll_interval_seconds = seconds.clamp(30, 3600);
    save_settings(app, settings)
}

#[tauri::command]
pub(crate) fn set_notify_on_reset(app: AppHandle<Wry>, enabled: bool) -> Result<Settings, String> {
    let mut settings = app.state::<Arc<AppState>>().settings();
    settings.notify_on_reset = enabled;
    save_settings(app, settings)
}

/// Providers the tray already knows about, for the widget toggles.
#[tauri::command]
pub(crate) fn known_providers(app: AppHandle<Wry>) -> Vec<String> {
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
pub(crate) fn open_window(app: AppHandle<Wry>, pane: Option<AppPane>) {
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
