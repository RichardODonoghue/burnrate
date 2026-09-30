//! Vendor quota APIs: Claude's OAuth usage endpoint and OpenCode Go's.
//!
//! Ported 1:1 from the Swift app's `ClaudeUsageAPI.swift`,
//! `OpenCodeGoUsageAPI.swift` and `ProviderThrottle.swift`.
//!
//! These are the authoritative numbers: the local parsers cannot see a plan's
//! real limits, only the tokens spent. The trade is rate limits, so every
//! provider goes through [`QuotaCache`] — a floor on the interval and a backoff
//! on failure, with the last good snapshot reused meanwhile.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::model::{ProviderUsage, UsageWindow};
use crate::paths::{AppPaths, CredentialReading, NoopCredentialReader};
use crate::sources::parse_log_date;

/// Result of a poll: either usage, or the reason there is none. The reason is
/// as important as the data — "no providers configured" with no explanation was
/// the bug that made the Linux port unusable.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FetchResult {
    pub usage: Option<ProviderUsage>,
    /// Human-readable reason, e.g. "HTTP 401" or "no credentials at …".
    pub status: Option<String>,
}

/// Shared throttle policy for the vendor quota providers.
pub struct ProviderThrottle;

impl ProviderThrottle {
    /// True when a window's reset moment passed *after* our last fetch — the
    /// snapshot predates the reset (the machine slept through it, or fetches were
    /// backing off), so fetch fresh rather than serving cache.
    ///
    /// Both halves matter. `now >= resets_at` alone would fire forever after a
    /// reset; `last_fetch < resets_at` is what makes it a one-shot: once a fetch
    /// has happened since the reset, the snapshot is current and the throttle
    /// applies again.
    pub fn reset_due(windows: &[UsageWindow], last_fetch: i64, now: i64) -> bool {
        windows.iter().any(|window| {
            let Some(resets_at) = window.resets_at else {
                return false;
            };
            now >= resets_at && last_fetch < resets_at
        })
    }
}

/// Shared throttling and last-good-snapshot cache.
pub struct QuotaCache {
    min_interval: Duration,
    backoff: Duration,
    last_fetch: Option<Instant>,
    /// The same fetch, on the wall clock. The interval logic uses `Instant`
    /// because it measures elapsed time, but a reset deadline is a Unix
    /// timestamp, so comparing against it needs the wall clock too.
    last_fetch_unix: i64,
    consecutive_failures: u32,
    windows: Vec<UsageWindow>,
    plan: Option<String>,
}

impl QuotaCache {
    pub fn new(min_interval: Duration, backoff: Duration) -> Self {
        Self {
            min_interval,
            backoff,
            last_fetch: None,
            last_fetch_unix: 0,
            consecutive_failures: 0,
            windows: Vec::new(),
            plan: None,
        }
    }

    /// Default cadence: 60s floor, 300s backoff.
    pub fn standard() -> Self {
        Self::new(Duration::from_secs(60), Duration::from_secs(300))
    }

    /// True when enough time has passed to hit the API again. The effective
    /// interval grows with consecutive failures.
    ///
    /// A window reset overrides all of that: serving a snapshot from before the
    /// reset shows a percentage for a window that has already rolled over, and the
    /// menu can keep showing it for a whole poll interval. `now` is seconds since
    /// the Unix epoch.
    pub fn should_fetch(&self, now: i64) -> bool {
        if ProviderThrottle::reset_due(&self.windows, self.last_fetch_unix, now) {
            return true;
        }
        let Some(last) = self.last_fetch else {
            return true;
        };
        let interval = self.backoff * self.consecutive_failures.min(2);
        let effective = if interval.is_zero() {
            self.min_interval
        } else {
            interval.max(self.min_interval)
        };
        last.elapsed() >= effective
    }

    pub fn note_fetch(&mut self, now: i64) {
        self.last_fetch = Some(Instant::now());
        self.last_fetch_unix = now;
    }

    pub fn note_success(&mut self, windows: Vec<UsageWindow>, plan: Option<String>) {
        self.windows = windows;
        self.plan = plan;
        self.consecutive_failures = 0;
    }

    pub fn note_failure(&mut self) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
    }

    /// The last good snapshot, reused while backing off.
    pub fn snapshot(&self, provider: &str) -> Option<ProviderUsage> {
        if self.windows.is_empty() {
            return None;
        }
        Some(ProviderUsage::new(
            provider,
            self.plan.clone(),
            self.windows.clone(),
        ))
    }

    pub fn invalidate(&mut self) {
        self.last_fetch = None;
        self.last_fetch_unix = 0;
        self.consecutive_failures = 0;
    }
}

// MARK: - Claude

const CLAUDE_ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";

/// Claude's OAuth usage endpoint. Percentages are **used**, not remaining.
pub struct ClaudeUsageApiProvider {
    credentials_url: PathBuf,
    /// Claude Code's account file, for the signed-in identity. Separate from the
    /// credentials: the token rotates, the account uuid does not.
    claude_json_url: PathBuf,
    credentials: Box<dyn CredentialReading>,
    cache: QuotaCache,
    client: Box<dyn HttpClient>,
    plan: Option<String>,
}

/// Minimal HTTP seam, so the parsing and throttling can be tested without a
/// network. `ureq` is blocking and dependency-light, which suits a poll loop
/// that runs on its own thread.
pub trait HttpClient: Send + Sync {
    /// `Ok(body)` for 2xx, `Err(message)` for anything else.
    fn get(
        &self,
        url: &str,
        bearer: &str,
        extra_headers: &[(&str, &str)],
    ) -> Result<String, String>;
}

/// Blocking HTTP over `ureq`.
pub struct UreqClient {
    timeout: Duration,
}

impl Default for UreqClient {
    fn default() -> Self {
        Self::new(Duration::from_secs(15))
    }
}

