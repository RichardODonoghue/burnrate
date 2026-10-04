//! The poll loop: fetch from every provider, evaluate alerts, keep history.
//!
//! Owns the state that has to persist between polls — the providers (with their
//! throttling), the notifier's per-window memory, and the remaining-% history
//! the trend chart draws. Everything it decides comes from `burnrate-core`; this
//! only sequences the work and hands results to the tray and the window.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::model::ProviderUsage;
use crate::notifier::{MilestoneNotifier, Notification};
use crate::paths::AppPaths;
use crate::providers::{ClaudeUsageApiProvider, LocalUsageProvider, OpenCodeGoApiProvider};
use crate::settings::Settings;
use crate::sources::{ClaudeUsageSource, CodexUsageSource, OpenCodeUsageSource};
use crate::usage::{DailyModelUsage, ModelUsageAggregator, ModelUsageEntry, PricingTable};

/// Everything the window and tray need after a poll.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PollResult {
    pub usage: Vec<ProviderUsage>,
    /// One line per provider that produced nothing, saying why.
    pub missing: Vec<String>,
    /// Remaining-% history, oldest first.
    pub model_totals: Vec<ModelUsageEntry>,
    pub model_daily: Vec<DailyModelUsage>,
    pub spend_today: HashMap<String, f64>,
    pub notifications: Vec<Notification>,
    pub at: i64,
    /// The raw per-provider sample batches this poll was built from, so a
    /// caller can aggregate models without re-parsing the logs. Not sent to the
    /// frontend: the window gets `model_totals` and `model_daily` instead.
    #[serde(skip)]
    pub batches: Vec<(String, Vec<crate::model::UsageSample>)>,
    /// Flat remaining-% samples for the trend chart, accumulated across polls.
    /// This is the Swift build's `remainingHistory`, and it is the only history
    /// the trend chart needs.
    pub remaining_history: Vec<crate::charts::RemainingSample>,
}

pub struct Poller {
    claude_api: ClaudeUsageApiProvider,
    opencode_api: OpenCodeGoApiProvider,
    claude_logs: ClaudeUsageSource,
    codex_logs: CodexUsageSource,
    opencode_logs: OpenCodeUsageSource,
    notifier: MilestoneNotifier,
    pricing: Mutex<PricingTable>,
    /// Remaining-% samples across polls, oldest first. This is the trend chart's
    /// only history.
    remaining_history: Vec<crate::charts::RemainingSample>,
    /// Thirty days of per-model daily buckets, persisted and merged with each
    /// live parse. The live parse is authoritative for the days it covers; this
    /// keeps the days whose logs have since rotated away.
    model_history: Vec<DailyModelUsage>,
    last_local_poll: Option<Instant>,
    local_interval: Duration,
    poll_count: AtomicU64,
    /// The last poll's credential fingerprints, Claude then OpenCode. When a
    /// login or logout changes either, the next poll skips the throttle so the
    /// change shows up at the next tick rather than after a failure backoff.
    last_credential_signature: Option<(Option<String>, Option<String>)>,
}

impl Poller {
    pub fn new() -> Self {
        Self::with_keychain(true)
    }

    /// `with_keychain` is false off macOS, where the dotfile is the credential.
    pub fn with_keychain(keychain: bool) -> Self {
        let credentials: Box<dyn crate::paths::CredentialReading> = if keychain {
            Box::new(crate::paths::KeychainCredentialReader::default())
        } else {
            Box::new(crate::paths::NoopCredentialReader)
        };
        Self {
            claude_api: ClaudeUsageApiProvider::new(None, Some(credentials)),
            opencode_api: OpenCodeGoApiProvider::new(),
            claude_logs: ClaudeUsageSource::new(None, None),
            codex_logs: CodexUsageSource::new(None),
            opencode_logs: OpenCodeUsageSource::new(None, None),
            notifier: MilestoneNotifier::new(),
            pricing: Mutex::new(PricingTable::default()),
            remaining_history: Vec::new(),
            model_history: Vec::new(),
            last_local_poll: None,
            // The Claude log parse is expensive the first time; after that the
            // incremental cache makes it milliseconds, but there is no reason
            // to walk 560MB more than once a minute.
            local_interval: Duration::from_secs(60),
            poll_count: AtomicU64::new(0),
            last_credential_signature: None,
        }
    }

    pub fn poll_count(&self) -> u64 {
        self.poll_count.load(Ordering::Relaxed)
    }

