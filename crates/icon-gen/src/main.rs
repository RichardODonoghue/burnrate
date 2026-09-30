//! Renders the BurnRate icon set from `burnrate-core`'s geometry.
//!
//!     cargo run -p icon-gen            # writes src-tauri/icons/
//!
//! The mark is defined once, in `burnrate_core::dial`, and this generator is the
//! only thing that rasterises it. There is no hand-drawn art anywhere in the
//! repo: the app icon, the macOS `.icns`, the Windows `.ico` and the PNG set all
//! come from here, so they cannot drift apart.
//!
//! The tray mark is *not* here: the runtime draws it from the same geometry and
//! hands Tauri raw RGBA, so a file would be a second copy to keep in step. This
//! used to write `tray.png`, `tray@2x.png` and `tray.rgba`, which nothing read.

use std::path::{Path, PathBuf};

use burnrate_core::dial::{self, Canvas};

fn main() {
    let out_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../src-tauri/icons")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from("src-tauri/icons"));
    std::fs::create_dir_all(&out_dir).expect("create icons dir");
    println!("writing {}", out_dir.display());

    // --- App icon: PNG set + .icns + .ico -----------------------------------
    let app_sizes = [16u32, 32, 64, 128, 256, 512, 1024];
    let mut app_pngs: Vec<(u32, Vec<u8>)> = Vec::new();
    for size in app_sizes {
        let canvas = dial::app_icon(size);
        let bytes = encode_png(&canvas);
        app_pngs.push((size, bytes));
    }
    for (size, bytes) in &app_pngs {
        let name = match size {
            16 => "icon_16x16.png".to_string(),
            // `32x32.png`, not `icon_32x32.png`: this is the name
            // `tauri.conf.json` declares, and a mismatch here left a
            // stale file as the Windows taskbar icon.
            32 => "32x32.png".to_string(),
            64 => "icon_64x64.png".to_string(),
            128 => "128x128.png".to_string(),
            256 => "256x256.png".to_string(),
            512 => "512x512.png".to_string(),
            _ => "icon-1024.png".to_string(),
        };
        write(&out_dir.join(&name), bytes);
    }
    // The bundler wants a canonical "icon.png".
    if let Some((_, bytes)) = app_pngs.iter().find(|(size, _)| *size == 512) {
        write(&out_dir.join("icon.png"), bytes);
    }

    write(&out_dir.join("icon.icns"), build_icns(&app_pngs));
    write(&out_dir.join("icon.ico"), build_ico(&app_pngs));

    println!("done");
}

fn write(path: &Path, bytes: impl AsRef<[u8]>) {
    std::fs::write(path, bytes.as_ref())
        .unwrap_or_else(|error| panic!("write {}: {error}", path.display()));
}

fn encode_png(canvas: &Canvas) -> Vec<u8> {
    canvas.to_png()
}

/// macOS `.icns`: an 'icns' magic, total length, then `type + length + PNG`
/// records. The OSType must be the *canonical size* for the entry.
fn build_icns(entries: &[(u32, Vec<u8>)]) -> Vec<u8> {
    fn ostype(size: u32) -> Option<&'static [u8; 4]> {
        Some(match size {
            16 => b"ic04",
            32 => b"ic05",
            64 => b"ic12",
            128 => b"ic07",
            256 => b"ic08",
            512 => b"ic09",
            1024 => b"ic10",
            _ => return None,
        })
    }
    let mut body = Vec::new();
    for (size, png) in entries {
        let Some(kind) = ostype(*size) else { continue };
        body.extend_from_slice(kind);
        body.extend_from_slice(&((png.len() + 8) as u32).to_be_bytes());
        body.extend_from_slice(png);
    }
    let mut out = Vec::with_capacity(body.len() + 8);
    out.extend_from_slice(b"icns");
    out.extend_from_slice(&((body.len() + 8) as u32).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

/// Windows `.ico`: PNG-compressed entries (Vista and newer accept these).
fn build_ico(entries: &[(u32, Vec<u8>)]) -> Vec<u8> {
    let chosen: Vec<(u32, &Vec<u8>)> = entries
        .iter()
        .filter(|(size, _)| [16u32, 32, 64, 128, 256].contains(size))
        .map(|(size, bytes)| (*size, bytes))
        .collect();
    let mut out = Vec::new();
    out.extend_from_slice(&[0, 0, 1, 0]); // reserved, type 1 (icon)
    out.extend_from_slice(&(chosen.len() as u16).to_le_bytes());
    let mut offset = 6 + chosen.len() * 16;
    for (size, png) in &chosen {
        let dimension = if *size >= 256 { 0u8 } else { *size as u8 };
        out.push(dimension);
        out.push(dimension);
        out.push(0); // palette
        out.push(0); // reserved
        out.extend_from_slice(&1u16.to_le_bytes()); // colour planes
        out.extend_from_slice(&32u16.to_le_bytes()); // bits per pixel
        out.extend_from_slice(&(png.len() as u32).to_le_bytes());
        out.extend_from_slice(&(offset as u32).to_le_bytes());
        offset += png.len();
    }
    for (_, png) in &chosen {
        out.extend_from_slice(png);
    }
    out
}