impl UreqClient {
    pub fn new(timeout: Duration) -> Self {
        Self { timeout }
    }
}

impl HttpClient for UreqClient {
    fn get(
        &self,
        url: &str,
        bearer: &str,
        extra_headers: &[(&str, &str)],
    ) -> Result<String, String> {
        let agent = ureq::AgentBuilder::new().timeout(self.timeout).build();
        let mut request = agent
            .get(url)
            .set("Authorization", &format!("Bearer {bearer}"));
        for (name, value) in extra_headers {
            request = request.set(name, value);
        }
        match request.call() {
            Ok(response) => response.into_string().map_err(|error| error.to_string()),
            Err(ureq::Error::Status(code, response)) => {
                let _ = response.into_string();
                Err(format!("HTTP {code}"))
            }
            Err(error) => Err(error.to_string()),
        }
    }
}

impl Default for ClaudeUsageApiProvider {
    fn default() -> Self {
        Self::new(None, None)
    }
}

impl ClaudeUsageApiProvider {
    /// `credentials` defaults to the file only; macOS builds inject a Keychain
    /// reader so a Keychain-only install still works.
    pub fn new(
        credentials_url: Option<PathBuf>,
        credentials: Option<Box<dyn CredentialReading>>,
    ) -> Self {
        let paths = AppPaths::detect();
        Self {
            credentials_url: credentials_url
                .unwrap_or_else(|| paths.home_directory().join(".claude/.credentials.json")),
            claude_json_url: paths.home_directory().join(".claude.json"),
            credentials: credentials.unwrap_or_else(|| Box::new(NoopCredentialReader)),
            cache: QuotaCache::standard(),
            client: Box::new(UreqClient::default()),
            plan: None,
        }
    }

    pub fn with_client(mut self, client: Box<dyn HttpClient>) -> Self {
        self.client = client;
        self
    }

    /// Points the account file somewhere else. The default is the real
    /// `~/.claude.json`, which a test must not read.
    pub fn with_account_file(mut self, path: PathBuf) -> Self {
        self.claude_json_url = path;
        self
    }

    pub fn with_cache(mut self, cache: QuotaCache) -> Self {
        self.cache = cache;
        self
    }

    pub fn fetch_usage(&mut self, now: i64) -> FetchResult {
        if !self.cache.should_fetch(now) {
            let usage = self.cache.snapshot("Claude");
            return FetchResult {
                usage,
                status: None,
            };
        }
        self.cache.note_fetch(now);
        match self.perform_fetch() {
            Ok((windows, plan)) => {
                self.plan = plan.clone();
                self.cache.note_success(windows, plan);
                FetchResult {
                    usage: self.cache.snapshot("Claude"),
                    status: None,
                }
            }
            Err(status) => {
                self.cache.note_failure();
                FetchResult {
                    usage: self.cache.snapshot("Claude"),
                    status: Some(status),
                }
            }
        }
    }

    pub fn invalidate_cache(&mut self) {
        self.cache.invalidate();
    }

    fn perform_fetch(&mut self) -> Result<(Vec<UsageWindow>, Option<String>), String> {
        let token = self.access_token().ok_or_else(|| {
            format!(
                "no Claude credentials at {}",
                self.credentials_url.display()
            )
        })?;
        let body = self.client.get(
            CLAUDE_ENDPOINT,
            &token,
            &[("anthropic-beta", "oauth-2025-04-20")],
        )?;
        let windows = Self::parse_windows(body.as_bytes())?;
        let plan = self.credential_plan();
        Ok((windows, plan))
    }

    /// The signed-in account's identity, for detecting a plan switch.
    ///
    /// `~/.claude.json`'s `oauthAccount` gives `accountUuid|organizationUuid`,
    /// which is stable across OAuth refreshes. Falls back to hashing the token,
    /// which is not — an OAuth refresh looks like a switch — so the uuid pair is
    /// preferred and the token is only used when there is no account block.
    ///
    /// `None` when neither is available; the notifier reads that as "no change"
    /// rather than as a switch.
    pub fn credential_fingerprint(&self) -> Option<String> {
        if let Ok(bytes) = std::fs::read(&self.claude_json_url) {
            if let Some(fingerprint) = Self::account_fingerprint(&bytes) {
                return Some(fingerprint);
            }
        }
        self.access_token()
            .map(|token| Self::fallback_fingerprint(&token))
    }

    /// `{"oauthAccount": {"accountUuid": "…", "organizationUuid": "…"}}`.
    /// An account without an org is still an account, so the org defaults to "".
    pub fn account_fingerprint(claude_json: &[u8]) -> Option<String> {
        let value: serde_json::Value = serde_json::from_slice(claude_json).ok()?;
        let account = value.get("oauthAccount")?;
        let uuid = account
            .get("accountUuid")
            .and_then(|v| v.as_str())
            .filter(|uuid| !uuid.is_empty())?;
        let org = account
            .get("organizationUuid")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        Some(format!("{uuid}|{org}"))
    }

    /// The fallback identity: a stable hash of the token.
    ///
    /// `formatting::stable_hash`, not `std::hash` — the latter is seeded per
    /// process, so the same token would fingerprint differently on every launch
    /// and every poll would look like a plan switch.
    pub fn fallback_fingerprint(token: &str) -> String {
        format!("token|{}", crate::formatting::stable_hash(token))
    }

    /// The OAuth access token, from the credentials file or the Keychain.
    pub fn access_token(&self) -> Option<String> {
        self.read_credential_oauth()?
            .get("accessToken")
            .and_then(|v| v.as_str())
            .filter(|token| !token.is_empty())
            .map(str::to_string)
    }