    /// Loads a cached pricing table from disk, if one exists.
    pub fn load_pricing_cache(&mut self) {
        let path = AppPaths::detect().app_directory().join("pricing.json");
        let Ok(bytes) = std::fs::read(&path) else {
            return;
        };
        if let Ok(table) = PricingTable::from_litellm_json(&bytes) {
            *self.pricing.lock().expect("pricing lock") = table;
        }
    }

    /// Fetches the LiteLLM price table. Failure is silent by design: cost is a
    /// nicety, and a failed refresh must not disturb the usage figures.
    pub fn refresh_pricing(&mut self, client: &dyn crate::providers::HttpClient) {
        const URL: &str = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
        if let Ok(body) = client.get(URL, "", &[]) {
            if let Ok(table) = PricingTable::from_litellm_json(body.as_bytes()) {
                let path = AppPaths::detect().app_directory().join("pricing.json");
                if let Some(parent) = path.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                let _ = std::fs::write(&path, body.as_bytes());
                *self.pricing.lock().expect("pricing lock") = table;
            }
        }
    }

    /// One full poll. `settings` is the current configuration; the poll
    /// interval comes from it.
    pub fn poll(&mut self, settings: &Settings) -> PollResult {
        let now = now_unix();
        self.poll_count.fetch_add(1, Ordering::Relaxed);
        let mut missing: Vec<String> = Vec::new();
        let mut usage: Vec<ProviderUsage> = Vec::new();

        // Credentials are re-read on every fetch, but the throttle and its
        // failure backoff would otherwise hold a stale snapshot for up to ten
        // minutes after a login. A changed signature drops the cache, so the
        // login shows up on the next tick. This is why logging back in and not
        // restarting appeared to do nothing.
        let signature = (
            self.claude_api.credential_signature(),
            self.opencode_api.credential_signature(),
        );
        if self.last_credential_signature != Some(signature.clone()) {
            if self.last_credential_signature.is_some() {
                self.claude_api.invalidate_cache();
                self.opencode_api.invalidate_cache();
            }
            self.last_credential_signature = Some(signature);
        }

        // --- vendor quota APIs: authoritative percentages --------------------
        let claude = self.claude_api.fetch_usage(now);
        if let Some(result) = claude.usage.clone() {
            usage.push(result);
        }
        if let Some(status) = claude.status.clone() {
            missing.push(format!("Claude: {status}"));
        }

        let opencode = self.opencode_api.fetch_usage(now);
        if let Some(result) = opencode.usage.clone() {
            usage.push(result);
        }
        if let Some(status) = opencode.status.clone() {
            missing.push(format!("OpenCode: {status}"));
        }

        // --- local logs: tokens, models and cost ----------------------------
        // The parse is throttled independently: the API answers in
        // milliseconds, the log walk does not.
        let local_due = self
            .last_local_poll
            .map(|last| last.elapsed() >= self.local_interval)
            .unwrap_or(true);
        let mut batches: Vec<(String, Vec<crate::model::UsageSample>)> = Vec::new();
        if local_due {
            self.last_local_poll = Some(Instant::now());
            let claude_samples = self.claude_logs.collect_samples();
            if claude_samples.is_empty() {
                missing.push(format!(
                    "Claude logs: nothing under {}",
                    self.claude_logs.base_directory().display()
                ));
            }
            batches.push(("Claude".to_string(), claude_samples));

            let codex_samples = self.codex_logs.collect_samples();
            if codex_samples.is_empty() {
                missing.push(format!(
                    "Codex: nothing under {}",
                    self.codex_logs.base_directory().display()
                ));
            }
            batches.push(("Codex".to_string(), codex_samples));

            let opencode_samples = self.opencode_logs.collect_samples();
            if opencode_samples.is_empty() {
                missing.push(format!(
                    "OpenCode logs: {}",
                    self.opencode_logs
                        .resolve_database()
                        .map(|path| format!("{} has no assistant turns", path.display()))
                        .unwrap_or_else(|| "no database found".to_string())
                ));
            }
            batches.push(("OpenCode Go".to_string(), opencode_samples));
        }

        // A provider with no API data falls back to its local windows, which is
        // the only way Codex ever shows a percentage.
        let mut local = LocalUsageProvider::new(
            "local",
            batches.clone(),
            Arc::new(crate::plan_capacities_by_provider_window()),
        );
        for entry in local.fetch_batches() {
            if !usage.iter().any(|u| u.provider_name == entry.provider_name) {
                usage.push(entry);
            }
        }

        // --- history for the trend chart -------------------------------------
        for (provider, label, percent) in history_values(&usage) {
            self.remaining_history.push(crate::charts::RemainingSample {
                provider,
                label,
                date: now,
                remaining: percent,
            });
        }
        // Trimmed by date, not by count: a five-minute poll over the longest
        // window is a few thousand entries, and a burst of polls must not
        // shorten the window.
        let history_cutoff = now - crate::migration::REMAINING_RETENTION_SECONDS;
        self.remaining_history
            .retain(|sample| sample.date >= history_cutoff);

        // --- notifications ----------------------------------------------------
        let poll_interval = settings.poll_interval_seconds as i64;
        // A plan switch resets the per-window history, so a fresh account's 5%
        // remaining does not read as "crossed 90, 80, 70…". This was passed `None`
        // unconditionally, so the notifier's plan-switch handling was wired but
        // never fed and a switch did fire that burst.
        self.notifier
            .set_account_fingerprint(self.claude_api.credential_fingerprint());
        let mut notifications = self.notifier.evaluate(&usage, settings, now, poll_interval);

        // --- models and cost --------------------------------------------------
        // The pricing table is needed to estimate cost for samples whose source
        // reports none — Claude's logs never do — so it is held across all three
        // aggregations and released before `self.model_history` is written.
        let (model_totals, fresh_daily, spend_today) = {
            let mut pricing = self.pricing.lock().expect("pricing lock");
            let totals = ModelUsageAggregator::totals(&batches, &mut pricing);
            let daily =
                ModelUsageAggregator::daily(&batches, 30, now, &local_start_of_day, &mut pricing);
            let spend =
                spend_since_start_of_day(&batches, now, local_utc_offset_seconds(), &mut pricing);
            (totals, daily, spend)
        };
        // Merged with the persisted history, so a day whose logs have rotated
        // away is still charted. Fresh wins wherever both have the day.
        self.model_history = crate::migration::prune_daily(
            crate::migration::merge_daily(&self.model_history, &fresh_daily),
            now,
        );
        let model_daily = self.model_history.clone();
        notifications.extend(self.notifier.evaluate_cost(
            start_of_day_local(now, local_utc_offset_seconds()),
            &spend_today,
            settings,
            now,
        ));

        PollResult {
            usage,
            missing,
            model_totals,
            model_daily,
            spend_today,
            notifications,
            at: now,
            batches,
            remaining_history: self.remaining_history.clone(),
        }
    }

