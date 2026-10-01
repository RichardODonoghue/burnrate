//! Checking for, and installing, a newer release.
//!
//! `burnrate_core::updater` decides whether an update exists and verifies the
//! download against the release's own `SHA256SUMS`; this is the part that touches
//! the filesystem. Ad-hoc signed builds have no stable identity for a framework
//! like Sparkle to validate against, so the release's published checksum is the
//! trust anchor.
//!
//! In-place install is macOS only: it replaces the running `.app` and relaunches.
//! Elsewhere the update is reported and the release page is opened instead.
//!
//! The install is staged before anything is moved: download, verify, unpack and
//! *validate* (bundle id, version, code signature) all have to pass before the
//! running bundle is touched, and a failure while swapping rolls back.

use serde::Serialize;

// Only the macOS install touches paths and processes; gated with it so a Linux
// build does not warn about imports it cannot use.
#[cfg(any(target_os = "macos", test))]
use std::path::{Path, PathBuf};
#[cfg(any(target_os = "macos", test))]
use std::process::Command;
// `Stdio` belongs to the relaunch script alone, which is macOS-only.
#[cfg(target_os = "macos")]
use std::process::Stdio;

use burnrate_core::providers::UreqClient;
use burnrate_core::updater::{self, Release};

/// Whether this platform replaces itself, or hands over to the release page.
pub const CAN_INSTALL: bool = cfg!(target_os = "macos");

// The staging, validation and swap machinery below is macOS only: that is where
// the app replaces itself. `any(..., test)` rather than a plain macOS gate, so
// the swap and rollback tests still run — and are still type-checked — on the
// Linux CI runner, while a Linux *release* build warns about none of it.
//
// `current_bundle` and `relaunch_after_exit` are the exceptions: nothing but the
// macOS install calls them, so they are gated on macOS alone.

/// What the tray and the About pane need to know.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    /// The newer version, when there is one.
    pub available: Option<String>,
    /// A check or install is in flight; the tray row is disabled meanwhile.
    pub busy: bool,
    /// A short line for the UI: "up to date", "checking…", or why it failed.
    pub state: String,
    /// `false` on platforms that cannot replace themselves.
    pub can_install: bool,
}

impl UpdateStatus {
    pub fn idle() -> Self {
        Self {
            available: None,
            busy: false,
            state: "not checked yet".to_string(),
            can_install: CAN_INSTALL,
        }
    }

    fn failed(error: String) -> Self {
        Self {
            available: None,
            busy: false,
            state: error,
            can_install: CAN_INSTALL,
        }
    }
}

/// The version this build is. One source, from the workspace `Cargo.toml`.
pub fn current_version() -> String {
    burnrate_core::VERSION.to_string()
}

/// Asks GitHub for a newer release than `current`. Blocking — call it off the UI
/// thread.
pub fn check(current: &str) -> UpdateStatus {
    let client = UreqClient::default();
    match updater::fetch_latest(&client) {
        Ok(Some(release)) if updater::is_newer(&release.version, current) => UpdateStatus {
            available: Some(release.version.clone()),
            busy: false,
            state: format!("{} is available", release.version),
            can_install: CAN_INSTALL,
        },
        Ok(_) => UpdateStatus {
            available: None,
            busy: false,
            state: format!("up to date ({current})"),
            can_install: CAN_INSTALL,
        },
        Err(error) => UpdateStatus::failed(format!("could not check for updates: {error}")),
    }
}