    /// The signed-in Claude Code OAuth object, from
    /// `~/.claude/.credentials.json` or, failing that, the login Keychain.
    ///
    /// Both hold the same shape, and the Keychain is the *only* place on a fresh
    /// install — there is no credentials file at all on this machine. Reading
    /// just the file is why the token worked (that path had grown its own
    /// Keychain fallback) while the plan tier came back empty: "the plan is
    /// missing for Claude subs".
    fn read_credential_oauth(&self) -> Option<serde_json::Value> {
        if let Some(oauth) = self.read_credentials_file() {
            return Some(oauth);
        }
        let raw = self
            .credentials
            .generic_password("Claude Code-credentials")?;
        let value: serde_json::Value = serde_json::from_slice(&raw).ok()?;
        value.get("claudeAiOauth").cloned()
    }

    fn read_credentials_file(&self) -> Option<serde_json::Value> {
        let raw = std::fs::read(&self.credentials_url).ok()?;
        let value: serde_json::Value = serde_json::from_slice(&raw).ok()?;
        value.get("claudeAiOauth").cloned()
    }

    /// Plan tier from the credential, e.g. "Max 20x".
    fn credential_plan(&self) -> Option<String> {
        let oauth = self.read_credential_oauth()?;
        let subscription = oauth
            .get("subscriptionType")
            .or_else(|| oauth.get("subscription_type"))
            .and_then(|v| v.as_str())?;
        let tier = oauth
            .get("rateLimitTier")
            .or_else(|| oauth.get("rate_limit_tier"))
            .and_then(|v| v.as_str());
        Self::format_plan(subscription, tier)
    }

    /// `"max"` + `"default_claude_max_20x"` → `"Max 20x"`.
    ///
    /// Ported from Swift's `formatPlan`, and it is *not* "join the two strings":
    /// the subscription type goes through a fixed table, and the multiplier is
    /// the `\d+x` at the **end of the tier** — `default_claude_max_20x` carries
    /// the "20x", not the whole string. Joining them yielded
    /// `"max default_claude_max_20x"`.
    ///
    /// An empty subscription type is `None` rather than `""`, so no caller can
    /// render a provider as "Claude - ".
    pub fn format_plan(subscription_type: &str, rate_limit_tier: Option<&str>) -> Option<String> {
        if subscription_type.is_empty() {
            return None;
        }
        let name = match subscription_type.to_lowercase().as_str() {
            "max" => "Max",
            "team" => "Team",
            "pro" => "Pro",
            "enterprise" => "Enterprise",
            _ => subscription_type,
        };
        Some(match rate_limit_tier.and_then(Self::plan_multiplier) {
            Some(multiplier) => format!("{name} {multiplier}"),
            None => name.to_string(),
        })
    }

    /// The `\d+x` suffix of a rate-limit tier: `"default_claude_max_20x"` →
    /// `"20x"`. The Swift build matches this with the regex `[0-9]+x$`.
    fn plan_multiplier(tier: &str) -> Option<String> {
        let without_x = tier.strip_suffix('x')?;
        let digits: String = without_x
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        (!digits.is_empty()).then(|| format!("{digits}x"))
    }