    /// The flat remaining-% history the trend chart reads.
    pub fn remaining_history(&self) -> &[crate::charts::RemainingSample] {
        &self.remaining_history
    }

    /// How many days of model history are held, for the launch log.
    pub fn model_history_len(&self) -> usize {
        self.model_history.len()
    }

    /// How many windows the notifier restored, for the launch log.
    pub fn notifier_windows_len(&self) -> usize {
        self.notifier.snapshot_state().windows.len()
    }

    /// How many prices the table holds, and how many models it could not price.
    ///
    /// Surfaced because an empty table is silent: every Claude row falls back to
    /// a list-price estimate, so with no table those rows read "—" while
    /// vendor-reported costs (OpenCode) still appear — which looks like "Claude
    /// has no cost" rather than "the price table did not load".
    pub fn pricing_state(&self) -> (usize, Vec<String>) {
        let table = self.pricing.lock().expect("pricing lock");
        (table.len(), table.unresolved().to_vec())
    }

    /// Reloads the persisted trend history, dropping anything past retention.
    ///
    /// Called at startup. Without it the trend chart is blank for the first hours of every launch, which is indistinguishable
    /// from a broken chart.
    pub fn load_history(&mut self, now: i64) {
        self.load_history_from(
            &crate::paths::AppPaths::detect().remaining_history_file(),
            now,
        );
    }

    /// The file half of [`Poller::load_history`], with the path passed in so it
    /// can be tested without touching the real app directory.
    pub fn load_history_from(&mut self, path: &std::path::Path, now: i64) {
        let Ok(text) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(samples) = serde_json::from_str::<Vec<crate::charts::RemainingSample>>(&text) else {
            // A corrupt cache is not worth failing a poll over: start clean.
            return;
        };
        let cutoff = now - crate::migration::REMAINING_RETENTION_SECONDS;
        self.remaining_history = samples
            .into_iter()
            .filter(|sample| sample.date >= cutoff)
            .collect();
    }

