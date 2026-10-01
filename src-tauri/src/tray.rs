use std::sync::{Arc, Mutex};

use tauri::image::Image;
use tauri::menu::{Menu, MenuBuilder, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

use burnrate_core::dial;
use burnrate_core::menu::{StatusMenuBuilder, StatusMenuEntry, StatusMenuModel};

use crate::{now_unix, AppState};

/// Menu item ids. Fixed strings, because a Linux tray menu cannot be replaced
/// once set — rows are reused and only their text changes.
pub(crate) const ID_DASHBOARD: &str = "open-dashboard";
pub(crate) const ID_UPDATE: &str = "check-updates";
pub(crate) const ID_QUIT: &str = "quit";
/// Widget rows are per provider, so their ids are built as `widget-<provider>`.
pub(crate) const ID_WIDGET_PREFIX: &str = "widget-";

/// Tray handles kept so every poll can rewrite them in place.
///
/// Only the rows whose *text or enabled state* changes are held. The Settings
/// and Quit rows are owned by the menu itself and are dispatched by id, so
/// keeping a handle to them would be dead weight.
pub(crate) struct TrayHandles<R: tauri::Runtime> {
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
    update: MenuItem<R>,
    main: tauri::tray::TrayIcon<R>,
    /// Per provider: the tray icon plus the widget menu's status row.
    pub(crate) widgets: Vec<WidgetHandles<R>>,
    /// Widget rows the last render asked for, so new ones can be added.
    known_widgets: Vec<String>,
}

pub(crate) struct WidgetHandles<R: tauri::Runtime> {
    provider: String,
    icon: tauri::tray::TrayIcon<R>,
    status: MenuItem<R>,
}

/// The tray glyph as raw RGBA — Tauri wants pixels, not a PNG.
/// The menu-bar mark, drawn at **2x**.
///
/// `tray-icon` scales whatever it is given to 18 points tall, so a 22px image was
/// being upscaled to 36 device pixels on a Retina display — which is the
/// pixelated icon. 36px is exactly 2x of 18pt, so macOS gets one image pixel per
/// device pixel.
pub(crate) const TRAY_EDGE: u32 = 36;

fn tray_image(remaining: Option<f64>) -> Image<'static> {
    // macOS is the only platform that recolours this: the image goes over as a
    // *template* and the system tints it for the menu bar, so it is drawn black
    // and comes out right in both light and dark menu bars. Windows and Linux
    // show the pixels as drawn, where black on a dark taskbar is invisible — so
    // they get white.
    #[cfg(target_os = "macos")]
    let canvas = dial::menu_bar_image(remaining, TRAY_EDGE);
    #[cfg(not(target_os = "macos"))]
    let canvas = dial::menu_bar_image_in(
        remaining,
        TRAY_EDGE,
        burnrate_core::icon::RgbColor::new(1.0, 1.0, 1.0),
    );
    Image::new_owned(canvas.pixels, TRAY_EDGE, TRAY_EDGE)
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
    update: MenuItem<R>,
}

