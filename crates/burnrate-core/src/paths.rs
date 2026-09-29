//! Platform seams: filesystem locations, credential reading, and SQLite.
//!
//! Ported 1:1 from `Sources/BurnRateCore/Platform.swift`, with one deliberate
//! change: SQLite is linked (`rusqlite`, bundled) rather than shelled out to
//! `/usr/bin/sqlite3`, because that binary is not present on a stock Fedora or
//! Debian install and its absence used to look like "no usage found".

use std::path::{Path, PathBuf};

/// Filesystem locations the app uses. Per-platform layouts are resolved here so
/// the rest of the core stays platform-free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppPaths {
    home: PathBuf,
    app_support: PathBuf,
}

impl AppPaths {
    /// Resolves the real locations for the current platform and user.
    pub fn detect() -> Self {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("USERPROFILE").map(PathBuf::from))
            .unwrap_or_else(|| PathBuf::from("/"));
        let app_support = if cfg!(target_os = "macos") {
            home.join("Library").join("Application Support")
        } else if cfg!(target_os = "windows") {
            // %APPDATA%, else ~/AppData/Roaming
            std::env::var_os("APPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("AppData").join("Roaming"))
        } else {
            config_directory_for(&home)
        };
        Self { home, app_support }
    }

    /// For tests: an explicit layout.
    pub fn with_layout(home: impl Into<PathBuf>, app_support: impl Into<PathBuf>) -> Self {
        Self { home: home.into(), app_support: app_support.into() }
    }

    pub fn home_directory(&self) -> &Path {
        &self.home
    }

    pub fn application_support_directory(&self) -> &Path {
        &self.app_support
    }

    /// Per-app data directory (created lazily by callers).
    pub fn app_directory(&self) -> PathBuf {
        self.app_support.join("BurnRate")
    }

    /// XDG data dir on Linux (`$XDG_DATA_HOME`, else `~/.local/share`).
    pub fn data_directory(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            return self.home.join(".local").join("share");
        }
        config_directory_for_data(&self.home)
    }

    /// XDG config dir on Linux (`$XDG_CONFIG_HOME`, else `~/.config`).
    pub fn config_directory(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            return self.home.join(".config");
        }
        config_directory_for(&self.home)
    }

    /// Where settings and cached history live.
    pub fn settings_file(&self) -> PathBuf {
        self.app_directory().join("settings.json")
    }

    /// Creates the app directory, returning it.
    pub fn ensure_app_directory(&self) -> std::io::Result<PathBuf> {
        let dir = self.app_directory();
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }
}

fn non_empty_env(key: &str) -> Option<PathBuf> {
    std::env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn config_directory_for(home: &Path) -> PathBuf {
    non_empty_env("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"))
}

fn config_directory_for_data(home: &Path) -> PathBuf {
    non_empty_env("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local").join("share"))
}

/// Reads a generic password / secret. macOS reads the Keychain; platforms
/// without a secret store always miss, and the CLI dotfiles are used instead.
pub trait CredentialReading: Send + Sync {
    /// Raw secret bytes for `service`, or `None` when absent.
    fn generic_password(&self, service: &str) -> Option<Vec<u8>>;
}

/// Credential reader for platforms without a secret store.
pub struct NoopCredentialReader;

impl CredentialReading for NoopCredentialReader {
    fn generic_password(&self, _service: &str) -> Option<Vec<u8>> {
        None
    }
}

/// macOS Keychain reader, via the `security` CLI. Deliberately not a link
/// against Security.framework: shelling out works from a sandboxed Tauri app
/// without an entitlement, and the call is once per poll at most.
pub struct KeychainCredentialReader {
    binary: PathBuf,
}

impl Default for KeychainCredentialReader {
    fn default() -> Self {
        Self::new("/usr/bin/security")
    }
}

impl KeychainCredentialReader {
    pub fn new(binary: impl Into<PathBuf>) -> Self {
        Self { binary: binary.into() }
    }
}

impl CredentialReading for KeychainCredentialReader {
    fn generic_password(&self, service: &str) -> Option<Vec<u8>> {
        let output = std::process::Command::new(&self.binary)
            .args([
                "find-generic-password",
                "-s",
                service,
                "-w",
            ])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let value = String::from_utf8(output.stdout).ok()?;
        Some(value.trim_end().as_bytes().to_vec())
    }
}

/// Errors from a read-only SQLite query.
#[derive(Debug, thiserror::Error)]
pub enum SqliteError {
    #[error("cannot open {path}: {source}")]
    Open { path: String, source: rusqlite::Error },
    #[error("query failed: {0}")]
    Query(#[from] rusqlite::Error),
}

/// Runs a read-only query against a SQLite database.
///
/// Opened read-only so a live OpenCode database (WAL mode, actively written)
/// is never modified or locked, and `busy_timeout` is set because the CLI is
/// usually mid-write.
pub struct SqliteReader;

impl SqliteReader {
    pub fn new() -> Self {
        Self
    }