#[cfg(any(target_os = "macos", test))]
/// Downloads, verifies and stages the release, returning the unpacked bundle.
///
/// Nothing in the running app is touched. Split out so the staging can be
/// exercised against a real release without installing it.
pub fn stage(release: &Release) -> Result<PathBuf, String> {
    let client = UreqClient::default();
    let bytes = updater::download_verified(&client, release)?;

    let dir = stage_directory();
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("cannot stage in {}: {error}", dir.display()))?;

    let zip = dir.join(&release.zip.name);
    std::fs::write(&zip, &bytes).map_err(|error| format!("cannot write the download: {error}"))?;

    let unpacked = dir.join("unpacked");
    std::fs::create_dir_all(&unpacked).map_err(|error| error.to_string())?;
    run(
        "/usr/bin/ditto",
        &[
            "-x".to_string(),
            "-k".to_string(),
            zip.to_string_lossy().into_owned(),
            unpacked.to_string_lossy().into_owned(),
        ],
    )
    .map_err(|error| format!("cannot unpack the download: {error}"))?;

    let bundle = unpacked.join(BUNDLE_NAME);
    if !bundle.is_dir() {
        return Err(format!("{BUNDLE_NAME} is missing from the archive"));
    }
    validate(&bundle, release)?;
    Ok(bundle)
}

/// Downloads, verifies, unpacks, validates and swaps in the release, then
/// relaunches. Returns once the replacement is in place — the caller is expected
/// to exit immediately afterwards.
#[cfg(target_os = "macos")]
pub fn install(release: &Release) -> Result<(), String> {
    let current = current_bundle()?;
    // Before the download, not after: a destination that cannot be written is not
    // fixed by having the bytes, and staging a release takes tens of megabytes to
    // discover that.
    ensure_installable(&current)?;
    let bundle = stage(release)?;
    replace_bundle(&current, &bundle)?;
    relaunch_after_exit(&current)?;
    Ok(())
}

/// Fetches, verifies and installs `version`, then relaunches.
///
/// The release is re-fetched rather than remembered, and refuses to install
/// anything whose version is not the one asked for — so the caller cannot aim the
/// installer at arbitrary bytes.
pub fn install_version(version: &str) -> Result<(), String> {
    let client = UreqClient::default();
    let release = updater::fetch_latest(&client)?.ok_or_else(|| "no release found".to_string())?;
    if release.version != version {
        return Err(format!(
            "the newest release is {} now, not {version}; check again",
            release.version
        ));
    }
    install(&release)
}

/// Not supported off macOS: the UI opens the release page instead.
#[cfg(not(target_os = "macos"))]
pub fn install(_release: &Release) -> Result<(), String> {
    Err("this platform installs from the release page".to_string())
}

#[cfg(any(target_os = "macos", test))]
pub const BUNDLE_NAME: &str = "BurnRate.app";

/// The marker at the front of a translocated bundle's path.
///
/// macOS runs a *quarantined* app that has never been moved — a downloaded one —
/// from a randomised read-only mount so it cannot modify itself, and this is what
/// that mount looks like: `/private/var/folders/…/AppTranslocation/<uuid>/d/…`.
/// Sparkle detects the same way; there is no public API for it.
#[cfg(any(target_os = "macos", test))]
const TRANSLOCATED_APP: &str = "/AppTranslocation/";

#[cfg(any(target_os = "macos", test))]
/// Refuses a destination that cannot be replaced, before anything is downloaded.
///
/// Two cases, and the message names the way out for each rather than reporting
/// the raw errno the swap would eventually fail with.
fn ensure_installable(current: &Path) -> Result<(), String> {
    if current.to_string_lossy().contains(TRANSLOCATED_APP) {
        return Err(format!(
            "{BUNDLE_NAME} is running from a temporary read-only copy that macOS made \
             because it was downloaded and never moved. Move {BUNDLE_NAME} to \
             /Applications, open it from there once, and updates install in place."
        ));
    }
    let parent = current
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", current.display()))?;
    if !parent.is_dir() {
        return Err(format!("{} is not a directory", parent.display()));
    }
    // An attempt, not a permission bit: the parent can be read-only for reasons
    // the mode does not show — a mounted disk image, a network volume, a
    // root-owned directory — and only writing says which.
    let probe = parent.join(format!(".{BUNDLE_NAME}.write-test"));
    match std::fs::write(&probe, b"") {
        Ok(()) => {
            let _ = std::fs::remove_file(&probe);
            Ok(())
        }
        Err(error) => Err(format!(
            "cannot write in {}, so {BUNDLE_NAME} cannot replace itself there. Move it \
             somewhere writable, such as /Applications, and update again: {error}",
            parent.display()
        )),
    }
}