/// Builds the menu for a given row plan.
fn build_menu<R: tauri::Runtime>(
    app: &AppHandle<R>,
    plan: &[(RowKind, String)],
    generation: u64,
) -> tauri::Result<BuiltMenu<R>> {
    // No "Charts…" row: the usage window carries the charts, so a second entry
    // that opens the same window is noise. No "Settings…" row either — the same
    // window's sidebar holds the settings panes, and the dashboard row opens it.
    let dashboard = MenuItem::with_id(app, ID_DASHBOARD, "Usage Dashboard…", true, None::<&str>)?;
    let update = MenuItem::with_id(app, ID_UPDATE, "Check for Updates…", true, None::<&str>)?;
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
                // **Enabled**, deliberately, even though the row does nothing.
                // A disabled item is greyed out on macOS, which is what the
                // usage figures were: unreadable. The Swift menu sets
                // `autoenablesItems = false` so its `action: nil` rows render at
                // full contrast; `enabled: true` is the same statement here, and
                // the click is ignored by `on_menu_event`.
                let item = MenuItem::with_id(
                    app,
                    format!("row-{generation}-{index}"),
                    text.as_str(),
                    true,
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
        .item(&update)
        .separator()
        .item(&quit)
        .build()?;
    Ok(BuiltMenu {
        menu,
        rows,
        dashboard,
        update,
    })
}

pub(crate) fn install_trays(app: &AppHandle<Wry>) -> tauri::Result<TrayHandles<Wry>> {
    // The menu starts with no usage rows: the first poll fills them in and the
    // shape is rebuilt then. One "Loading usage…" row stands in until it arrives,
    // which is what the Swift menu shows too.
    let plan = vec![(RowKind::Text, "Loading usage…".to_string())];
    let BuiltMenu {
        menu,
        rows,
        dashboard,
        update,
    } = build_menu(app, &plan, 0)?;
    let main = TrayIconBuilder::with_id("main")
        .icon(tray_image(None))
        .icon_as_template(true)
        .tooltip("BurnRate")
        .menu(&menu)
        .build(app)?;

    Ok(TrayHandles {
        rows,
        row_kinds: plan.iter().map(|(kind, _)| *kind).collect(),
        generation: 0,
        dashboard,
        update,
        main,
        widgets: Vec::new(),
        known_widgets: Vec::new(),
    })
}

fn install_widget(app: &AppHandle<Wry>, provider: &str) -> tauri::Result<WidgetHandles<Wry>> {
    // Enabled for the same reason as the usage rows: a disabled item is greyed
    // out, and this one carries the widget's own reading.
    let status = MenuItem::with_id(
        app,
        format!("{ID_WIDGET_PREFIX}{provider}-status"),
        provider,
        true,
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
        .icon(tray_image(None))
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
pub(crate) fn render_tray(app: &AppHandle<Wry>) -> tauri::Result<()> {
    let app_state = app.state::<Arc<AppState>>();
    let tray_state = app.state::<Mutex<TrayHandles<Wry>>>();
    let mut handles = tray_state.lock().expect("tray lock");

    let settings = app_state.settings();
    let usage = app_state.usage();
    let remaining = StatusMenuBuilder::worst_rolling_remaining(&usage);
    let now = now_unix() as i64;

    // The icon carries the severity, so it is redrawn on every poll. This must
    // go through `set_icon_with_as_template`: tray-icon's plain `set_icon` passes
    // `false` for the template flag, ignoring `icon_as_template`, so redrawing
    // the icon silently turned it back into a fixed black image — which is why
    // the mark stayed black in dark mode instead of being tinted white.
    handles
        .main
        .set_icon_with_as_template(Some(tray_image(remaining)), true)
        .ok();

    // `false`: this build has no separate Charts window — the usage pane is the
    // dashboard, so the tray has no Charts row to gate.
    let model = StatusMenuBuilder::main_menu(&usage, None, false, false, now);
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
    // The update row carries the state: an offer to install, or an invitation to
    // check. Disabled while a check or download is in flight, so a second click
    // cannot start a second download.
    let status = app_state.update_status();
    let label = match (&status.available, status.busy) {
        (Some(version), true) => format!("Downloading {version}…"),
        (Some(version), false) => format!("Update to {version}…"),
        (None, true) => "Checking for Updates…".to_string(),
        (None, false) => "Check for Updates…".to_string(),
    };
    let _ = handles.update.set_text(label);
    let _ = handles.update.set_enabled(!status.busy);

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
    // A provider that is no longer configured has to be *unregistered*, not just
    // dropped. `TrayIcon` implements no `Drop` of its own and the tray manager
    // owns the resource, so letting the handle fall out of the vector left the
    // menu-bar item in place: toggling a widget off appeared to do nothing, and
    // toggling it on again installed a second icon for the same provider.
    let mut kept = Vec::with_capacity(handles.widgets.len());
    for widget in handles.widgets.drain(..) {
        if settings.widget_providers.contains(&widget.provider) {
            kept.push(widget);
        } else {
            let _ = app.remove_tray_by_id(widget_id(&widget.provider).as_str());
            eprintln!("burnrate: widget {} removed", widget.provider);
        }
    }
    handles.widgets = kept;

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
