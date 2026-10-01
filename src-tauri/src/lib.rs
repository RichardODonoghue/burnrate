//! BurnRate desktop app (Tauri v2).
//!
//! The shell owns: the tray (main item + per-plan widgets), the window and its
//! panes, settings persistence, and the poll loop. All the logic — menu
//! contents, icon state, alert rules — comes from `burnrate-core`, so this file
//! is the "host decides how to perform an action" half of
//! `StatusItemPresenting`.
//!
//! Two constraints on Linux tray menus:
//!   - a tray menu cannot be swapped once set, only edited, so the menu is
//!     built once and its items' text is rewritten every poll;
//!   - the items must each have a menu, or the icon does not appear at all.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tauri::{AppHandle, Manager, Wry};

mod commands;
mod dashboard;
mod notifications;
mod swift_import;
mod tray;
mod updater;
mod wire;

use burnrate_core::model::ProviderUsage;
use burnrate_core::paths::AppPaths;
use burnrate_core::poller::{PollResult, Poller};
use burnrate_core::settings::Settings;

use commands::{
    app_icon_data_url, check_for_updates, install_update, known_providers, model_colours, open_url,
    open_window, refresh_now, remove_burn_alert, remove_milestone, save_settings,
    send_test_notification, set_notify_on_reset, set_poll_interval, toggle_widget,
    upsert_burn_alert, upsert_cost_alert, upsert_milestone,
};
use dashboard::snapshot;
use tray::{
    install_trays, render_tray, TrayHandles, ID_DASHBOARD, ID_QUIT, ID_UPDATE, ID_WIDGET_PREFIX,
};
use wire::AppPane;

#[cfg(test)]
use dashboard::{daily_slots, nice_ticks};
#[cfg(test)]
use tray::TRAY_EDGE;

/// Shared state: settings, the poller, and the last result.
pub(crate) struct AppState {
    pub(crate) settings: Mutex<Settings>,
    pub(crate) poller: Mutex<Poller>,
    pub(crate) last: Mutex<Option<PollResult>>,
    /// Set while a notification is being delivered, so a burst cannot stack.
    notified: AtomicU64,
    pub(crate) core_version: String,
    /// Providers detected at least once this session.
    ///
    /// A widget is only created for one of these. A configured provider whose CLI
    /// is not installed used to get a menu-bar item that could never show a
    /// figure — the permanently empty "Codex" widget. Tracking what has been
    /// *seen* rather than what is in the latest poll keeps a widget from
    /// disappearing during a transient API failure.
    seen_providers: Mutex<std::collections::BTreeSet<String>>,
    /// The updater's last result, for the tray row and the About pane.
    update: Mutex<updater::UpdateStatus>,
}

impl AppState {
    pub(crate) fn settings(&self) -> Settings {
        self.settings.lock().expect("settings lock").clone()
    }

    pub(crate) fn update_status(&self) -> updater::UpdateStatus {
        self.update.lock().expect("update lock").clone()
    }

    pub(crate) fn set_update_status(&self, status: updater::UpdateStatus) {
        *self.update.lock().expect("update lock") = status;
    }

    pub(crate) fn seen_providers(&self) -> std::collections::BTreeSet<String> {
        self.seen_providers.lock().expect("seen lock").clone()
    }

    fn note_providers(&self, usage: &[ProviderUsage]) {
        let mut seen = self.seen_providers.lock().expect("seen lock");
        for provider in usage {
            seen.insert(provider.provider_name.clone());
        }
    }

    pub(crate) fn usage(&self) -> Vec<ProviderUsage> {
        self.last
            .lock()
            .expect("result lock")
            .as_ref()
            .map(|result| result.usage.clone())
            .unwrap_or_default()
    }
}