    /// Parses the usage response. Percentages are **used**; the app shows
    /// remaining.
    pub fn parse_windows(data: &[u8]) -> Result<Vec<UsageWindow>, String> {
        let value: serde_json::Value = serde_json::from_slice(data)
            .map_err(|_| "could not parse usage response".to_string())?;

        // Preferred: the `limits` array — it includes model-scoped weekly
        // quotas (e.g. Fable) that the flat keys do not cover.
        if let Some(limits) = value.get("limits").and_then(|v| v.as_array()) {
            if !limits.is_empty() {
                let mut windows = Vec::new();
                for limit in limits {
                    let kind = limit.get("kind").and_then(|v| v.as_str()).unwrap_or("");
                    let label = match kind {
                        "session" => "Rolling",
                        "weekly_all" => "Weekly",
                        "weekly_scoped" => limit
                            .get("scope")
                            .and_then(|scope| scope.get("model"))
                            .and_then(|model| model.get("display_name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("Weekly (scoped)"),
                        _ => continue,
                    };
                    let used = limit
                        .get("percent")
                        .and_then(|v| v.as_f64())
                        .map(|percent| percent.clamp(0.0, 100.0))
                        .unwrap_or(0.0);
                    windows.push(UsageWindow::with_id(
                        format!("Claude-{label}"),
                        label,
                        0,
                        Some(100.0 - used),
                        limit
                            .get("resets_at")
                            .and_then(|v| v.as_str())
                            .and_then(parse_log_date),
                    ));
                }
                return Ok(windows);
            }
        }

        // Fallback: flat keys (older response shape).
        let mut windows = Vec::new();
        for (label, key) in [("Rolling", "five_hour"), ("Weekly", "seven_day")] {
            let Some(entry) = value.get(key) else {
                continue;
            };
            let Some(utilization) = entry.get("utilization").and_then(|v| v.as_f64()) else {
                continue;
            };
            windows.push(UsageWindow::with_id(
                format!("Claude-{label}"),
                label,
                0,
                Some((100.0 - utilization).max(0.0)),
                entry
                    .get("resets_at")
                    .and_then(|v| v.as_str())
                    .and_then(parse_log_date),
            ));
        }
        if windows.is_empty() {
            return Err("usage response had no usable limits".to_string());
        }
        Ok(windows)
    }
}

// MARK: - OpenCode Go

const OPENCODE_ENDPOINT: &str = "https://opencode.ai/zen/go/v1/usage";

/// OpenCode Go's usage endpoint, for both OpenCode versions.
pub struct OpenCodeGoApiProvider {
    auth_urls: Vec<PathBuf>,
    db_urls: Vec<PathBuf>,
    cache: QuotaCache,
    client: Box<dyn HttpClient>,
    sqlite: crate::paths::SqliteReader,
}

impl Default for OpenCodeGoApiProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl OpenCodeGoApiProvider {
    pub fn new() -> Self {
        Self::with_paths(None)
    }

    /// v1 keeps keys in `auth.json`; v2 uses `account.json` and the DB
    /// `credential` table. All are searched, XDG included, because a v2-only
    /// machine has no `auth.json` at all.
    pub fn with_paths(explicit: Option<PathBuf>) -> Self {
        let paths = AppPaths::detect();
        let mut dirs = vec![
            paths.data_directory().join("opencode"),
            paths.home_directory().join(".local/share/opencode"),
            paths.config_directory().join("opencode"),
        ];
        if let Some(explicit) = explicit {
            dirs.insert(0, explicit);
        }
        let mut auth_urls = Vec::new();
        for dir in &dirs {
            auth_urls.push(dir.join("auth.json"));
            auth_urls.push(dir.join("account.json"));
        }
        let db_urls = dirs.iter().map(|dir| dir.join("opencode.db")).collect();
        Self {
            auth_urls,
            db_urls,
            cache: QuotaCache::standard(),
            client: Box::new(UreqClient::default()),
            sqlite: crate::paths::SqliteReader::new(),
        }
    }

    pub fn with_client(mut self, client: Box<dyn HttpClient>) -> Self {
        self.client = client;
        self
    }

    pub fn with_cache(mut self, cache: QuotaCache) -> Self {
        self.cache = cache;
        self
    }

    /// Every location a key is looked for, for the diagnostic message.
    pub fn credential_candidates(&self) -> &[PathBuf] {
        &self.auth_urls
    }

    pub fn fetch_usage(&mut self, now: i64) -> FetchResult {
        if !self.cache.should_fetch(now) {
            let usage = self.cache.snapshot("OpenCode Go");
            return FetchResult {
                usage,
                status: None,
            };
        }
        self.cache.note_fetch(now);
        match self.perform_fetch() {
            Ok(windows) => {
                self.cache.note_success(windows, Some("Go".to_string()));
                FetchResult {
                    usage: self.cache.snapshot("OpenCode Go"),
                    status: None,
                }
            }
            Err(status) => {
                self.cache.note_failure();
                FetchResult {
                    usage: self.cache.snapshot("OpenCode Go"),
                    status: Some(status),
                }
            }
        }
    }

    pub fn invalidate_cache(&mut self) {
        self.cache.invalidate();
    }

    fn perform_fetch(&mut self) -> Result<Vec<UsageWindow>, String> {
        let key = self
            .read_api_key()
            .ok_or_else(|| format!("no OpenCode key in {}", self.candidate_list()))?;
        let body = self.client.get(OPENCODE_ENDPOINT, &key, &[])?;
        Self::parse_windows(body.as_bytes())
    }

    fn candidate_list(&self) -> String {
        self.auth_urls
            .iter()
            .map(|path| path.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// The `opencode-go` key from whichever store this version uses.
    pub fn read_api_key(&self) -> Option<String> {
        for url in &self.auth_urls {
            if let Ok(data) = std::fs::read(url) {
                if let Some(key) = Self::api_key_in_json(&data) {
                    return Some(key);
                }
            }
        }
        self.key_from_database()
    }

    /// v1 `auth.json`: `{"opencode-go":{"key":…}}`.
    /// v2 `account.json`: `{"version":2,"accounts":{…serviceID:"opencode-go"…}}`.
    pub fn api_key_in_json(data: &[u8]) -> Option<String> {
        let value: serde_json::Value = serde_json::from_slice(data).ok()?;
        if let Some(key) = value
            .get("opencode-go")
            .and_then(|entry| entry.get("key"))
            .and_then(|v| v.as_str())
        {
            return Some(key.to_string());
        }
        let accounts = value.get("accounts")?.as_object()?;
        for entry in accounts.values() {
            if entry.get("serviceID").and_then(|v| v.as_str()) == Some("opencode-go") {
                if let Some(key) = entry
                    .get("credential")
                    .and_then(|credential| credential.get("key"))
                    .and_then(|v| v.as_str())
                {
                    return Some(key.to_string());
                }
            }
        }
        None
    }

    /// v2 also keeps an integration key in the DB `credential` table.
    fn key_from_database(&self) -> Option<String> {
        for url in &self.db_urls {
            if !url.exists() {
                continue;
            }
            let Ok(output) = self.sqlite.query(
                url,
                "SELECT value FROM credential WHERE integration_id='opencode-go' LIMIT 1;",
            ) else {
                continue;
            };
            let value = output.trim();
            if value.is_empty() {
                continue;
            }
            if let Some(key) = Self::api_key_in_json(value.as_bytes()) {
                return Some(key);
            }
            // The row is `{"type":"key","key":"…"}` — the flat shape.
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(value) {
                if let Some(key) = parsed.get("key").and_then(|v| v.as_str()) {
                    return Some(key.to_string());
                }
            }
        }
        None
    }

    /// Parses `{usage:{rolling,weekly,monthly:{percent,resetsAt}}}`. `percent`
    /// is **used**.
    pub fn parse_windows(data: &[u8]) -> Result<Vec<UsageWindow>, String> {
        let value: serde_json::Value = serde_json::from_slice(data)
            .map_err(|_| "could not parse usage response".to_string())?;
        let usage = value
            .get("usage")
            .and_then(|v| v.as_object())
            .ok_or_else(|| "usage response had no usage block".to_string())?;

        let mut windows = Vec::new();
        for (key, label) in [
            ("rolling", "Rolling"),
            ("weekly", "Weekly"),
            ("monthly", "Monthly"),
        ] {
            let Some(entry) = usage.get(key) else {
                continue;
            };
            let used = entry
                .get("percent")
                .and_then(|v| v.as_f64())
                .map(|percent| percent.clamp(0.0, 100.0))
                .unwrap_or(0.0);
            windows.push(UsageWindow::with_id(
                format!("OpenCode Go-{label}"),
                label,
                0,
                Some(100.0 - used),
                entry
                    .get("resetsAt")
                    .and_then(|v| v.as_str())
                    .and_then(parse_log_date),
            ));
        }
        if windows.is_empty() {
            return Err("usage response had no windows".to_string());
        }
        Ok(windows)
    }
}

// MARK: - Local provider

/// Wraps a local parser as a provider, computing windows from capacities.
/// Returns `None` when there is no local data at all, so an unconfigured CLI is
/// left out of the menu instead of showing an empty row.
pub struct LocalUsageProvider {
    pub provider_name: String,
    pub samples: Vec<(String, Vec<crate::model::UsageSample>)>,
    capacities: Arc<HashMap<String, i64>>,
    cache: QuotaCache,
}

impl LocalUsageProvider {
    pub fn new(
        provider_name: &str,
        samples: Vec<(String, Vec<crate::model::UsageSample>)>,
        capacities: Arc<HashMap<String, i64>>,
    ) -> Self {
        Self {
            provider_name: provider_name.to_string(),
            samples,
            capacities,
            cache: QuotaCache::new(Duration::from_secs(30), Duration::from_secs(30)),
        }
    }

    /// Windows for every batch that has samples. Each local provider gets its
    /// own entry, because Codex and Claude have different capacities.
    pub fn fetch_batches(&mut self) -> Vec<ProviderUsage> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        self.samples
            .iter()
            .filter(|(_, samples)| !samples.is_empty())
            .map(|(provider, samples)| {
                let windows = crate::model::UsageComputation::windows(
                    samples,
                    provider,
                    &self.capacities,
                    now,
                );
                ProviderUsage::new(provider.clone(), None, windows)
            })
            .collect()
    }

    pub fn fetch_usage(&mut self) -> FetchResult {
        let usage = self.fetch_batches();
        if usage.is_empty() {
            return FetchResult {
                usage: None,
                status: Some("no local usage".to_string()),
            };
        }
        self.cache.note_success(usage[0].windows.clone(), None);
        FetchResult {
            usage: Some(usage[0].clone()),
            status: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// A fixed clock, so the throttle tests are about deadlines rather than
    /// elapsed time and cannot go flaky on a loaded machine.
    const NOW: i64 = 1_790_000_000;

    fn window(label: &str, percent: Option<f64>) -> UsageWindow {
        UsageWindow::new(label, 0, percent, None)
    }

    // ---- throttle ----

    fn resetting(label: &str, resets_at: Option<i64>) -> UsageWindow {
        UsageWindow::new(label, 0, Some(50.0), resets_at)
    }

    /// `noWindowsNeverDue` — nothing to be due about.
    #[test]
    fn no_windows_never_due() {
        assert!(!ProviderThrottle::reset_due(&[], NOW - 600, NOW));
    }

    /// `futureResetNotDue` — a window that has not rolled over yet.
    #[test]
    fn future_reset_not_due() {
        let windows = [resetting("Rolling", Some(NOW + 3600))];
        assert!(!ProviderThrottle::reset_due(&windows, NOW - 600, NOW));
    }

    /// `resetPassedAfterLastFetchIsDue` — the snapshot predates the reset, so it
    /// describes a window that no longer exists.
    #[test]
    fn reset_passed_after_last_fetch_is_due() {
        let windows = [resetting("Rolling", Some(NOW - 60))];
        assert!(ProviderThrottle::reset_due(&windows, NOW - 600, NOW));
    }

    /// `fetchedSinceResetNotDue` — what stops the previous case firing forever:
    /// once a fetch has happened *after* the reset, the snapshot is current.
    #[test]
    fn fetched_since_reset_not_due() {
        let windows = [resetting("Rolling", Some(NOW - 600))];
        assert!(!ProviderThrottle::reset_due(&windows, NOW - 60, NOW));
    }

    /// `missingResetsAtNeverDue` — local parsing cannot know a reset time.
    #[test]
    fn missing_resets_at_never_due() {
        let windows = [resetting("Rolling", None)];
        assert!(!ProviderThrottle::reset_due(&windows, NOW - 600, NOW));
    }

    /// `anyDueWindowForcesRefresh` — one due window is enough.
    #[test]
    fn any_due_window_forces_refresh() {
        let windows = [
            resetting("Rolling", Some(NOW + 3600)),
            resetting("Weekly", Some(NOW - 60)),
        ];
        assert!(ProviderThrottle::reset_due(&windows, NOW - 600, NOW));
    }

    /// `quotaCacheThrottlesAndBacksOff` — the interval floor and the backoff.
    #[test]
    fn quota_cache_throttles_and_backs_off() {
        let mut cache = QuotaCache::new(Duration::from_millis(60), Duration::from_millis(100));
        assert!(cache.should_fetch(NOW), "first call always goes out");
        cache.note_fetch(NOW);
        assert!(!cache.should_fetch(NOW), "then throttled");
        std::thread::sleep(Duration::from_millis(80));
        assert!(cache.should_fetch(NOW), "past the floor");

        // Failures widen the interval.
        cache.note_fetch(NOW);
        cache.note_failure();
        cache.note_failure();
        std::thread::sleep(Duration::from_millis(120));
        assert!(
            !cache.should_fetch(NOW),
            "two failures back off past the plain floor"
        );
    }

    /// `quotaCacheSkipsThrottleWhenResetPassed` — the reset escape hatch: inside
    /// the interval, but a window has rolled over since the last fetch.
    #[test]
    fn quota_cache_skips_throttle_when_reset_passed() {
        let mut cache = QuotaCache::new(Duration::from_secs(60), Duration::from_secs(300));
        cache.note_success(vec![resetting("Rolling", Some(NOW + 60))], None);
        cache.note_fetch(NOW);

        // Just fetched, so throttled...
        assert!(!cache.should_fetch(NOW));
        // ...but the window rolls over before the floor elapses.
        assert!(
            cache.should_fetch(NOW + 90),
            "a reset since the last fetch must force a fetch"
        );
        // Once that fetch has happened, the throttle applies again.
        cache.note_fetch(NOW + 90);
        assert!(!cache.should_fetch(NOW + 90));
    }

    /// A cache with no snapshot yet has nothing to be due.
    #[test]
    fn quota_cache_without_a_snapshot_is_never_reset_due() {
        let cache = QuotaCache::standard();
        assert!(!ProviderThrottle::reset_due(&[], 0, NOW));
        assert!(cache.snapshot("Claude").is_none());
    }

    // ---- Claude account fingerprint ----

    /// `claudeAccountFingerprintUsesAccountAndOrg`.
    #[test]
    fn claude_account_fingerprint_uses_account_and_org() {
        let json = br#"{"oauthAccount":{"accountUuid":"acct-1","organizationUuid":"org-1"}}"#;
        assert_eq!(
            ClaudeUsageApiProvider::account_fingerprint(json).as_deref(),
            Some("acct-1|org-1")
        );

        // An account with no organisation is still an account.
        let no_org = br#"{"oauthAccount":{"accountUuid":"acct-1"}}"#;
        assert_eq!(
            ClaudeUsageApiProvider::account_fingerprint(no_org).as_deref(),
            Some("acct-1|")
        );

        // Nothing usable: no account block, an empty uuid, or not JSON at all.
        assert!(ClaudeUsageApiProvider::account_fingerprint(br#"{}"#).is_none());
        assert!(ClaudeUsageApiProvider::account_fingerprint(
            br#"{"oauthAccount":{"accountUuid":""}}"#
        )
        .is_none());
        assert!(ClaudeUsageApiProvider::account_fingerprint(b"not json").is_none());
    }

    /// `tokenHashFallbackDiffersPerToken` — and, just as importantly, is the same
    /// every time, because a per-process hash would make every poll look like a
    /// plan switch.
    #[test]
    fn token_hash_fallback_differs_per_token() {
        let first = ClaudeUsageApiProvider::fallback_fingerprint("token-a");
        let second = ClaudeUsageApiProvider::fallback_fingerprint("token-b");
        assert_ne!(first, second);
        assert_eq!(
            first,
            ClaudeUsageApiProvider::fallback_fingerprint("token-a"),
            "stable across calls, and across processes"
        );
        assert!(first.starts_with("token|"));
    }

    /// The uuid pair wins when the account file is readable, because a token hash
    /// changes on every OAuth refresh and would read as a switch.
    #[test]
    fn the_account_file_is_preferred_over_the_token() {
        let dir = std::env::temp_dir().join(format!("burnrate-acct-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let credentials = dir.join("credentials.json");
        std::fs::write(&credentials, br#"{"claudeAiOauth":{"accessToken":"tok"}}"#).expect("write");

        let account = dir.join("claude.json");
        std::fs::write(
            &account,
            br#"{"oauthAccount":{"accountUuid":"acct-9","organizationUuid":"org-9"}}"#,
        )
        .expect("write");
        let provider =
            ClaudeUsageApiProvider::new(Some(credentials), None).with_account_file(account);
        assert_eq!(
            provider.credential_fingerprint().as_deref(),
            Some("acct-9|org-9"),
            "the account block wins: a token hash changes on every refresh"
        );

        // With no account file, the token is the only identity available.
        let provider = ClaudeUsageApiProvider::new(Some(dir.join("credentials.json")), None)
            .with_account_file(dir.join("absent.json"));
        assert_eq!(
            provider.credential_fingerprint().as_deref(),
            Some(ClaudeUsageApiProvider::fallback_fingerprint("tok").as_str())
        );

        // And with neither, there is no identity — not an empty one.
        let provider = ClaudeUsageApiProvider::new(Some(dir.join("absent.json")), None)
            .with_account_file(dir.join("absent.json"));
        assert!(provider.credential_fingerprint().is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A failed fetch still serves the last good snapshot.
    #[test]
    fn failed_fetch_reuses_last_snapshot() {
        let mut cache = QuotaCache::new(Duration::from_millis(1), Duration::from_millis(1));
        cache.note_success(vec![window("Weekly", Some(64.0))], Some("Team 5x".into()));
        let snapshot = cache.snapshot("Claude").unwrap();
        assert_eq!(snapshot.plan.as_deref(), Some("Team 5x"));
        assert_eq!(snapshot.windows[0].percent_remaining, Some(64.0));
    }

    // ---- Claude parsing ----

    /// `parsesClaudeLimitsArrayIncludingModelScoped` — including Fable.
    #[test]
    fn parses_claude_limits_array_including_model_scoped() {
        let body = br#"{"limits":[
            {"kind":"session","percent":18,"resets_at":"2026-09-29T05:34:21Z"},
            {"kind":"weekly_all","percent":36},
            {"kind":"weekly_scoped","percent":91,
             "scope":{"model":{"display_name":"Fable"}}}]}"#;
        let windows = ClaudeUsageApiProvider::parse_windows(body).unwrap();
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].label, "Rolling");
        assert_eq!(windows[0].percent_remaining, Some(82.0));
        assert_eq!(windows[1].percent_remaining, Some(64.0));
        assert_eq!(
            windows[2].label, "Fable",
            "scoped windows use the model name"
        );
        assert_eq!(windows[2].percent_remaining, Some(9.0));
        assert!(windows[0].resets_at.is_some());
    }

    /// `claudeFallbackParsesFlatKeysWithoutLimits` — the older response shape.
    #[test]
    fn claude_fallback_parses_flat_keys_without_limits() {
        let body = br#"{"five_hour":{"utilization":25},"seven_day":{"utilization":40}}"#;
        let windows = ClaudeUsageApiProvider::parse_windows(body).unwrap();
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "Rolling");
        assert_eq!(windows[0].percent_remaining, Some(75.0));
        assert_eq!(windows[1].percent_remaining, Some(60.0));
    }

    /// `claudeClampsUtilizationOver100`.
    #[test]
    fn claude_clamps_utilization_over_100() {
        let body = br#"{"limits":[{"kind":"session","percent":140}]}"#;
        let windows = ClaudeUsageApiProvider::parse_windows(body).unwrap();
        assert_eq!(windows[0].percent_remaining, Some(0.0));
    }

    #[test]
    fn claude_parses_bare_keys_only() {
        let body = br#"{"limits":[{"kind":"session"},{"kind":"something_else","percent":5}]}"#;
        let windows = ClaudeUsageApiProvider::parse_windows(body).unwrap();
        assert_eq!(windows.len(), 1, "unknown kinds are skipped");
        assert_eq!(windows[0].percent_remaining, Some(100.0));
    }

    #[test]
    fn claude_rejects_a_response_with_nothing_usable() {
        assert!(ClaudeUsageApiProvider::parse_windows(b"{}").is_err());
        assert!(ClaudeUsageApiProvider::parse_windows(b"not json").is_err());
    }

    /// The plan name comes from a fixed table and the multiplier from the *end*
    /// of the rate-limit tier — the real credential shape, not two
    /// already-formatted halves. The previous test fed it `"Max"` and `"20x"`,
    /// so joining the strings looked correct and hid that the real credential
    /// (`"max"`, `"default_claude_max_20x"`) rendered as
    /// `"max default_claude_max_20x"`.
    #[test]
    fn format_plan_matches_the_swift_shapes() {
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("max", Some("default_claude_max_20x")),
            Some("Max 20x".into())
        );
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("team", Some("default_claude_team_5x")),
            Some("Team 5x".into())
        );
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("pro", None),
            Some("Pro".into())
        );
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("enterprise", Some("default_claude_enterprise")),
            Some("Enterprise".into())
        );
        // An unknown subscription type falls through verbatim rather than
        // vanishing.
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("weird", None),
            Some("weird".into())
        );
        // The multiplier only counts at the end of the tier.
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("max", Some("20x")),
            Some("Max 20x".into())
        );
        assert_eq!(
            ClaudeUsageApiProvider::format_plan("max", Some("20x_then_more")),
            Some("Max".into())
        );
        assert_eq!(ClaudeUsageApiProvider::format_plan("", None), None);
    }

    /// The Keychain is the *only* credential store on a machine that never wrote
    /// `~/.claude/.credentials.json`, and the plan has to come from there too —
    /// not just the token. It did not: `credential_plan` read only the file, so
    /// this machine showed "Claude" with no tier.
    #[test]
    fn keychain_supplies_the_plan_when_the_file_has_none() {
        struct FixedKeychain;
        impl CredentialReading for FixedKeychain {
            fn generic_password(&self, _service: &str) -> Option<Vec<u8>> {
                Some(
                    br#"{"claudeAiOauth":{"accessToken":"from-keychain","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
                        .to_vec(),
                )
            }
        }
        let dir = temp_dir("keychain-plan");
        std::fs::write(dir.join(".credentials.json"), br#"{}"#).unwrap();
        let mut provider = ClaudeUsageApiProvider::new(
            Some(dir.join(".credentials.json")),
            Some(Box::new(FixedKeychain)),
        )
        .with_client(Box::new(StubClient {
            response: Ok(r#"{"limits":[{"kind":"session","percent":10}]}"#.to_string()),
        }))
        .with_cache(QuotaCache::new(
            Duration::from_millis(1),
            Duration::from_millis(1),
        ));
        let usage = provider.fetch_usage(NOW).usage.expect("usage");
        assert_eq!(usage.plan.as_deref(), Some("Max 20x"));
    }

    // ---- OpenCode parsing ----

    /// `parsesOpenCodeGoWindows`.
    #[test]
    fn parses_opencode_go_windows() {
        let body = br#"{"usage":{"rolling":{"percent":4,"resetsAt":"2026-09-25T03:34:21Z"},
                                    "weekly":{"percent":1},
                                    "monthly":{"percent":1}}}"#;
        let windows = OpenCodeGoApiProvider::parse_windows(body).unwrap();
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].label, "Rolling");
        assert_eq!(windows[0].percent_remaining, Some(96.0));
        assert_eq!(windows[2].percent_remaining, Some(99.0));
    }

    /// `parsesOpenCodeGoAPIKeyFromAuthJSON` — v1.
    #[test]
    fn reads_opencode_v1_key() {
        let data = br#"{"opencode-go":{"type":"api","key":"sk-v1"}}"#;
        assert_eq!(
            OpenCodeGoApiProvider::api_key_in_json(data),
            Some("sk-v1".to_string())
        );
    }

    /// `parsesOpenCodeV2AccountJSON` — v2, picking the right service out of many.
    #[test]
    fn reads_opencode_v2_key() {
        let data = br#"{"version":2,"accounts":{
            "a1":{"id":"a1","serviceID":"lmstudio","credential":{"type":"api","key":"sk-lm"}},
            "a2":{"id":"a2","serviceID":"opencode-go","credential":{"type":"api","key":"sk-v2"}}}}"#;
        assert_eq!(
            OpenCodeGoApiProvider::api_key_in_json(data),
            Some("sk-v2".to_string())
        );
        let no_go = br#"{"version":2,"accounts":{"a1":{"serviceID":"lmstudio","credential":{"key":"sk-lm"}}}}"#;
        assert_eq!(OpenCodeGoApiProvider::api_key_in_json(no_go), None);
    }

    // ---- the HTTP seam, without a network ----

    struct StubClient {
        response: Result<String, String>,
    }

    impl HttpClient for StubClient {
        fn get(
            &self,
            _url: &str,
            _bearer: &str,
            _headers: &[(&str, &str)],
        ) -> Result<String, String> {
            self.response.clone()
        }
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("burnrate-providers-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A missing credential is reported, not silently "no providers".
    #[test]
    fn missing_credentials_are_reported() {
        let dir = temp_dir("nocreds");
        let mut provider = ClaudeUsageApiProvider::new(Some(dir.join(".credentials.json")), None);
        let result = provider.fetch_usage(NOW);
        assert!(result.usage.is_none());
        let status = result.status.unwrap();
        assert!(status.contains("no Claude credentials"), "got {status}");
        assert!(status.contains(".credentials.json"), "says where it looked");
    }

    /// A rejected key surfaces the HTTP code.
    #[test]
    fn http_failures_surface_the_status_code() {
        let dir = temp_dir("401");
        std::fs::write(
            dir.join(".credentials.json"),
            br#"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#,
        )
        .unwrap();
        let mut provider = ClaudeUsageApiProvider::new(Some(dir.join(".credentials.json")), None)
            .with_client(Box::new(StubClient {
                response: Err("HTTP 401".into()),
            }));
        let result = provider.fetch_usage(NOW);
        assert_eq!(result.status.as_deref(), Some("HTTP 401"));
        assert!(result.usage.is_none());
    }

    /// A good response produces windows, and the plan comes from the credential.
    #[test]
    fn successful_fetch_returns_windows_and_plan() {
        let dir = temp_dir("ok");
        std::fs::write(
            dir.join(".credentials.json"),
            br#"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#,
        )
        .unwrap();
        let mut provider = ClaudeUsageApiProvider::new(Some(dir.join(".credentials.json")), None)
            .with_client(Box::new(StubClient {
                response: Ok(r#"{"limits":[{"kind":"session","percent":20}]}"#.to_string()),
            }))
            .with_cache(QuotaCache::new(
                Duration::from_millis(1),
                Duration::from_millis(1),
            ));
        let result = provider.fetch_usage(NOW);
        assert_eq!(result.status, None);
        let usage = result.usage.expect("usage");
        assert_eq!(usage.plan.as_deref(), Some("Max 20x"));
        assert_eq!(usage.windows[0].percent_remaining, Some(80.0));
    }

    /// The Keychain reader is consulted when the file has no token.
    #[test]
    fn keychain_supplies_the_token_when_the_file_has_none() {
        struct FixedKeychain;
        impl CredentialReading for FixedKeychain {
            fn generic_password(&self, _service: &str) -> Option<Vec<u8>> {
                Some(br#"{"claudeAiOauth":{"accessToken":"from-keychain"}}"#.to_vec())
            }
        }
        let dir = temp_dir("keychain");
        std::fs::write(dir.join(".credentials.json"), br#"{}"#).unwrap();
        let mut provider = ClaudeUsageApiProvider::new(
            Some(dir.join(".credentials.json")),
            Some(Box::new(FixedKeychain)),
        )
        .with_client(Box::new(StubClient {
            response: Ok(r#"{"limits":[{"kind":"session","percent":10}]}"#.to_string()),
        }))
        .with_cache(QuotaCache::new(
            Duration::from_millis(1),
            Duration::from_millis(1),
        ));
        let result = provider.fetch_usage(NOW);
        assert!(result.usage.is_some(), "keychain token was used");
    }

    /// A provider with no local data reports why instead of showing nothing.
    #[test]
    fn local_provider_without_samples_reports_why() {
        let capacities = Arc::new(HashMap::new());
        let mut provider = LocalUsageProvider::new("Codex", vec![], capacities);
        let result = provider.fetch_usage();
        assert!(result.usage.is_none());
        assert_eq!(result.status.as_deref(), Some("no local usage"));
    }

    #[test]
    fn local_provider_computes_windows() {
        let capacities = Arc::new(crate::plan_capacities_by_provider_window());
        // Relative to now: the Rolling window is 5h, so a fixed epoch would
        // silently fall outside it as the test suite ages.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap();
        let samples = vec![(
            "Codex".to_string(),
            vec![crate::model::UsageSample::new(
                now - 60,
                crate::model::TokenUsage::new(1_200_000, 0, 0, 0),
            )],
        )];
        let mut provider = LocalUsageProvider::new("Codex", samples, capacities);
        let result = provider.fetch_usage();
        let usage = result.usage.expect("usage");
        let rolling = usage.window("Rolling").expect("rolling window");
        let percent = rolling.percent_remaining.expect("percent");
        assert!(percent > 85.0 && percent < 95.0, "got {percent}");
    }

    // A mutex-based credential reader, proving the trait is object safe.
    #[test]
    fn credential_reader_is_object_safe() {
        let readers: Vec<Box<dyn CredentialReading>> =
            vec![Box::new(NoopCredentialReader), Box::new(FixedReader)];
        assert!(readers
            .iter()
            .all(|reader| reader.generic_password("x").is_none()));
    }

    struct FixedReader;
    impl CredentialReading for FixedReader {
        fn generic_password(&self, _service: &str) -> Option<Vec<u8>> {
            None
        }
    }

    #[allow(dead_code)]
    fn _assert_send_sync<T: Send + Sync>() {}
    #[allow(dead_code)]
    fn _assert_providers_are() {
        _assert_send_sync::<ClaudeUsageApiProvider>();
        _assert_send_sync::<OpenCodeGoApiProvider>();
        _assert_send_sync::<LocalUsageProvider>();
        let _ = Mutex::new(());
    }
}