#[cfg(any(target_os = "macos", test))]
/// Where a download is staged. Keyed by pid so two attempts cannot collide.
fn stage_directory() -> PathBuf {
    std::env::temp_dir().join(format!("burnrate-update-{}", std::process::id()))
}

#[cfg(target_os = "macos")]
/// The running `.app`, derived from the executable path:
/// `…/BurnRate.app/Contents/MacOS/burnrate-desktop`.
fn current_bundle() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|error| error.to_string())?;
    exe.parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| format!("cannot locate the running bundle from {}", exe.display()))
}

#[cfg(any(target_os = "macos", test))]
/// The archive has to be a BurnRate build of the version we asked for, and it has
/// to have a signature that verifies, before it goes anywhere near the disk.
fn validate(bundle: &Path, release: &Release) -> Result<(), String> {
    let plist = bundle.join("Contents/Info.plist");
    let identifier = plist_value(&plist, "CFBundleIdentifier")?;
    if identifier != BUNDLE_IDENTIFIER {
        return Err(format!(
            "the download is {} (a {identifier} bundle), not {BUNDLE_IDENTIFIER}",
            release.version
        ));
    }
    let version = plist_value(&plist, "CFBundleShortVersionString")?;
    if version != release.version {
        return Err(format!(
            "the download says version {version}, but the release is {}",
            release.version
        ));
    }
    run(
        "/usr/bin/codesign",
        &[
            "--verify".to_string(),
            "--deep".to_string(),
            bundle.to_string_lossy().into_owned(),
        ],
    )
    .map_err(|error| format!("the download's signature failed: {error}"))?;
    Ok(())
}

#[cfg(any(target_os = "macos", test))]
fn plist_value(plist: &Path, key: &str) -> Result<String, String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw"])
        .arg(plist)
        .output()
        .map_err(|error| format!("plutil: {error}"))?;
    if !output.status.success() {
        return Err(format!("the download's Info.plist has no {key}"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(any(target_os = "macos", test))]
/// Moves `current` aside and puts `new` in its place, rolling back if the second
/// move fails.
///
/// Parameterised rather than reaching for the running bundle so the swap and its
/// rollback can be tested without replacing the app under test.
pub fn replace_bundle(current: &Path, new: &Path) -> Result<(), String> {
    let parent = current
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", current.display()))?;
    if !parent.is_dir() {
        return Err(format!("{} is not a directory", parent.display()));
    }
    let backup = parent.join(format!("{BUNDLE_NAME}.replaced-{}", std::process::id()));

    std::fs::rename(current, &backup).map_err(|error| {
        format!(
            "cannot move the running app aside in {}; move BurnRate somewhere writable, or update manually: {error}",
            parent.display()
        )
    })?;
    if let Err(error) = std::fs::rename(new, current) {
        // Put the old bundle back rather than leaving the user with none.
        let _ = std::fs::rename(&backup, current);
        return Err(format!("cannot place the new app: {error}"));
    }

    // Ad-hoc signed, so a quarantined copy would be refused on first launch.
    // Swift stripped this defensively for the same reason.
    let _ = Command::new("/usr/bin/xattr")
        .args(["-dr", "com.apple.quarantine"])
        .arg(current)
        .status();
    let _ = std::fs::remove_dir_all(&backup);
    Ok(())
}

/// The script that waits for this process to exit and then reopens the app.
///
/// The bundle path is **not** interpolated into it. It arrives as `$1`, so a path
/// containing a quote, `$( )` or a semicolon is ordinary text to the shell rather
/// than syntax — interpolating it would make the install directory a command
/// injection, since the updater runs this on the way out.
///
/// The wait itself matters: opening immediately would leave two copies running,
/// and the single-instance guard would then kill the new one.
#[cfg(any(target_os = "macos", test))]
fn relaunch_script(pid: u32) -> String {
    format!("while kill -0 {pid} 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$1\"")
}

/// Relaunches once this process is gone.
#[cfg(target_os = "macos")]
fn relaunch_after_exit(bundle: &Path) -> Result<(), String> {
    Command::new("/bin/sh")
        .arg("-c")
        .arg(relaunch_script(std::process::id()))
        // `$0` for the shell, then the path as `$1`.
        .arg("sh")
        .arg(bundle)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("cannot relaunch: {error}"))?;
    Ok(())
}

#[cfg(any(target_os = "macos", test))]
fn run(program: &str, args: &[String]) -> Result<(), String> {
    let status = Command::new(program)
        .args(args)
        .status()
        .map_err(|error| format!("{program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} exited with {status}"))
    }
}

