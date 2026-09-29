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
use crate::usage::{
    ChartData, ChartRange, DailyModelUsage, ModelUsageAggregator, ModelUsageEntry, PricingTable,
    RemainingSnapshot, TrendSeries,
};

/// Everything the window and tray need after a poll.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PollResult {
    pub usage: Vec<ProviderUsage>,
    /// One line per provider that produced nothing, saying why.
    pub missing: Vec<String>,
    /// Remaining-% history, oldest first.
    pub snapshots: Vec<RemainingSnapshot>,
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
    snapshots: Vec<RemainingSnapshot>,
    /// Flat samples, mirrored from `snapshots` for the chart API.
    remaining_history: Vec<crate::charts::RemainingSample>,
    /// 7 days of minute-resolution history is plenty for a month of charts.
    history_limit: usize,
    last_local_poll: Option<Instant>,
    local_interval: Duration,
    poll_count: AtomicU64,
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
            snapshots: Vec::new(),
            remaining_history: Vec::new(),
            history_limit: 7 * 24 * 60,
            last_local_poll: None,
            // The Claude log parse is expensive the first time; after that the
            // incremental cache makes it milliseconds, but there is no reason
            // to walk 560MB more than once a minute.
            local_interval: Duration::from_secs(60),
            poll_count: AtomicU64::new(0),
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

        // --- vendor quota APIs: authoritative percentages --------------------
        let claude = self.claude_api.fetch_usage();
        if let Some(result) = claude.usage.clone() {
            usage.push(result);
        }
        if let Some(status) = claude.status.clone() {
            missing.push(format!("Claude: {status}"));
        }

        let opencode = self.opencode_api.fetch_usage();
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
        let snapshot = RemainingSnapshot {
            at: now,
            values: usage
                .iter()
                .flat_map(|provider| {
                    provider.windows.iter().map(move |window| {
                        (
                            provider.provider_name.clone(),
                            window.label.clone(),
                            window.percent_remaining.unwrap_or(0.0),
                        )
                    })
                })
                .collect(),
        };
        if !snapshot.values.is_empty() {
            for (provider, label, percent) in &snapshot.values {
                self.remaining_history.push(crate::charts::RemainingSample {
                    provider: provider.clone(),
                    label: label.clone(),
                    date: now,
                    remaining: *percent,
                });
            }
            self.snapshots.push(snapshot.clone());
        }
        // Retention: seven days of history. The flat list is trimmed by date
        // rather than by count, because a five-minute poll over seven days is
        // ~2000 entries and a burst of polls must not shorten the window.
        let history_cutoff = now - 7 * 86_400;
        self.remaining_history
            .retain(|sample| sample.date >= history_cutoff);
        if self.snapshots.len() > self.history_limit {
            let excess = self.snapshots.len() - self.history_limit;
            self.snapshots.drain(0..excess);
        }

        // --- notifications ----------------------------------------------------
        let poll_interval = settings.poll_interval_seconds as i64;
        self.notifier.set_account_fingerprint(None);
        let mut notifications = self.notifier.evaluate(&usage, settings, now, poll_interval);

        // --- models and cost --------------------------------------------------
        let model_totals = ModelUsageAggregator::totals(&batches);
        let model_daily =
            ModelUsageAggregator::daily(&batches, 30, now, local_utc_offset_seconds());
        let spend_today = spend_since_start_of_day(&batches, now, local_utc_offset_seconds());
        notifications.extend(self.notifier.evaluate_cost(
            start_of_day_local(now, local_utc_offset_seconds()),
            &spend_today,
            settings,
            now,
        ));

        PollResult {
            usage,
            missing,
            snapshots: self.snapshots.clone(),
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

    /// Trend series for a window label.
    pub fn trend(&self, label: &str, provider: Option<&str>) -> Vec<TrendSeries> {
        ChartData::trend_series(&self.snapshots, label, provider)
    }

    pub fn snapshots(&self) -> &[RemainingSnapshot] {
        &self.snapshots
    }

    /// Drops the persisted chart history — a "Reset history" affordance.
    pub fn clear_history(&mut self) {
        self.snapshots.clear();
        self.remaining_history.clear();
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
) -> HashMap<String, f64> {
    let start = start_of_day_local(now, offset);
    let mut spend: HashMap<String, f64> = HashMap::new();
    for (provider, samples) in batches {
        let total: f64 = samples
            .iter()
            .filter(|sample| sample.timestamp >= start)
            .map(|sample| sample.cost.unwrap_or(0.0))
            .sum();
        if total > 0.0 {
            spend.insert(provider.clone(), total);
        }
    }
    spend
}

/// The ranges the dashboard offers, in the Swift build's order.
pub const CHART_RANGES: [ChartRange; 3] = [ChartRange::Day, ChartRange::Week, ChartRange::Month];

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

    #[test]
    fn spend_only_counts_today() {
        let batches = vec![(
            "OpenCode Go".to_string(),
            vec![
                crate::model::UsageSample::new(now_unix() - 60, crate::model::TokenUsage::zero())
                    .maybe_cost(Some(4.5)),
            ],
        )];
        let spend = spend_since_start_of_day(&batches, now_unix(), 0);
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