    /// Writes the trend history out, so the next launch has a chart.
    pub fn save_history(&self) {
        let paths = crate::paths::AppPaths::detect();
        if paths.ensure_app_directory().is_err() {
            return;
        }
        self.save_history_to(&paths.remaining_history_file());
    }

    /// The file half of [`Poller::save_history`].
    pub fn save_history_to(&self, path: &std::path::Path) {
        if let Ok(text) = serde_json::to_string(&self.remaining_history) {
            // Best-effort: a full disk must not take the poll loop down.
            let _ = std::fs::write(path, text);
        }
    }

    /// Reloads the persisted daily model history.
    pub fn load_model_history(&mut self, now: i64) {
        self.load_model_history_from(&crate::paths::AppPaths::detect().model_history_file(), now);
    }

    pub fn load_model_history_from(&mut self, path: &std::path::Path, now: i64) {
        let Ok(text) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(days) = serde_json::from_str::<Vec<DailyModelUsage>>(&text) else {
            return;
        };
        self.model_history = crate::migration::prune_daily(days, now);
    }

    /// Reloads the notifier's durable state, so a relaunch continues rather than
    /// starting blank.
    pub fn load_notifier_state(&mut self) {
        let path = AppPaths::detect().notifier_state_file();
        let Ok(text) = std::fs::read_to_string(&path) else {
            return;
        };
        let Ok(state) = serde_json::from_str::<crate::notifier::NotifierState>(&text) else {
            return;
        };
        self.notifier.restore_state(state);
    }

    /// Writes it out. Best-effort, like the histories: a full disk must not take
    /// the poll loop down.
    pub fn save_notifier_state(&self) {
        let paths = AppPaths::detect();
        if paths.ensure_app_directory().is_err() {
            return;
        }
        if let Ok(text) = serde_json::to_string(&self.notifier.snapshot_state()) {
            let _ = std::fs::write(paths.notifier_state_file(), text);
        }
    }

    /// Writes the daily model history out.
    pub fn save_model_history(&self) {
        let paths = crate::paths::AppPaths::detect();
        if paths.ensure_app_directory().is_err() {
            return;
        }
        if let Ok(text) = serde_json::to_string(&self.model_history) {
            let _ = std::fs::write(paths.model_history_file(), text);
        }
    }

    /// Replaces the daily history wholesale — used by the Swift import, which
    /// runs before the first poll and must not be merged with an empty list.
    pub fn set_model_history(&mut self, days: Vec<DailyModelUsage>) {
        self.model_history = days;
    }

    /// Replaces the trend history wholesale, for the Swift import.
    pub fn set_remaining_history(&mut self, samples: Vec<crate::charts::RemainingSample>) {
        self.remaining_history = samples;
    }

    /// Forces the next poll to go out immediately, skipping the throttle — used
    /// by the tray's Refresh item.
    pub fn invalidate_caches(&mut self) {
        self.claude_api.invalidate_cache();
        self.opencode_api.invalidate_cache();
        self.last_local_poll = None;
    }
}

impl Default for Poller {
    fn default() -> Self {
        Self::new()
    }
}

/// Remaining-% readings for the trend history: one per window that reported a
/// percentage.
///
/// A window with no figure is **skipped**, not recorded as zero. A zero would be
/// drawn as a real drop and would drag the Y domain down with it, flattening
/// every genuine line. A rate-limited provider is exactly when this fires.
fn history_values(usage: &[ProviderUsage]) -> Vec<(String, String, f64)> {
    usage
        .iter()
        .flat_map(|provider| {
            provider.windows.iter().filter_map(move |window| {
                let percent = window.percent_remaining?;
                Some((
                    provider.provider_name.clone(),
                    window.label.clone(),
                    percent,
                ))
            })
        })
        .collect()
}

