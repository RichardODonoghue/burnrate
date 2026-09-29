//! Per-model usage: aggregation, pricing, and the series the charts draw.
//!
//! Ported 1:1 from `Sources/BurnRateCore/ModelUsage.swift`, `Pricing.swift` and
//! `ChartData.swift`.
//!
//! The dashboard needs three derived views from the same samples, and they must
//! agree with each other: daily buckets, flat totals, and trend series. Getting
//! the *day boundary* wrong is the classic bug here — everything is bucketed by
//! local start-of-day, because that is what a person means by "yesterday".

use std::collections::HashMap;

use serde::Serialize;

use crate::model::{TokenUsage, UsageSample};

/// Totals for one model on one provider.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsageEntry {
    pub provider: String,
    pub model: String,
    pub tokens: TokenUsage,
    pub cost: f64,
    pub requests: i64,
    /// Sub-source tag (OpenCode's providerID: "opencode-go", "opencode", …).
    pub source_tag: Option<String>,
}

impl ModelUsageEntry {
    pub fn total_tokens(&self) -> i64 {
        self.tokens.total()
    }

    /// Friendly sub-source name: "Go", "Zen", "Ollama", "LM Studio", "OMLX".
    pub fn tag_label(&self) -> Option<String> {
        self.source_tag.as_deref().map(Self::label_for_tag)
    }

    /// Model name, qualified by the sub-source when there is one — Go's models
    /// and Zen's are distinct services and must read differently.
    pub fn display_name(&self) -> String {
        match self.tag_label() {
            Some(label) => format!("{} · {label}", self.model),
            None => self.model.clone(),
        }
    }

    pub fn label_for_tag(tag: &str) -> String {
        match tag {
            "opencode-go" => "Go",
            "opencode" => "Zen",
            "ollama" => "Ollama",
            "lmstudio" => "LM Studio",
            "omlx" => "OMLX",
            other => other,
        }
        .to_string()
    }
}

/// One day of per-model usage. `day` is a local start-of-day epoch.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DailyModelUsage {
    pub day: i64,
    pub entries: Vec<ModelUsageEntry>,
}

pub struct ModelUsageAggregator;

impl ModelUsageAggregator {
    /// Claude Code emits zero-usage placeholder turns with model
    /// `<synthetic>`; they are not a model and must never be counted or listed,
    /// including when they arrive from a persisted snapshot.
    pub fn is_displayable(model: Option<&str>) -> bool {
        !matches!(model, Some("<synthetic>"))
    }

    /// Buckets samples into per-day per-model totals over the trailing `days`,
    /// merging across providers. `now` is seconds since the Unix epoch.
    pub fn daily(
        buckets: &[(String, Vec<UsageSample>)],
        days: i64,
        now: i64,
        local_offset_seconds: i64,
    ) -> Vec<DailyModelUsage> {
        let start = start_of_day(now - (days - 1) * 86_400, local_offset_seconds);
        let mut by_day: HashMap<i64, HashMap<String, ModelUsageEntry>> = HashMap::new();

        for (provider, samples) in buckets {
            for sample in samples {
                if sample.timestamp < start || !Self::is_displayable(sample.model.as_deref()) {
                    continue;
                }
                let day = start_of_day(sample.timestamp, local_offset_seconds);
                let entry = by_day
                    .entry(day)
                    .or_default()
                    .entry(entry_key(provider, sample))
                    .or_insert_with(|| make_entry(provider, sample));
                add(sample, entry);
            }
        }

        let mut out: Vec<DailyModelUsage> = by_day
            .into_iter()
            .map(|(day, entries)| {
                let mut entries: Vec<ModelUsageEntry> = entries.into_values().collect();
                entries.sort_by_key(|entry| std::cmp::Reverse(entry.total_tokens()));
                DailyModelUsage { day, entries }
            })
            .collect();
        out.sort_by_key(|day| day.day);
        out
    }

