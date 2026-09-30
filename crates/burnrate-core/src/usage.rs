//! Per-model usage: aggregation and pricing.
//!
//! The dashboard needs three derived views from the same samples, and they must
//! agree with each other: daily buckets, flat totals, and trend series. Getting
//! the *day boundary* wrong is the classic bug here — everything is bucketed by
//! local start-of-day, because that is what a person means by "yesterday".
use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::model::{TokenUsage, UsageSample};

/// Totals for one model on one provider.
///
/// `Deserialize` is derived for the persisted `modelUsageHistory` payload, which
/// is the same shape the Swift build wrote to `UserDefaults` — see
/// `crate::migration`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsageEntry {
    pub provider: String,
    pub model: String,
    pub tokens: TokenUsage,
    pub cost: f64,
    pub requests: i64,
    /// Sub-source tag (OpenCode's providerID: "opencode-go", "opencode", …).
    #[serde(default)]
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    ///
    /// `day_start` maps an instant to the local midnight of the calendar day
    /// containing it — `poller::local_start_of_day`, which is
    /// `Calendar.startOfDay`. Taking an offset instead is not enough: a day's
    /// midnight cannot be derived from the offset at an arbitrary instant, and
    /// doing so splits a daylight-saving transition day into two buckets where
    /// the calendar has one.
    pub fn daily(
        buckets: &[(String, Vec<UsageSample>)],
        days: i64,
        now: i64,
        day_start: &dyn Fn(i64) -> i64,
        pricing: &mut PricingTable,
    ) -> Vec<DailyModelUsage> {
        let window_start = now - (days - 1) * 86_400;
        let start = day_start(window_start);
        let mut by_day: HashMap<i64, HashMap<String, ModelUsageEntry>> = HashMap::new();

        for (provider, samples) in buckets {
            for sample in samples {
                if sample.timestamp < start || !Self::is_displayable(sample.model.as_deref()) {
                    continue;
                }
                let day = day_start(sample.timestamp);
                let entry = by_day
                    .entry(day)
                    .or_default()
                    .entry(entry_key(provider, sample))
                    .or_insert_with(|| make_entry(provider, sample));
                add(sample, entry, pricing);
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
    pub fn totals(
        buckets: &[(String, Vec<UsageSample>)],
        pricing: &mut PricingTable,
    ) -> Vec<ModelUsageEntry> {
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
                add(sample, &mut entry, pricing);
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

fn add(sample: &UsageSample, entry: &mut ModelUsageEntry, pricing: &mut PricingTable) {
    entry.tokens = entry.tokens + sample.tokens;
    // Vendor cost when the source reports one, otherwise a list-price estimate —
    // `ModelUsage.add`'s `sample.cost ?? PricingService.shared.cost(of: sample)`.
    entry.cost += sample_cost(sample, pricing);
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
///
/// Cache channels are only charged when the table has a rate for them, matching
/// `PricingService.estimate(model:tokens:)` — which adds them under `if let`.
/// Falling back to the input rate would silently overcharge every model whose
/// pricing entry omits them.
pub fn cost_of(sample: &UsageSample, pricing: &ModelPricing) -> f64 {
    let mut cost =
        sample.tokens.input as f64 * pricing.input + sample.tokens.output as f64 * pricing.output;
    if let Some(rate) = pricing.cache_read {
        cost += sample.tokens.cache_read as f64 * rate;
    }
    if let Some(rate) = pricing.cache_write {
        cost += sample.tokens.cache_write as f64 * rate;
    }
    cost
}

/// Cost of a sample: vendor-reported if present, else estimated from the pricing
/// table, else nothing.
///
/// This is `PricingService.cost(of:)`, and it is what puts a figure in the COST
/// column for Claude. Claude's logs carry no `costUSD`, so without the estimate
/// every Claude row reads "—" while Swift shows a list-price figure — the
/// pricing table was loaded, refreshed and never consulted.
pub fn sample_cost(sample: &UsageSample, pricing: &mut PricingTable) -> f64 {
    if let Some(vendor) = sample.cost {
        return vendor;
    }
    let Some(model) = sample.model.as_deref() else {
        return 0.0;
    };
    match pricing.lookup(model) {
        Some(entry) => cost_of(sample, &entry),
        None => 0.0,
    }
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
        let daily = ModelUsageAggregator::daily(
            &buckets,
            7,
            now(),
            &|ts| start_of_day(ts, UTC),
            &mut PricingTable::default(),
        );
        assert_eq!(daily.len(), 2, "two distinct days");
        let today = &daily[1];
        assert_eq!(today.entries.len(), 1, "two samples, same model, same day");
        assert_eq!(today.entries[0].tokens.input, 150);
        assert_eq!(today.entries[0].requests, 2);
    }

    #[test]
    fn samples_without_model_group_as_unknown() {
        let buckets = vec![(
            "Claude".to_string(),
            vec![UsageSample::new(now(), TokenUsage::new(5, 0, 0, 0))],
        )];
        let totals = ModelUsageAggregator::totals(&buckets, &mut PricingTable::default());
        assert_eq!(totals[0].model, "unknown");
    }

    /// Placeholders never reach the charts.
    #[test]
    fn skips_synthetic_models() {
        let buckets = vec![(
            "Claude".to_string(),
            vec![
                sample(None, "<synthetic>", 999, 0),
                sample(None, "opus", 10, 0),
            ],
        )];
        let totals = ModelUsageAggregator::totals(&buckets, &mut PricingTable::default());
        assert_eq!(totals.len(), 1);
        assert_eq!(totals[0].tokens.input, 10);
    }

    /// Go's and Zen's are distinct.
    #[test]
    fn same_model_on_different_sources_stays_separate() {
        let buckets = vec![(
            "OpenCode Go".to_string(),
            vec![
                sample(Some("opencode-go"), "gpt-5", 100, 0),
                sample(Some("opencode"), "gpt-5", 200, 0),
            ],
        )];
        let totals = ModelUsageAggregator::totals(&buckets, &mut PricingTable::default());
        assert_eq!(totals.len(), 2);
        let labels: Vec<String> = totals.iter().map(|entry| entry.display_name()).collect();
        assert!(labels.contains(&"gpt-5 · Go".to_string()));
        assert!(labels.contains(&"gpt-5 · Zen".to_string()));
    }

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
        let flat = ModelUsageAggregator::totals(&buckets, &mut PricingTable::default());
        let daily = ModelUsageAggregator::daily(
            &buckets,
            7,
            now(),
            &|ts| start_of_day(ts, UTC),
            &mut PricingTable::default(),
        );
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

    /// The local start-of-day boundary.
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
        let daily = ModelUsageAggregator::daily(
            &buckets,
            3,
            now(),
            &|ts| start_of_day(ts, UTC),
            &mut PricingTable::default(),
        );
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

    /// Cache channels use their own rates.
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

    /// Claude's logs carry no `costUSD`, so every Claude row in the breakdown
    /// table read "—" while Swift showed a list-price figure: the pricing table
    /// was loaded, refreshed and never consulted.
    #[test]
    fn cost_falls_back_to_the_pricing_table() {
        let mut pricing = PricingTable::new(HashMap::from([(
            "claude-opus-5".to_string(),
            ModelPricing::new(15e-6, 75e-6, Some(1.5e-6), Some(18.75e-6)),
        )]));

        // No vendor cost: estimated from the table.
        let unpriced = UsageSample::new(0, TokenUsage::new(1_000_000, 0, 0, 0));
        let unpriced = UsageSample {
            model: Some("claude-opus-5".to_string()),
            ..unpriced
        };
        assert!((sample_cost(&unpriced, &mut pricing) - 15.0).abs() < 1e-9);

        // A vendor figure wins over the estimate.
        let vendor = UsageSample {
            model: Some("claude-opus-5".to_string()),
            cost: Some(2.5),
            ..UsageSample::new(0, TokenUsage::new(1_000_000, 0, 0, 0))
        };
        assert_eq!(sample_cost(&vendor, &mut pricing), 2.5);

        // A model the table does not know stays at zero rather than guessing.
        let unknown = UsageSample {
            model: Some("no-such-model".to_string()),
            ..UsageSample::new(0, TokenUsage::new(1_000_000, 0, 0, 0))
        };
        assert_eq!(sample_cost(&unknown, &mut pricing), 0.0);
    }

    /// The estimate has to reach the aggregate the table is built from, not just
    /// the helper.
    #[test]
    fn daily_buckets_carry_estimated_cost() {
        let mut pricing = PricingTable::new(HashMap::from([(
            "claude-opus-5".to_string(),
            ModelPricing::new(15e-6, 75e-6, Some(1.5e-6), Some(18.75e-6)),
        )]));
        let now = now();
        let sample = UsageSample {
            model: Some("claude-opus-5".to_string()),
            ..UsageSample::new(now, TokenUsage::new(1_000_000, 0, 0, 0))
        };
        let buckets = vec![("Claude".to_string(), vec![sample])];
        let daily = ModelUsageAggregator::daily(
            &buckets,
            7,
            now,
            &|ts| start_of_day(ts, UTC),
            &mut pricing,
        );
        let entry = &daily.last().expect("a bucket").entries[0];
        assert!(
            (entry.cost - 15.0).abs() < 1e-9,
            "estimated cost reached the entry: {}",
            entry.cost
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
}
