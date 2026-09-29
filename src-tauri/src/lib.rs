//! BurnRate desktop app (Tauri v2).
//!
//! Gate 0 (this file) is a tray spike, not the product: it proves that a Tauri
//! tray icon registers on all three platforms, that a *second and third* tray
//! item can coexist (per-plan widgets), and — the constraint that actually bit
//! the old hand-rolled Linux tray — that menu text can be mutated in place on a
//! timer. On Linux a tray menu cannot be swapped once set, only edited, so the
//! real menu is built once and its items' text is rewritten every poll.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;
use tauri::image::Image;
use tauri::menu::{Menu, MenuBuilder, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

/// Main tray item: the provider/menu item.
const TRAY_MAIN: &str = "main";
/// Per-plan widget items, mirroring the Swift `StatusItemManager`.
const WIDGETS: [(&str, &str); 2] = [
    ("widget-claude", "Claude 78%"),
    ("widget-opencode", "Go 91%"),
];

const MENU_STATUS: &str = "status";
const MENU_QUIT: &str = "quit";

/// Shared state the UI polls and the ticker writes.
#[derive(Default)]
struct SpikeState {
    tick: AtomicU64,
}

/// A tray icon plus the menu items whose text we rewrite each tick.
struct TrayHandles<R: tauri::Runtime> {
    status: MenuItem<R>,
    #[allow(dead_code)]
    quit: MenuItem<R>,
    #[allow(dead_code)]
    main: tauri::tray::TrayIcon<R>,
    widgets: Vec<(String, tauri::tray::TrayIcon<R>)>,
}

#[derive(Serialize)]
struct SpikeStatus {
    tray_count: usize,
    tick: u64,
    core: String,
    main_item_present: bool,
}

/// 22×22 tray glyph as raw RGBA, rendered by `cargo run -p icon-gen`.
const TRAY_RGBA: &[u8] = include_bytes!("../icons/tray.rgba");
const TRAY_EDGE: u32 = 22;

fn tray_icon() -> Image<'static> {
    // Monochrome + alpha: macOS treats it as a template image and recolours it,
    // Linux themes it. Tauri's `Image` wants owned RGBA bytes, not a PNG.
    Image::new_owned(TRAY_RGBA.to_vec(), TRAY_EDGE, TRAY_EDGE)
}

fn build_menu<R: tauri::Runtime>(
    app: &AppHandle<R>,
) -> tauri::Result<(Menu<R>, MenuItem<R>, MenuItem<R>)> {
    let status = MenuItem::with_id(app, MENU_STATUS, "Spike — starting…", false, None::<&str>)?;
    let quit = MenuItem::with_id(app, MENU_QUIT, "Quit BurnRate", true, None::<&str>)?;
    let menu = MenuBuilder::new(app)
        .item(&status)
        .separator()
        .item(&quit)
        .build()?;
    Ok((menu, status, quit))
}

fn install_trays(app: &AppHandle<Wry>) -> tauri::Result<TrayHandles<Wry>> {
    let (menu, status, quit) = build_menu(app)?;

    let main = TrayIconBuilder::with_id(TRAY_MAIN)
        .icon(tray_icon())
        .icon_as_template(true)
        .tooltip("BurnRate")
        .menu(&menu)
        .build(app)?;

    let mut widgets = Vec::new();
    for (id, title) in WIDGETS {
        // Linux only shows a tray item when it has a menu, so give each widget
        // a single-item menu rather than an icon with no menu attached.
        let (widget_menu, _, _) = build_menu(app)?;
        let icon = TrayIconBuilder::with_id(id)
            .icon(tray_icon())
            .icon_as_template(true)
            .title(title)
            .tooltip(title)
            .menu(&widget_menu)
            .build(app)?;
        widgets.push((title.to_string(), icon));
    }

    Ok(TrayHandles {
        status,
        quit,
        main,
        widgets,
    })
}

#[tauri::command]
fn spike_status(app: AppHandle<Wry>, state: tauri::State<'_, Arc<SpikeState>>) -> SpikeStatus {
    let mut count = 0;
    if app.tray_by_id(TRAY_MAIN).is_some() {
        count += 1;
    }
    for (id, _) in WIDGETS {
        if app.tray_by_id(id).is_some() {
            count += 1;
        }
    }
    SpikeStatus {
        tray_count: count,
        tick: state.tick.load(Ordering::Relaxed),
        core: format!("burnrate-core {}", burnrate_core::VERSION),
        main_item_present: count > 0,
    }
}

pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(SpikeState::default()))
        .setup(|app| {
            let handle = app.handle().clone();
            let handles = install_trays(&handle)?;
            let installed = 1 + handles.widgets.len();
            eprintln!("burnrate: {installed} tray item(s) installed");
            app.manage(handles);

            // Live text mutation: prove the menu can be updated in place.
            let ticker = handle.clone();
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(1));
                    let tick = {
                        let state = ticker.state::<Arc<SpikeState>>();
                        state.tick.fetch_add(1, Ordering::Relaxed) + 1
                    };
                    let app = ticker.clone();
                    let inner = ticker.clone();
                    let _ = app.run_on_main_thread(move || {
                        let handles = inner.state::<TrayHandles<Wry>>();
                        // Items are mutated, never replaced: on Linux a tray
                        // menu cannot be swapped once set.
                        let _ = handles.status.set_text(format!("Spike — tick {tick}"));
                        for (title, icon) in handles.widgets.iter() {
                            let _ = icon.set_title(Some(format!("{title} · t{tick}")));
                        }
                    });
                }
            });

            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
            }
            Ok(())
        })
        .on_menu_event(|app, event| {
            if event.id().as_ref() == MENU_QUIT {
                app.exit(0);
            }
        })
        .invoke_handler(tauri::generate_handler![spike_status])
        .run(tauri::generate_context!())
        .expect("error while running BurnRate");
}