    /// Flat totals over all provided samples, sorted by tokens.
    pub fn totals(buckets: &[(String, Vec<UsageSample>)]) -> Vec<ModelUsageEntry> {
        let mut by_key: HashMap<String, ModelUsageEntry> = HashMap::new();
        for (provider, samples) in buckets {
            for sample in samples {
                if !Self::is_displayable(sample.model.as_deref()) {
                    continue;
                }
                let key = entry_key(provider, sample);
                let mut entry = by_key
                    .get(&key)
                    .cloned()
                    .unwrap_or_else(|| make_entry(provider, sample));
                add(sample, &mut entry);
                by_key.insert(key, entry);
            }
        }
        let mut entries: Vec<ModelUsageEntry> = by_key.into_values().collect();
        entries.sort_by_key(|entry| std::cmp::Reverse(entry.total_tokens()));
        entries
    }

    /// Totals summed across the daily buckets, which must agree with
    /// [`Self::totals`] for the same input.
    pub fn totals_from_daily(daily: &[DailyModelUsage]) -> Vec<ModelUsageEntry> {
        let mut by_key: HashMap<String, ModelUsageEntry> = HashMap::new();
        for day in daily {
            for entry in &day.entries {
                let key = entry_key_for_entry(entry);
                match by_key.get_mut(&key) {
                    Some(existing) => merge_entries(existing, entry),
                    None => {
                        by_key.insert(key, entry.clone());
                    }
                }
            }
        }
        let mut entries: Vec<ModelUsageEntry> = by_key.into_values().collect();
        entries.sort_by_key(|entry| std::cmp::Reverse(entry.total_tokens()));
        entries
    }
}

/// Adds one entry's tokens, cost and request count into another.
fn merge_entries(into: &mut ModelUsageEntry, from: &ModelUsageEntry) {
    into.tokens = into.tokens + from.tokens;
    into.cost += from.cost;
    into.requests += from.requests;
}

/// Local start-of-day for an epoch second, given the UTC offset.
pub fn start_of_day(timestamp: i64, local_offset_seconds: i64) -> i64 {
    let local = timestamp + local_offset_seconds;
    (local.div_euclid(86_400)) * 86_400 - local_offset_seconds
}

fn entry_key(provider: &str, sample: &UsageSample) -> String {
    match &sample.source_tag {
        Some(tag) => format!(
            "{provider}|{tag}|{}",
            sample.model.as_deref().unwrap_or("unknown")
        ),
        None => format!(
            "{provider}|{}",
            sample.model.as_deref().unwrap_or("unknown")
        ),
    }
}

fn entry_key_for_entry(entry: &ModelUsageEntry) -> String {
    match &entry.source_tag {
        Some(tag) => format!("{}|{tag}|{}", entry.provider, entry.model),
        None => format!("{}|{}", entry.provider, entry.model),
    }
}

fn make_entry(provider: &str, sample: &UsageSample) -> ModelUsageEntry {
    ModelUsageEntry {
        provider: provider.to_string(),
        model: sample
            .model
            .clone()
            .unwrap_or_else(|| "unknown".to_string()),
        tokens: TokenUsage::zero(),
        cost: 0.0,
        requests: 0,
        source_tag: sample.source_tag.clone(),
    }
}

fn add(sample: &UsageSample, entry: &mut ModelUsageEntry) {
    entry.tokens = entry.tokens + sample.tokens;
    entry.cost += sample.cost.unwrap_or(0.0);
    entry.requests += 1;
}

// MARK: - Pricing

/// Per-token USD costs for one model.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelPricing {
    pub input: f64,
    pub output: f64,
    pub cache_read: Option<f64>,
    pub cache_write: Option<f64>,
}

impl ModelPricing {
    pub const fn new(
        input: f64,
        output: f64,
        cache_read: Option<f64>,
        cache_write: Option<f64>,
    ) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write,
        }
    }
}