    /// Runs `sql` and returns rows as tab-separated strings, newline-delimited —
    /// the same shape the Swift `ProcessSQLiteRunner` produced.
    pub fn query(&self, database_at: &Path, sql: &str) -> Result<String, SqliteError> {
        if !database_at.exists() {
            return Err(SqliteError::Open {
                path: database_at.display().to_string(),
                source: rusqlite::Error::InvalidPath(database_at.to_path_buf()),
            });
        }
        let connection = rusqlite::Connection::open_with_flags(
            database_at,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                | rusqlite::OpenFlags::SQLITE_OPEN_URI
                | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|source| SqliteError::Open {
            path: database_at.display().to_string(),
            source,
        })?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;

        let mut statement = connection.prepare(sql)?;
        let column_count = statement.column_count();
        let mut rows = statement.query([])?;
        let mut out = String::new();
        while let Some(row) = rows.next()? {
            for index in 0..column_count {
                if index > 0 {
                    out.push('\t');
                }
                let text: String = match row.get_ref(index)? {
                    rusqlite::types::ValueRef::Null => String::new(),
                    rusqlite::types::ValueRef::Integer(value) => value.to_string(),
                    rusqlite::types::ValueRef::Real(value) => value.to_string(),
                    rusqlite::types::ValueRef::Text(bytes) => {
                        String::from_utf8_lossy(bytes).into_owned()
                    }
                    rusqlite::types::ValueRef::Blob(bytes) => {
                        String::from_utf8_lossy(bytes).into_owned()
                    }
                };
                out.push_str(&text);
            }
            out.push('\n');
        }
        Ok(out)
    }
}

impl Default for SqliteReader {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("burnrate-paths-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// `fileManagerPathsAppendsAppName` — the per-app directory is nested.
    #[test]
    fn app_directory_is_under_application_support() {
        let home = temp_home("appdir");
        let paths = AppPaths::with_layout(&home, home.join("Library/Application Support"));
        assert_eq!(paths.app_directory(), home.join("Library/Application Support/BurnRate"));
        assert_eq!(
            paths.settings_file(),
            home.join("Library/Application Support/BurnRate/settings.json")
        );
    }

    /// macOS keeps OpenCode's data in ~/.local/share regardless of XDG vars.
    #[test]
    fn macos_data_directory_ignores_xdg() {
        let home = temp_home("macos");
        let paths = AppPaths::with_layout(&home, home.join("Library/Application Support"));
        assert_eq!(paths.data_directory(), home.join(".local/share"));
        assert_eq!(paths.config_directory(), home.join(".config"));
    }

    #[test]
    fn xdg_data_home_is_honoured_on_unix() {
        let home = temp_home("xdg");
        // serialised: mutates process env
        std::env::set_var("XDG_DATA_HOME", "/tmp/xdg-data-test");
        let expected = if cfg!(target_os = "macos") {
            home.join(".local/share")
        } else {
            PathBuf::from("/tmp/xdg-data-test")
        };
        let paths = AppPaths::with_layout(&home, home.join(".config"));
        assert_eq!(paths.data_directory(), expected);
        std::env::remove_var("XDG_DATA_HOME");
    }

    /// The Keychain reader misses cleanly when `security` is absent, rather
    /// than panicking or blocking.
    #[test]
    fn keychain_reader_misses_without_the_binary() {
        let reader = KeychainCredentialReader::new("/nonexistent/security");
        assert!(reader.generic_password("Claude Code-credentials").is_none());
    }

    #[test]
    fn noop_credential_reader_always_misses() {
        assert!(NoopCredentialReader.generic_password("anything").is_none());
    }

    /// A missing database is an error, not an empty result — the difference
    /// between "no data" and "no database" used to be invisible.
    #[test]
    fn sqlite_reports_a_missing_database() {
        let home = temp_home("sqlite");
        let missing = home.join("nope.db");
        let error = SqliteReader::new().query(&missing, "SELECT 1;").unwrap_err();
        assert!(error.to_string().contains("cannot open"));
    }

    /// A real round trip, including a NULL rendering as an empty field.
    #[test]
    fn sqlite_queries_return_tab_separated_rows() {
        use rusqlite::Connection;
        let home = temp_home("sqlite-ok");
        let path = home.join("test.db");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch("CREATE TABLE t(a TEXT, b INTEGER, c REAL);")
                .unwrap();
            connection
                .execute("INSERT INTO t VALUES ('x', 7, 1.5), (NULL, 2, 0.5);", [])
                .unwrap();
        }
        let output = SqliteReader::new().query(&path, "SELECT a, b, c FROM t;").unwrap();
        assert_eq!(output, "x\t7\t1.5\n\t2\t0.5\n");
    }
}