#[cfg(any(target_os = "macos", test))]
/// The bundle id the download must carry. Matches `tauri.conf.json`'s
/// `identifier`, and the Swift app's, which is why an update to a Swift install
/// and one to a Tauri install are the same app.
pub const BUNDLE_IDENTIFIER: &str = "com.burnrate.desktop";

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("burnrate-swap-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
        std::fs::write(path, text).expect("write");
    }

    /// The happy path: the old bundle is moved aside and the new one takes its
    /// place.
    #[test]
    fn the_swap_replaces_the_bundle() {
        let dir = temp("replace");
        let current = dir.join(BUNDLE_NAME);
        write(&current.join("Contents/version"), "old");
        let new = dir.join("new.app");
        write(&new.join("Contents/version"), "new");

        replace_bundle(&current, &new).expect("swap");

        assert_eq!(
            std::fs::read_to_string(current.join("Contents/version")).expect("read"),
            "new"
        );
        // And the replacement is not left lying around.
        assert!(!new.exists(), "the staged bundle should have been moved");
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .expect("read dir")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.contains("replaced-"))
            .collect();
        assert!(leftovers.is_empty(), "backup left behind: {leftovers:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A swap that cannot place the new bundle puts the old one back. Leaving the
    /// user with no app at all is the failure this exists to prevent.
    #[test]
    fn a_failed_swap_rolls_back() {
        let dir = temp("rollback");
        let current = dir.join(BUNDLE_NAME);
        write(&current.join("Contents/version"), "old");
        // A staged bundle that does not exist: the second rename fails.
        let missing = dir.join("never-staged.app");

        let error = replace_bundle(&current, &missing).expect_err("must fail");
        assert!(error.contains("cannot place"), "got {error}");
        assert_eq!(
            std::fs::read_to_string(current.join("Contents/version")).expect("read"),
            "old",
            "the original bundle must be back in place"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The bundle path is passed as `$1`, so a hostile install directory is
    /// inert. This exercises the real mechanism through `sh`, with the wait and
    /// the `open` replaced by something harmless.
    #[cfg(unix)]
    #[test]
    fn a_hostile_bundle_path_is_not_executed() {
        let dir = std::env::temp_dir().join(format!("burnrate-hostile-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let marker = dir.join("marker");
        let hostile = dir.join(format!(
            "$(touch {m})`touch {m}`;touch {m}",
            m = marker.display()
        ));

        let output = Command::new("/bin/sh")
            .arg("-c")
            .arg("printf %s \"$1\"")
            .arg("sh")
            .arg(&hostile)
            .output()
            .expect("sh runs");
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            hostile.to_string_lossy(),
            "the path must arrive verbatim"
        );
        assert!(!marker.exists(), "the path was executed as shell text");

        let script = relaunch_script(4242);
        assert!(script.contains("kill -0 4242"), "{script}");
        assert!(
            script.contains("\"$1\""),
            "the path arrives as an argument: {script}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unwritable_parent_is_reported() {
        let error = replace_bundle(
            Path::new("/definitely/not/here/BurnRate.app"),
            Path::new("/tmp/whatever.app"),
        )
        .expect_err("must fail");
        assert!(error.contains("not a directory"), "got {error}");
    }

    #[test]
    fn a_translocated_copy_is_refused_before_downloading() {
        let error = ensure_installable(Path::new(
            "/private/var/folders/bw/zz/T/AppTranslocation/66A65D2C-AB73/d/BurnRate.app",
        ))
        .expect_err("a translocated copy cannot replace itself");
        assert!(error.contains("read-only"), "got {error}");
        assert!(
            error.contains("/Applications"),
            "the message has to name the way out: {error}"
        );
        assert!(
            !error.contains("os error"),
            "a raw errno is what this check exists to avoid: {error}"
        );
    }

    #[test]
    fn a_writable_destination_is_accepted() {
        let dir = temp("installable");
        let current = dir.join(BUNDLE_NAME);
        std::fs::create_dir_all(&current).expect("bundle");
        ensure_installable(&current).expect("a temp dir is writable");

        // The probe is a real file in the destination, so it must not survive.
        let strays = std::fs::read_dir(&dir)
            .expect("read")
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.contains("write-test"))
            .count();
        assert_eq!(strays, 0, "ensure_installable left its probe behind");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn a_read_only_destination_is_refused_before_downloading() {
        use std::os::unix::fs::PermissionsExt;

        let dir = temp("read-only");
        let current = dir.join(BUNDLE_NAME);
        std::fs::create_dir_all(&current).expect("bundle");

        let mut perms = std::fs::metadata(&dir).expect("metadata").permissions();
        perms.set_mode(0o500);
        std::fs::set_permissions(&dir, perms).expect("chmod");

        // Root ignores mode bits, so let the environment say whether the assertion
        // means anything here rather than assuming which user runs the suite.
        let writable = std::fs::write(dir.join(".probe"), b"").is_ok();
        if writable {
            let _ = std::fs::remove_file(dir.join(".probe"));
            eprintln!("skipped: this user writes to a 0500 directory anyway");
        } else {
            let error = ensure_installable(&current).expect_err("must refuse");
            assert!(error.contains("cannot write"), "got {error}");
            assert!(
                error.contains("/Applications"),
                "the message has to name the way out: {error}"
            );
        }

        let mut perms = std::fs::metadata(&dir).expect("metadata").permissions();
        perms.set_mode(0o700);
        let _ = std::fs::set_permissions(&dir, perms);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The real thing, against the real release.
    ///
    /// Ignored by default: it downloads the latest release from GitHub and needs
    /// the network. Run it with
    ///
    /// ```text
    /// cargo test -p burnrate-desktop -- --ignored --nocapture real_release
    /// ```
    ///
    /// This is the check that matters for the updater: it proves the *published*
    /// artifact passes the same verification an install performs — the checksum
    /// in the release's own `SHA256SUMS`, the bundle identifier, the version, and
    /// `codesign --verify --deep`. If the release's ad-hoc signature does not
    /// verify, every install refuses it, and that cannot be seen from a unit test.
    #[test]
    #[ignore = "downloads a release from GitHub"]
    fn a_real_release_is_fetched_verified_and_validated() {
        let client = UreqClient::default();
        let release = updater::fetch_latest(&client)
            .expect("the API is reachable")
            .expect("there is a release");
        println!("latest release: {} ({})", release.version, release.zip.name);

        let bundle = stage(&release).expect("stages and validates");
        let plist = bundle.join("Contents/Info.plist");
        assert_eq!(
            plist_value(&plist, "CFBundleIdentifier").expect("identifier"),
            BUNDLE_IDENTIFIER
        );
        assert_eq!(
            plist_value(&plist, "CFBundleShortVersionString").expect("version"),
            release.version
        );
        println!("staged and validated: {}", bundle.display());
        let _ = std::fs::remove_dir_all(stage_directory());
    }
}