/// Cost of a sample under a pricing entry.
pub fn cost_of(sample: &UsageSample, pricing: &ModelPricing) -> f64 {
    sample.tokens.input as f64 * pricing.input
        + sample.tokens.output as f64 * pricing.output
        + sample.tokens.cache_read as f64 * pricing.cache_read.unwrap_or(pricing.input)
        + sample.tokens.cache_write as f64 * pricing.cache_write.unwrap_or(pricing.input)
}

/// Resolves a model name to a price, memoised: the LiteLLM table is large and
/// lookups run per sample.
#[derive(Default)]
pub struct PricingTable {
    table: HashMap<String, ModelPricing>,
    resolved: HashMap<String, ModelPricing>,
    unresolved: Vec<String>,
}

impl PricingTable {
    /// Prices in USD per token.
    pub fn new(table: HashMap<String, ModelPricing>) -> Self {
        Self {
            table,
            resolved: HashMap::new(),
            unresolved: Vec::new(),
        }
    }

    /// Parses LiteLLM's `model_prices_and_context_window.json`. The
    /// `*_cost_per_token` fields are already per token.
    ///
    /// Only bare model keys are kept ("claude-opus-5"), not provider-prefixed
    /// variants ("anthropic.claude-…", "vertex_ai/…"), which are the same model
    /// priced differently and would shadow the real one.
    pub fn from_litellm_json(data: &[u8]) -> Result<Self, String> {
        let value: serde_json::Value =
            serde_json::from_slice(data).map_err(|error| error.to_string())?;
        let object = value
            .as_object()
            .ok_or_else(|| "pricing table was not an object".to_string())?;
        let mut table = HashMap::new();
        for (model, entry) in object {
            if model.contains('/') || model.contains('.') {
                continue;
            }
            let Some(entry) = entry.as_object() else {
                continue;
            };
            let (Some(input), Some(output)) = (
                entry.get("input_cost_per_token").and_then(|v| v.as_f64()),
                entry.get("output_cost_per_token").and_then(|v| v.as_f64()),
            ) else {
                continue;
            };
            let optional = |name: &str| entry.get(name).and_then(|v| v.as_f64());
            table.insert(
                model.to_lowercase(),
                ModelPricing::new(
                    input,
                    output,
                    optional("cache_read_input_token_cost"),
                    optional("cache_creation_input_token_cost"),
                ),
            );
        }
        Ok(Self::new(table))
    }

    /// Longest-prefix match against the table, so "claude-opus-4-20250514"
    /// resolves via a "claude-opus-4" entry when no exact key exists.
    pub fn lookup(&mut self, model: &str) -> Option<ModelPricing> {
        if let Some(cached) = self.resolved.get(model) {
            return Some(*cached);
        }
        if self.table.contains_key(model) {
            let pricing = self.table[model];
            self.resolved.insert(model.to_string(), pricing);
            return Some(pricing);
        }
        let found = self
            .table
            .iter()
            .filter(|(key, _)| model.starts_with(key.as_str()))
            .max_by_key(|(key, _)| key.len())
            .map(|(_, pricing)| *pricing);
        match found {
            Some(pricing) => {
                self.resolved.insert(model.to_string(), pricing);
                Some(pricing)
            }
            None => {
                if !self.unresolved.iter().any(|seen| seen == model) {
                    self.unresolved.push(model.to_string());
                }
                None
            }
        }
    }

    /// Models that could not be priced, so the UI can say so rather than
    /// showing a confident $0.00.
    pub fn unresolved(&self) -> &[String] {
        &self.unresolved
    }

    pub fn len(&self) -> usize {
        self.table.len()
    }

    pub fn is_empty(&self) -> bool {
        self.table.is_empty()
    }
}

// MARK: - Charts

/// Which window the dashboard is showing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChartRange {
    Day,
    Week,
    Month,
}

impl ChartRange {
    /// How many days the range covers.
    pub fn days(self) -> i64 {
        match self {
            ChartRange::Day => 1,
            ChartRange::Week => 7,
            ChartRange::Month => 30,
        }
    }
}