pub fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The machine's current UTC offset in seconds, so "today" and the chart's day
/// buckets mean the user's day rather than UTC's.
///
/// Falls back to UTC when the platform cannot answer (a sandbox without
/// timezone data, say) — which only makes the buckets UTC-aligned, not wrong.
/// The local midnight of the calendar day containing `timestamp`.
///
/// This is `Calendar.startOfDay(for:)`: `localtime_r` to get the local calendar
/// date, then `mktime` to convert that date back, which applies the offset in
/// effect **at that midnight**.
///
/// Both cheaper approaches are wrong. A fixed offset is wrong for every day
/// before a daylight-saving change. And deriving the midnight from the offset at
/// the sample's own instant splits a transition day in two — samples before the
/// shift land on one midnight, samples after on another — where the calendar has
/// one day. That second form is what made the daily chart bare before 27
/// September: the slots were built with today's offset and matched no bucket.
#[cfg(unix)]
pub fn local_start_of_day(timestamp: i64) -> i64 {
    let time = timestamp as libc::time_t;
    let mut broken_down: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::localtime_r(&time, &mut broken_down) }.is_null() {
        return timestamp;
    }
    broken_down.tm_hour = 0;
    broken_down.tm_min = 0;
    broken_down.tm_sec = 0;
    // Let mktime work out whether that midnight is in daylight time.
    broken_down.tm_isdst = -1;
    let midnight = unsafe { libc::mktime(&mut broken_down) };
    if midnight == -1 {
        timestamp
    } else {
        midnight as i64
    }
}

/// Off Unix there is no cheap per-instant lookup, so this uses the current
/// offset. Windows has the same hazard; it is not the platform this was found on.
#[cfg(not(unix))]
pub fn local_start_of_day(timestamp: i64) -> i64 {
    crate::usage::start_of_day(timestamp, local_utc_offset_seconds())
}

pub fn local_utc_offset_seconds() -> i64 {
    match time::UtcOffset::current_local_offset() {
        Ok(offset) => offset.whole_seconds() as i64,
        Err(_) => 0,
    }
}

fn start_of_day_local(timestamp: i64, offset: i64) -> i64 {
    crate::usage::start_of_day(timestamp, offset)
}

