//! One-time import of the Swift app's history, on macOS.
//!
//! The Swift build persisted two histories in `UserDefaults` under the bundle id
//! `com.burnrate.desktop`. The conversion lives in `burnrate_core::migration`;
//! this module is only the plumbing that gets the bytes out of the defaults
//! store, because that is the one part that cannot be platform-independent.
//!
//! Reading goes through `defaults export` → `plutil -extract … raw`. `defaults
//! export` asks `cfprefsd` for the live values rather than reading the plist file
//! from disk, so a value that has not been flushed yet is still visible.
//!
//! `plutil -convert json` is *not* usable here: it refuses any plist containing
//! a `Data` value outright ("Invalid object in plist for JSON format"), and both
//! histories are `Data`. `-extract <key> raw` handles them, returning a `Data`
//! value as base64.
//!
//! This runs once. It is skipped entirely when the Tauri app already has the
//! files, so a later launch never overwrites live history with a stale import.

use base64::Engine;
use burnrate_core::migration;
use burnrate_core::paths::AppPaths;
use burnrate_core::poller::{local_utc_offset_seconds, Poller};
use std::io::Write;

/// The Swift app's defaults domains, newest first. `com.burnrate.desktop` is
/// current; `com.burnrate.app` is the pre-Sep-2026 id it migrated from.
const DOMAINS: [&str; 2] = ["com.burnrate.desktop", "com.burnrate.app"];

/// Imports the Swift history if this install has none. Returns a one-line
/// summary for the log, or `None` when there was nothing to do.
pub fn import_swift_history_if_needed(poller: &mut Poller, now: i64) -> Option<String> {
    let paths = AppPaths::detect();
    let remaining_path = paths.remaining_history_file();
    let model_path = paths.model_history_file();

    // Already migrated, or already collecting. Either way, do not touch it: a
    // second import would replace live history with a stale snapshot.
    let want_remaining = !remaining_path.exists();
    let want_models = !model_path.exists();
    if !want_remaining && !want_models {
        return None;
    }

    let mut imported_remaining = 0_usize;
    let mut imported_days = 0_usize;
    for domain in DOMAINS {
        if want_remaining && imported_remaining == 0 {
            if let Some(bytes) = defaults_data(domain, "remainingHistory") {
                match migration::import_remaining_history(&bytes, now) {
                    Ok(samples) if !samples.is_empty() => {
                        imported_remaining = samples.len();
                        poller.set_remaining_history(samples);
                        poller.save_history();
                    }
                    Ok(_) => {}
                    Err(error) => {
                        eprintln!("burnrate: {domain} remainingHistory did not import: {error}")
                    }
                }
            }
        }
        if want_models && imported_days == 0 {
            if let Some(bytes) = defaults_data(domain, "modelUsageHistory") {
                match migration::import_model_history(&bytes, now, local_utc_offset_seconds()) {
                    Ok(days) if !days.is_empty() => {
                        imported_days = days.len();
                        poller.set_model_history(days);
                        poller.save_model_history();
                    }
                    Ok(_) => {}
                    Err(error) => {
                        eprintln!("burnrate: {domain} modelUsageHistory did not import: {error}")
                    }
                }
            }
        }
    }

    if imported_remaining == 0 && imported_days == 0 {
        return None;
    }
    Some(format!(
        "imported {} trend sample(s) and {} day(s) of model history from the Swift app",
        imported_remaining, imported_days
    ))
}

/// Reads one `Data` value out of a defaults domain, or `None` if it is absent.
fn defaults_data(domain: &str, key: &str) -> Option<Vec<u8>> {
    let exported = run("/usr/bin/defaults", &["export", domain, "-"], None)?;
    let extracted = run(
        "/usr/bin/plutil",
        &["-extract", key, "raw", "-o", "-", "-"],
        Some(&exported),
    )?;
    // A `Data` value comes back as base64, wrapped at 76 columns; the decoder
    // rejects the newlines that introduces.
    let encoded: Vec<u8> = extracted
        .into_iter()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()
}

/// Runs a command, optionally feeding it `input`, and returns stdout. `None` on
/// any failure: a missing domain or key is normal, not an error worth reporting.
fn run(program: &str, args: &[&str], input: Option<&[u8]>) -> Option<Vec<u8>> {
    use std::process::{Command, Stdio};
    let mut child = Command::new(program)
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let Some(bytes) = input {
        child.stdin.take()?.write_all(bytes).ok()?;
    }
    let output = child.wait_with_output().ok()?;
    if !output.status.success() || output.stdout.is_empty() {
        return None;
    }
    Some(output.stdout)
}