/// One provider's remaining-% series, for the trend chart.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendSeries {
    pub provider: String,
    /// `true` when this is a model-scoped window (Claude's "Fable"), which is
    /// drawn faded so it does not read as the account total.
    pub scoped: bool,
    /// (epoch seconds, percent remaining) in chronological order.
    pub points: Vec<(i64, f64)>,
}

/// A snapshot of every provider window's remaining %, appended once per poll.
/// This is the only history the trend chart needs, and it is small enough to
/// persist verbatim.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemainingSnapshot {
    /// Seconds since the Unix epoch.
    pub at: i64,
    /// (provider, window label, percent remaining)
    pub values: Vec<(String, String, f64)>,
}

/// Builds the chart series from persisted snapshots.
pub struct ChartData;

impl ChartData {
    /// Series for one window label, one line per provider, in chronological
    /// order. `provider_filter` of `None` keeps every provider.
    pub fn trend_series(
        snapshots: &[RemainingSnapshot],
        label: &str,
        provider_filter: Option<&str>,
    ) -> Vec<TrendSeries> {
        let mut by_provider: HashMap<String, Vec<(i64, f64)>> = HashMap::new();
        for snapshot in snapshots {
            for (provider, window_label, percent) in &snapshot.values {
                if window_label != label {
                    continue;
                }
                if let Some(filter) = provider_filter {
                    if provider != filter {
                        continue;
                    }
                }
                by_provider
                    .entry(provider.clone())
                    .or_default()
                    .push((snapshot.at, *percent));
            }
        }
        let mut series: Vec<TrendSeries> = by_provider
            .into_iter()
            .map(|(provider, mut points)| {
                points.sort_by_key(|(at, _)| *at);
                // The label suffix marks model-scoped windows, which are drawn
                // faded: "Claude (Fable)" rather than "Claude".
                let (provider, scoped) = match provider.split_once(" (") {
                    Some((base, scope)) => {
                        (base.to_string(), scope.trim_end_matches(')').to_string())
                    }
                    None => (provider.clone(), String::new()),
                };
                TrendSeries {
                    provider,
                    scoped: !scoped.is_empty(),
                    points,
                }
            })
            .collect();
        series.sort_by(|a, b| a.provider.cmp(&b.provider));
        series
    }

    /// The x domain for a range: `[earliest, latest]`, or an empty series when
    /// there is no data (the caller decides what to draw then).
    pub fn x_domain(points: &[(i64, f64)], range: ChartRange) -> Option<(i64, i64)> {
        if points.is_empty() {
            return None;
        }
        let first = points.first()?.0;
        let last = points.last()?.0;
        let _ = range;
        Some((first, last))
    }

    /// Y bounds, padded so a flat line at 100% is not drawn on the frame.
    pub fn y_domain(series: &[TrendSeries]) -> Option<(f64, f64)> {
        let mut min = f64::INFINITY;
        let mut max = f64::NEG_INFINITY;
        for line in series {
            for (_, percent) in &line.points {
                min = min.min(*percent);
                max = max.max(*percent);
            }
        }
        if !min.is_finite() || !max.is_finite() {
            return None;
        }
        Some((min.floor().max(0.0), max.ceil().min(100.0)))
    }