pub(crate) fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Runs one poll on the UI thread, stores the result, redraws the tray and
/// delivers any notifications the notifier decided on.
pub(crate) fn poll_once(app: &AppHandle<Wry>) {
    let state = app.state::<Arc<AppState>>();
    let settings = state.settings();
    let result = {
        let mut poller = state.poller.lock().expect("poller lock");
        let result = poller.poll(&settings);
        // Persist the trend history with each poll, so the chart has data
        // immediately on the next launch rather than after hours of polling.
        poller.save_history();
        poller.save_model_history();
        poller.save_notifier_state();
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
/// Posts one banner.
///
/// macOS needs `UNUserNotificationCenter` — see `notifications.rs`. Elsewhere the
/// Tauri plugin's path works and is used instead.
pub(crate) fn post_banner(app: &AppHandle<Wry>, title: &str, body: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let _ = app;
        notifications::post(title, body)
    }
    #[cfg(not(target_os = "macos"))]
    {
        use tauri_plugin_notification::NotificationExt;
        app.notification()
            .builder()
            .title(title)
            .body(body)
            .show()
            .map_err(|error| error.to_string())
    }
}

/// Asks for notification permission, prompting where the platform does that.
fn authorise_notifications(app: &AppHandle<Wry>) -> String {
    #[cfg(target_os = "macos")]
    {
        let _ = app;
        notifications::authorise()
    }
    #[cfg(not(target_os = "macos"))]
    {
        use tauri_plugin_notification::NotificationExt;
        app.notification()
            .request_permission()
            .map(|state| format!("{state:?}"))
            .unwrap_or_else(|error| format!("error ({error})"))
    }
}

/// The current permission state, without prompting.
pub(crate) fn notification_permission(app: &AppHandle<Wry>) -> String {
    #[cfg(target_os = "macos")]
    {
        let _ = app;
        notifications::permission_state()
    }
    #[cfg(not(target_os = "macos"))]
    {
        use tauri_plugin_notification::NotificationExt;
        app.notification()
            .permission_state()
            .map(|state| format!("{state:?}"))
            .unwrap_or_else(|error| format!("unknown ({error})"))
    }
}

fn deliver(app: &AppHandle<Wry>, notifications: &[burnrate_core::notifier::Notification]) {
    for notification in notifications {
        if let Err(error) = post_banner(app, &notification.title, &notification.body) {
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
            update: Mutex::new(updater::UpdateStatus::idle()),
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
            // A menu-bar app has no Dock icon. Without this the app shows up in
            // the Dock and the app switcher while it is only a tray icon.
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
                poller.load_notifier_state();
                if let Some(summary) =
                    swift_import::import_swift_history_if_needed(&mut poller, now)
                {
                    eprintln!("burnrate: {summary}");
                }
                eprintln!(
                    "burnrate: trend history {} sample(s), {} day(s) of model history, \
                     {} notifier window(s)",
                    poller.remaining_history().len(),
                    poller.model_history_len(),
                    poller.notifier_windows_len()
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
                        // Asking is what shows the macOS permission prompt, so it
                        // is also the only way to learn the answer.
                        let asked = authorise_notifications(&ask);
                        eprintln!("burnrate: notification permission {asked}");
                        if asked.starts_with("granted") || asked.contains("Granted") {
                            match post_banner(
                                &ask,
                                "BurnRate",
                                "Notifications are on. Milestones, resets, burn rate and daily spend appear here.",
                            ) {
                                Ok(()) => eprintln!("burnrate: welcome notification delivered"),
                                Err(error) => {
                                    eprintln!("burnrate: welcome notification failed: {error}")
                                }
                            }
                        }
                    });
                });
            }

            // First poll immediately, so the window is never empty on open.
            poll_once(&handle);

            // Updates: check once just after launch, then daily while running.
            // The first check is what turns the tray row into "Update to X…"
            // without the user asking.
            {
                let checker = handle.clone();
                std::thread::spawn(move || loop {
                    let status = updater::check(&updater::current_version());
                    eprintln!("burnrate: update check: {}", status.state);
                    checker
                        .state::<Arc<AppState>>()
                        .set_update_status(status);
                    let inner = checker.clone();
                    let runner = checker.clone();
                    let _ = runner.run_on_main_thread(move || {
                        render_tray(&inner).ok();
                    });
                    std::thread::sleep(Duration::from_secs(
                        burnrate_core::updater::CHECK_INTERVAL_SECONDS as u64,
                    ));
                });
            }

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
                // Opens the About pane rather than installing. The row says
                // "Update to X…" either way, but one click should not replace the
                // application: the pane shows the version and the Install button
                // is the confirmation.
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
            open_url,
            check_for_updates,
            install_update,
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

    /// `TrayIcon::set_icon` passes `false` for the template flag on macOS,
    /// ignoring `icon_as_template` — so redrawing the severity icon silently
    /// reverted it to a fixed black image instead of a mark macOS tints white in
    /// dark mode. Only `set_icon_with_as_template` preserves it, and nothing in
    /// the type system stops the next person reaching for the shorter name.
    #[test]
    fn tray_icons_are_always_set_as_templates() {
        // Only the shipping code: this test's own source contains the pattern.
        let source = include_str!("tray.rs");
        let shipping = source
            .split("#[cfg(test)]")
            .next()
            .expect("the file has a non-test part");
        let offenders: Vec<&str> = shipping
            .lines()
            .filter(|line| !line.trim_start().starts_with("//"))
            .filter(|line| line.contains(".set_icon("))
            .collect();
        assert!(
            offenders.is_empty(),
            "use set_icon_with_as_template, not set_icon: {offenders:?}"
        );
        assert!(
            shipping.contains("set_icon_with_as_template"),
            "the tray icon is never set with the template flag"
        );
    }

    /// The mark is drawn at 2x because tray-icon scales it to 18 points; a 22px
    /// source was upscaled to 36 device pixels on a Retina display.
    #[test]
    fn the_tray_mark_is_drawn_at_two_x() {
        assert_eq!(super::TRAY_EDGE, 36, "2x of the 18pt tray-icon target");
    }

    /// The window is a webview, and `tauri::generate_context!` embeds
    /// `frontendDist` at **compile** time. Without a `tsc` run the build still
    /// succeeds and the window renders nothing at all — so this reads the emitted
    /// entry point, and `include_str!` fails to compile when it is absent.
    #[test]
    fn the_frontend_is_built() {
        let entry = include_str!("../../ui/app/js/main.js");
        assert!(
            entry.contains("boot"),
            "ui/app/js/main.js is not the built entry point; run `npm run build` in ui/"
        );
    }

    /// Every icon `tauri.conf.json` declares must exist *and* be what the
    /// generator produces.
    ///
    /// The Windows taskbar icon was a stale `32x32.png`: the config asked for it,
    /// and `icon-gen` had long since renamed its output to `icon_32x32.png`, so
    /// the file on disk was an older icon — the pre-rewrite dial on a
    /// hard-cornered square plate, which showed up as a "horrible border" on the
    /// taskbar. Existence alone would not have caught it. The bytes have to match
    /// the geometry.
    #[test]
    fn the_declared_icons_are_the_ones_the_generator_makes() {
        let config: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
            .expect("tauri.conf.json parses");
        let icons = config["bundle"]["icon"]
            .as_array()
            .expect("bundle.icon is a list");
        assert!(!icons.is_empty(), "no bundle icons declared");

        for icon in icons {
            let path = icon.as_str().expect("an icon path");
            let full = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(path);
            assert!(full.exists(), "{path} is declared but does not exist");

            // PNG entries are a direct render, so they can be compared exactly.
            // The .icns and .ico are containers assembled by icon-gen.
            let size = std::path::Path::new(path)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .and_then(|stem| stem.split('x').next())
                .and_then(|first| first.parse::<u32>().ok());
            let Some(size) = size else { continue };

            let found = std::fs::read(&full).expect("read the icon");
            let expected = burnrate_core::dial::app_icon(size).to_png();
            assert!(
                found == expected,
                "{path} is not what the generator produces — run `cargo run -p icon-gen`"
            );
        }
    }

    /// The CSP has to permit exactly what the UI loads, and no more.
    ///
    /// Every directive is load-bearing, and a missing one blanks the window
    /// rather than failing a build — so it is pinned here. `index.html` loads its
    /// module and stylesheet same-origin; the palette and chart colours are set
    /// as `style` *attributes*, which cannot be nonced or hashed, making
    /// `'unsafe-inline'` the only way to allow them; and the About pane's icon is
    /// a `data:` URL. Script execution stays `'self'` — that directive is what
    /// stops an injected string from running.
    ///
    /// The `index.html` half keeps this honest: if the frontend starts loading
    /// something new, or gains an inline script, this fails rather than the CSP
    /// silently blocking it at runtime.
    #[test]
    fn the_csp_covers_what_the_ui_loads() {
        let config: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
            .expect("tauri.conf.json parses");
        let csp = config["app"]["security"]["csp"]
            .as_str()
            .expect("a CSP must be set: with none, an injected string can run");

        for needed in [
            "default-src 'self'",
            "script-src 'self'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data:",
            "connect-src 'self'",
            "object-src 'none'",
        ] {
            assert!(csp.contains(needed), "the UI needs `{needed}`, got: {csp}");
        }
        assert!(
            !csp.contains("\'unsafe-inline\'")
                || csp.contains("style-src \'self\' \'unsafe-inline\'"),
            "only style attributes may be inline: {csp}"
        );
        assert!(
            !csp.contains("script-src") || !csp.contains("script-src 'self' 'unsafe-inline'"),
            "inline script must stay blocked: {csp}"
        );

        let html = include_str!("../../ui/app/index.html");
        assert!(
            html.contains("src=\"./js/main.js\""),
            "the module is same-origin"
        );
        assert!(
            html.contains("href=\"./styles.css\""),
            "the stylesheet is same-origin"
        );
        // An inline script or handler would need 'unsafe-inline' for script-src,
        // which this CSP deliberately does not grant.
        assert!(
            !html.contains("<script>") && !html.contains("onload=") && !html.contains("onclick="),
            "index.html must not carry inline script"
        );
    }

    /// The bundle version has exactly one source: the workspace `Cargo.toml`.
    ///
    /// A `version` in `tauri.conf.json` **overrides** the crate version, and the
    /// two then drift without anything noticing. They did: both read `1.0.0`
    /// while the newest release was `0.8.0`, so About showed a number that
    /// corresponded to no release at all. Omitting the field makes Tauri fall
    /// back to the crate version — which is also what `burnrate_core::VERSION`
    /// reports for About's "Core" line, so the two cannot disagree.
    #[test]
    fn the_bundle_version_has_one_source() {
        let config: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
            .expect("tauri.conf.json parses");
        assert!(
            config.get("version").is_none(),
            "tauri.conf.json must not set `version`: it overrides the crate version and drifts"
        );
        // And the crate version really is the workspace one, so a crate that
        // grew its own version would be caught here.
        assert_eq!(env!("CARGO_PKG_VERSION"), burnrate_core::VERSION);
    }

    // The frontend's view of the wire is checked by TypeScript now
    // (`ui/app/src/types.ts`) — the job this test did by parsing JavaScript for
    // `dashboard.<field>` strings. A field read that Rust does not send is a
    // compile error at every use, rather than a test kept in step by hand. It also
    // never covered the `usage` entries, which is how `providerName` was read as
    // `provider_name` and silently fell through to a fallback.

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