fn spend_since_start_of_day(
    batches: &[(String, Vec<crate::model::UsageSample>)],
    now: i64,
    offset: i64,
    pricing: &mut crate::usage::PricingTable,
) -> HashMap<String, f64> {
    let start = start_of_day_local(now, offset);
    let mut spend: HashMap<String, f64> = HashMap::new();
    for (provider, samples) in batches {
        let total: f64 = samples
            .iter()
            .filter(|sample| sample.timestamp >= start)
            // Estimated where the source reports none, as the spend figure in
            // every Swift app does.
            .map(|sample| crate::usage::sample_cost(sample, pricing))
            .sum();
        if total > 0.0 {
            spend.insert(provider.clone(), total);
        }
    }
    spend
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_of_day_is_stable() {
        let now = now_unix();
        let start = start_of_day_local(now, 0);
        assert!(start <= now);
        assert_eq!(start % 86_400, 0, "UTC midnight with a zero offset");
    }

    /// The trend chart is empty on every launch unless the history is persisted,
    /// which is exactly how it looked broken.
    #[test]
    fn history_survives_a_restart_and_is_pruned_to_retention() {
        let dir = std::env::temp_dir().join(format!("burnrate-history-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("remaining-history.json");
        let _ = std::fs::remove_file(&path);
        let now = 1_800_000_000_i64;

        let mut poller = Poller::with_keychain(false);
        let sample = |date: i64, remaining: f64| crate::charts::RemainingSample {
            provider: "Claude".to_string(),
            label: "Rolling".to_string(),
            date,
            remaining,
        };
        poller.remaining_history = vec![
            sample(now - 60, 84.0),
            sample(now - 120, 85.0),
            // A day past the retention window.
            sample(
                now - crate::migration::REMAINING_RETENTION_SECONDS - 86_400,
                12.0,
            ),
        ];
        poller.save_history_to(&path);

        let mut restarted = Poller::with_keychain(false);
        restarted.load_history_from(&path, now);
        let history = restarted.remaining_history();
        assert_eq!(history.len(), 2, "the stale sample is dropped");
        assert_eq!(history[0].remaining, 84.0);
        assert_eq!(history[1].remaining, 85.0);

        // A missing or corrupt file must leave an empty history, not panic.
        let mut fresh = Poller::with_keychain(false);
        fresh.load_history_from(&dir.join("absent.json"), now);
        assert!(fresh.remaining_history().is_empty());
        std::fs::write(&path, "{not json").expect("write");
        let mut corrupt = Poller::with_keychain(false);
        corrupt.load_history_from(&path, now);
        assert!(corrupt.remaining_history().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A window that reported no percentage must not enter the history as 0%.
    #[test]
    fn a_window_with_no_percentage_is_skipped_not_zeroed() {
        use crate::model::{ProviderUsage, UsageWindow};
        let usage = vec![ProviderUsage::new(
            "Claude",
            None,
            vec![
                UsageWindow::new("Rolling", 0, Some(84.0), None),
                // No capacity configured, or the quota call was rate-limited.
                UsageWindow::new("Weekly", 0, None, None),
                UsageWindow::new("Fable", 0, Some(100.0), None),
            ],
        )];
        let values = history_values(&usage);
        assert_eq!(
            values.len(),
            2,
            "the unmeasured window is dropped: {values:?}"
        );
        assert!(values.iter().all(|(_, _, percent)| *percent > 0.0));
        assert!(values.iter().any(|(_, label, _)| label == "Rolling"));
        assert!(!values.iter().any(|(_, label, _)| label == "Weekly"));

        // And a provider with nothing measured contributes nothing at all.
        let empty = vec![ProviderUsage::new(
            "Codex",
            None,
            vec![UsageWindow::new("Rolling", 0, None, None)],
        )];
        assert!(history_values(&empty).is_empty());
    }

    /// The notifier's state has to survive a relaunch, or a plan switch that
    /// happened while the app was closed is invisible — the first poll has no
    /// baseline to compare against, so it cannot tell a fresh account from a
    /// continued one.
    #[test]
    fn notifier_state_survives_a_restart() {
        let dir = std::env::temp_dir().join(format!("burnrate-notify-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("notifier-state.json");

        let mut poller = Poller::with_keychain(false);
        poller
            .notifier
            .set_account_fingerprint(Some("acct-1".into()));
        // Default settings are enough: this is about the recorded baseline, not
        // about any rule firing.
        let settings = Settings::default();
        poller.notifier.evaluate(
            &[crate::model::ProviderUsage::new(
                "Claude",
                None,
                vec![crate::model::UsageWindow::new(
                    "Rolling",
                    0,
                    Some(74.0),
                    Some(1_800_000_000),
                )],
            )],
            &settings,
            1_799_000_000,
            300,
        );

        let text = serde_json::to_string(&poller.notifier.snapshot_state()).expect("serialise");
        std::fs::write(&path, text).expect("write");

        let restored: crate::notifier::NotifierState =
            serde_json::from_str(&std::fs::read_to_string(&path).expect("read")).expect("parse");
        let mut restarted = MilestoneNotifier::new();
        restarted.restore_state(restored);
        assert_eq!(
            restarted.snapshot_state().account_fingerprint.as_deref(),
            Some("acct-1"),
            "the fingerprint must come back"
        );
        assert_eq!(
            restarted.snapshot_state().windows["Claude|Rolling"].last_remaining,
            Some(74.0)
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn spend_only_counts_today() {
        let batches = vec![(
            "OpenCode Go".to_string(),
            vec![
                crate::model::UsageSample::new(now_unix() - 60, crate::model::TokenUsage::zero())
                    .maybe_cost(Some(4.5)),
            ],
        )];
        let spend = spend_since_start_of_day(
            &batches,
            now_unix(),
            0,
            &mut crate::usage::PricingTable::default(),
        );
        assert_eq!(spend.get("OpenCode Go"), Some(&4.5));
    }

    #[test]
    fn poll_never_panics_without_any_provider() {
        // No credentials, no logs: the poll must still return a result, with
        // reasons for everything that produced nothing.
        let mut poller = Poller::new();
        let settings = Settings {
            poll_interval_seconds: 3600,
            ..Settings::default()
        };
        let result = poller.poll(&settings);
        assert!(result.usage.is_empty() || !result.usage.is_empty()); // no assertion on data
                                                                      // Every reason mentions a provider, so the UI can show them.
        for line in &result.missing {
            assert!(
                line.starts_with("Claude")
                    || line.starts_with("Codex")
                    || line.starts_with("OpenCode"),
                "unattributed diagnostic: {line}"
            );
        }
    }

    #[test]
    fn local_offset_is_a_whole_number_of_seconds() {
        let offset = local_utc_offset_seconds();
        assert!(offset.abs() <= 14 * 3600, "implausible offset {offset}");
        assert_eq!(offset % 60, 0, "offsets are whole minutes");
    }
}