    /// Nearest point to `at` in a series, for the hover tooltip. Binary search,
    /// because a month of minute-resolution polls is a few thousand points.
    pub fn nearest_point(points: &[(i64, f64)], at: i64) -> Option<(i64, f64)> {
        if points.is_empty() {
            return None;
        }
        let index = points
            .binary_search_by_key(&at, |(stamp, _)| *stamp)
            .unwrap_or_else(|insertion| insertion);
        let index = index.min(points.len() - 1);
        let candidate = points[index];
        if index > 0 {
            let previous = points[index - 1];
            if (previous.0 - at).abs() < (candidate.0 - at).abs() {
                return Some(previous);
            }
        }
        if index + 1 < points.len() {
            let next = points[index + 1];
            if (next.0 - at).abs() < (candidate.0 - at).abs() {
                return Some(next);
            }
        }
        Some(candidate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 86_400;
    const UTC: i64 = 0;

    fn now() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }

    fn sample(provider_tag: Option<&str>, model: &str, input: i64, day_offset: i64) -> UsageSample {
        UsageSample::new(now() - day_offset * DAY, TokenUsage::new(input, 0, 0, 0))
            .maybe_model(Some(model))
            .maybe_source_tag(provider_tag)
    }

    /// `aggregatesPerDayPerModel`.
    #[test]
    fn aggregates_per_day_per_model() {
        let buckets = vec![(
            "Claude".to_string(),
            vec![
                sample(None, "opus", 100, 0),
                sample(None, "opus", 50, 0),
                sample(None, "sonnet", 20, 1),
            ],
        )];
        let daily = ModelUsageAggregator::daily(&buckets, 7, now(), UTC);
        assert_eq!(daily.len(), 2, "two distinct days");
        let today = &daily[1];
        assert_eq!(today.entries.len(), 1, "two samples, same model, same day");
        assert_eq!(today.entries[0].tokens.input, 150);
        assert_eq!(today.entries[0].requests, 2);
    }

    /// `samplesWithoutModelGroupAsUnknown`.
    #[test]
    fn samples_without_model_group_as_unknown() {
        let buckets = vec![(
            "Claude".to_string(),
            vec![UsageSample::new(now(), TokenUsage::new(5, 0, 0, 0))],
        )];
        let totals = ModelUsageAggregator::totals(&buckets);
        assert_eq!(totals[0].model, "unknown");
    }

    /// `skipsSyntheticModels` — placeholders never reach the charts.
    #[test]
    fn skips_synthetic_models() {
        let buckets = vec![(
            "Claude".to_string(),
            vec![
                sample(None, "<synthetic>", 999, 0),
                sample(None, "opus", 10, 0),
            ],
        )];
        let totals = ModelUsageAggregator::totals(&buckets);
        assert_eq!(totals.len(), 1);
        assert_eq!(totals[0].tokens.input, 10);
    }

    /// `sameModelOnDifferentSourcesStaysSeparate` — Go's and Zen's are distinct.
    #[test]
    fn same_model_on_different_sources_stays_separate() {
        let buckets = vec![(
            "OpenCode Go".to_string(),
            vec![
                sample(Some("opencode-go"), "gpt-5", 100, 0),
                sample(Some("opencode"), "gpt-5", 200, 0),
            ],
        )];
        let totals = ModelUsageAggregator::totals(&buckets);
        assert_eq!(totals.len(), 2);
        let labels: Vec<String> = totals.iter().map(|entry| entry.display_name()).collect();
        assert!(labels.contains(&"gpt-5 · Go".to_string()));
        assert!(labels.contains(&"gpt-5 · Zen".to_string()));
    }

    /// `tagLabelsReadAsServices`.
    #[test]
    fn tag_labels_read_as_services() {
        assert_eq!(ModelUsageEntry::label_for_tag("opencode-go"), "Go");
        assert_eq!(ModelUsageEntry::label_for_tag("opencode"), "Zen");
        assert_eq!(ModelUsageEntry::label_for_tag("lmstudio"), "LM Studio");
        assert_eq!(ModelUsageEntry::label_for_tag("omlx"), "OMLX");
        assert_eq!(
            ModelUsageEntry::label_for_tag("something-else"),
            "something-else"
        );
    }

    /// `totalsMergeAcrossDays` and `totalsFromDailyMergesAcrossDays` — the two
    /// routes to the same number must agree.
    #[test]
    fn totals_from_daily_matches_flat_totals() {
        let buckets = vec![(
            "OpenCode Go".to_string(),
            vec![
                sample(Some("opencode-go"), "gpt-5", 100, 0),
                sample(Some("opencode-go"), "gpt-5", 250, 2),
                sample(Some("opencode-go"), "opus", 40, 1),
            ],
        )];
        let flat = ModelUsageAggregator::totals(&buckets);
        let daily = ModelUsageAggregator::daily(&buckets, 7, now(), UTC);
        let merged = ModelUsageAggregator::totals_from_daily(&daily);

        assert_eq!(flat.len(), merged.len());
        for entry in &flat {
            let other = merged
                .iter()
                .find(|candidate| candidate.model == entry.model)
                .expect("same models");
            assert_eq!(entry.tokens.input, other.tokens.input, "{}", entry.model);
            assert_eq!(entry.requests, other.requests);
        }
    }

    /// `dayBucketMatchesOnlySameDay` — the local start-of-day boundary.
    #[test]
    fn day_bucket_matches_only_same_day() {
        let base = start_of_day(now(), UTC);
        let buckets = vec![(
            "Claude".to_string(),
            vec![
                UsageSample::new(base + 60, TokenUsage::new(10, 0, 0, 0)),
                UsageSample::new(base + DAY + 60, TokenUsage::new(20, 0, 0, 0)),
            ],
        )];
        let daily = ModelUsageAggregator::daily(&buckets, 3, now(), UTC);
        assert_eq!(daily.len(), 2);
        assert_eq!(daily[0].entries[0].tokens.input, 10);
        assert_eq!(daily[1].entries[0].tokens.input, 20);
    }

    /// A non-UTC offset shifts the boundary, which is the whole point of
    /// passing it in.
    #[test]
    fn local_offset_shifts_the_day_boundary() {
        let utc_midnight = 1_700_000_000 / DAY * DAY * DAY;
        let nz_offset = 12 * 3600; // UTC+12
        let local_midnight = start_of_day(utc_midnight, nz_offset);
        assert_eq!(local_midnight + nz_offset, utc_midnight);
    }

    // ---- pricing ----

    /// `costCalculationWeightsCaches` — cache channels use their own rates.
    #[test]
    fn cost_calculation_weights_caches() {
        let pricing = ModelPricing::new(3e-6, 15e-6, Some(0.3e-6), Some(3.75e-6));
        let sample = UsageSample::new(
            0,
            TokenUsage::new(1_000_000, 1_000_000, 1_000_000, 1_000_000),
        );
        let cost = cost_of(&sample, &pricing);
        assert!(
            (cost - (3.0 + 15.0 + 0.3 + 3.75)).abs() < 0.001,
            "got {cost}"
        );
    }

    #[test]
    fn litellm_table_is_parsed_per_token() {
        let json = br#"{
            "gpt-5": {"input_cost_per_token": 0.00000125, "output_cost_per_token": 0.00001},
            "claude-opus-4": {"input_cost_per_token": 0.000015,
                              "output_cost_per_token": 0.000075,
                              "cache_read_input_token_cost": 0.0000015},
            "anthropic.claude-opus-4": {"input_cost_per_token": 9.9,
                                        "output_cost_per_token": 9.9},
            "vertex_ai/claude-opus-4": {"input_cost_per_token": 9.9,
                                        "output_cost_per_token": 9.9},
            "broken": {"input_cost_per_token": 0.1}
        }"#;
        let mut table = PricingTable::from_litellm_json(json).unwrap();
        assert_eq!(
            table.len(),
            2,
            "no output cost, and provider-prefixed keys, dropped"
        );
        assert_eq!(table.lookup("gpt-5").unwrap().input, 1.25e-6);
        // Longest-prefix resolution for a dated model name.
        assert_eq!(table.lookup("claude-opus-4-20250514").unwrap().input, 15e-6);
        assert_eq!(table.lookup("gpt-5").unwrap().input, 1.25e-6, "memoised");
        assert!(table.lookup("never-heard-of-it").is_none());
        assert_eq!(table.unresolved(), &["never-heard-of-it".to_string()]);
    }

    // ---- charts ----

    fn snapshots() -> Vec<RemainingSnapshot> {
        vec![
            RemainingSnapshot {
                at: 1_000,
                values: vec![
                    ("Claude".into(), "Rolling".into(), 80.0),
                    ("Codex".into(), "Rolling".into(), 40.0),
                ],
            },
            RemainingSnapshot {
                at: 2_000,
                values: vec![
                    ("Claude".into(), "Rolling".into(), 70.0),
                    ("Codex".into(), "Rolling".into(), 38.0),
                ],
            },
            RemainingSnapshot {
                at: 3_000,
                values: vec![
                    ("Claude".into(), "Rolling".into(), 65.0),
                    ("Codex".into(), "Rolling".into(), 20.0),
                ],
            },
        ]
    }

    /// `rollingCardHonorsProviderFilter` and the general series build.
    #[test]
    fn trend_series_are_per_provider_and_chronological() {
        let series = ChartData::trend_series(&snapshots(), "Rolling", None);
        assert_eq!(series.len(), 2);
        assert_eq!(series[0].provider, "Claude");
        assert_eq!(series[0].points.len(), 3);
        // Chronological even if the snapshots arrive out of order.
        let reversed: Vec<RemainingSnapshot> = snapshots().into_iter().rev().collect();
        let out_of_order = ChartData::trend_series(&reversed, "Rolling", None);
        let first = out_of_order[0].points[0];
        assert!(first.0 < out_of_order[0].points[1].0, "sorted by time");
    }

    #[test]
    fn trend_series_honours_a_provider_filter() {
        let series = ChartData::trend_series(&snapshots(), "Rolling", Some("Codex"));
        assert_eq!(series.len(), 1);
        assert_eq!(series[0].provider, "Codex");
    }

    /// A model-scoped window is marked so the chart can fade it.
    #[test]
    fn scoped_windows_are_flagged() {
        let data = vec![RemainingSnapshot {
            at: 1,
            values: vec![("Claude (Fable)".into(), "Weekly".into(), 30.0)],
        }];
        let series = ChartData::trend_series(&data, "Weekly", None);
        assert_eq!(series[0].provider, "Claude");
        assert!(series[0].scoped, "a scoped window draws faded");
    }

    #[test]
    fn unknown_window_label_yields_no_series() {
        assert!(ChartData::trend_series(&snapshots(), "Monthly", None).is_empty());
    }

    /// `emptySeriesUsesFullDomain` / `xDomainFallsBackToFullRangeWhenEmpty`.
    #[test]
    fn x_domain_is_none_when_empty() {
        assert_eq!(ChartData::x_domain(&[], ChartRange::Month), None);
        assert_eq!(
            ChartData::x_domain(&[(10, 50.0), (20, 60.0)], ChartRange::Month),
            Some((10, 20))
        );
    }

    /// `yTicksStayInsideDomain` — the domain is clamped to 0–100.
    #[test]
    fn y_domain_is_clamped_to_percent() {
        let series = ChartData::trend_series(&snapshots(), "Rolling", None);
        let (low, high) = ChartData::y_domain(&series).unwrap();
        assert!(low >= 0.0 && high <= 100.0, "got {low}..{high}");
        assert!(low <= 20.0 && high >= 80.0);
        assert_eq!(ChartData::y_domain(&[]), None);
    }

    /// `nearestPointBinarySearchesSortedSamples`.
    #[test]
    fn nearest_point_binary_searches() {
        let points = vec![(0, 10.0), (100, 20.0), (200, 30.0)];
        assert_eq!(ChartData::nearest_point(&points, 95), Some((100, 20.0)));
        assert_eq!(ChartData::nearest_point(&points, 190), Some((200, 30.0)));
        assert_eq!(ChartData::nearest_point(&points, -50), Some((0, 10.0)));
        assert_eq!(ChartData::nearest_point(&points, 10_000), Some((200, 30.0)));
        assert_eq!(ChartData::nearest_point(&[], 5), None);
    }

    #[test]
    fn chart_range_days() {
        assert_eq!(ChartRange::Day.days(), 1);
        assert_eq!(ChartRange::Week.days(), 7);
        assert_eq!(ChartRange::Month.days(), 30);
    }
}
