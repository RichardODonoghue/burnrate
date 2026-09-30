//! Usage model: token counts, samples, quota windows, and the window
//! computation that turns samples into % remaining.
//!
//! Ported 1:1 from `Sources/BurnRateCore/UsageModel.swift`. Parity tests:
//! `UsageComputationTests`, `UsageSourceTests` (sample decoding).

use serde::{Deserialize, Serialize};

/// Token counts for one usage event.
///
/// Field names are camelCase on the wire so persisted Swift payloads
/// (`modelUsageHistory`, settings) decode unchanged across the port.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    /// Reasoning/thinking tokens. Providers that report these separately
    /// (OpenCode's DeepSeek et al.) exclude them from `output` — confirmed
    /// against rows where reasoning > output.
    #[serde(default)]
    pub reasoning: i64,
}

impl std::ops::Add for TokenUsage {
    type Output = TokenUsage;

    fn add(self, rhs: TokenUsage) -> TokenUsage {
        TokenUsage::summed(self, rhs)
    }
}

impl TokenUsage {
    pub const fn new(input: i64, output: i64, cache_read: i64, cache_write: i64) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write,
            reasoning: 0,
        }
    }

    pub const fn with_reasoning(
        input: i64,
        output: i64,
        cache_read: i64,
        cache_write: i64,
        reasoning: i64,
    ) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write,
            reasoning,
        }
    }

    pub const fn zero() -> Self {
        Self::new(0, 0, 0, 0)
    }

    /// Channel-wise sum. Used everywhere usage is accumulated, so no caller
    /// has to remember the five fields — or accidentally drop `reasoning`.
    pub fn summed(a: TokenUsage, b: TokenUsage) -> Self {
        Self {
            input: a.input + b.input,
            output: a.output + b.output,
            cache_read: a.cache_read + b.cache_read,
            cache_write: a.cache_write + b.cache_write,
            reasoning: a.reasoning + b.reasoning,
        }
    }

    /// Raw sum of every token channel, all cache traffic included.
    pub const fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write + self.reasoning
    }

    /// Cache-discounted tokens (Anthropic-style billing weights): cache reads
    /// count 0.1x, cache writes 1.25x. Use this for plan-limit %.
    pub fn weighted(&self) -> f64 {
        self.input as f64
            + self.output as f64
            + self.reasoning as f64
            + self.cache_read as f64 * 0.1
            + self.cache_write as f64 * 1.25
    }
}

/// One usage event: tokens consumed at a point in time.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageSample {
    /// Seconds since the Unix epoch.
    pub timestamp: i64,
    pub tokens: TokenUsage,
    /// Vendor request identifier, when present (Claude). Used to dedupe
    /// repeated log lines for the same request.
    pub request_id: Option<String>,
    /// Model identifier when the source records it (e.g. "claude-opus-5").
    pub model: Option<String>,
    /// Vendor-reported cost in USD when available (OpenCode only).
    pub cost: Option<f64>,
    /// Sub-source within a multi-provider source. OpenCode records the
    /// upstream provider here: "opencode-go" (Go), "opencode" (Zen),
    /// "ollama"/"lmstudio"/"omlx" (local runtimes).
    pub source_tag: Option<String>,
}

impl UsageSample {
    pub fn new(timestamp: i64, tokens: TokenUsage) -> Self {
        Self {
            timestamp,
            tokens,
            request_id: None,
            model: None,
            cost: None,
            source_tag: None,
        }
    }

    pub fn with_request_id(mut self, id: impl Into<String>) -> Self {
        self.request_id = Some(id.into());
        self
    }

    pub fn with_model(mut self, model: impl Into<String>) -> Self {
        self.model = Some(model.into());
        self
    }

    pub fn with_cost(mut self, cost: f64) -> Self {
        self.cost = Some(cost);
        self
    }

    pub fn with_source_tag(mut self, tag: impl Into<String>) -> Self {
        self.source_tag = Some(tag.into());
        self
    }

    /// Set only when the source actually recorded the field — the parsers see
    /// every shape of missing key, and "absent" is not "empty".
    pub fn maybe_request_id(mut self, id: Option<&str>) -> Self {
        self.request_id = id.map(str::to_string);
        self
    }

    pub fn maybe_model(mut self, model: Option<&str>) -> Self {
        self.model = model.map(str::to_string);
        self
    }

    pub fn maybe_cost(mut self, cost: Option<f64>) -> Self {
        self.cost = cost;
        self
    }

    pub fn maybe_source_tag(mut self, tag: Option<&str>) -> Self {
        self.source_tag = tag.map(str::to_string);
        self
    }
}

/// Aggregated usage for one plan window (Rolling / Weekly / Monthly).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub id: String,
    pub label: String,
    /// Raw tokens (all cache traffic included) — informational display.
    pub tokens_used: i64,
    /// `None` when no plan capacity is configured for this window.
    pub percent_remaining: Option<f64>,
    /// When the window resets (provider APIs supply this; local parsing can't).
    pub resets_at: Option<i64>,
}

impl UsageWindow {
    pub fn new(
        label: impl Into<String>,
        tokens_used: i64,
        percent_remaining: Option<f64>,
        resets_at: Option<i64>,
    ) -> Self {
        let label = label.into();
        Self {
            id: String::new(),
            label,
            tokens_used,
            percent_remaining,
            resets_at,
        }
    }

    /// Window with an explicit id, as the quota providers build them.
    pub fn with_id(
        id: impl Into<String>,
        label: impl Into<String>,
        tokens_used: i64,
        percent_remaining: Option<f64>,
        resets_at: Option<i64>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            tokens_used,
            percent_remaining,
            resets_at,
        }
    }
}

/// Latest usage for one provider.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsage {
    pub provider_name: String,
    /// Vendor plan tier when known (e.g. "Team 5x", "Max 20x", "Go").
    pub plan: Option<String>,
    pub windows: Vec<UsageWindow>,
}

impl ProviderUsage {
    pub fn new(
        provider_name: impl Into<String>,
        plan: Option<String>,
        windows: Vec<UsageWindow>,
    ) -> Self {
        Self {
            provider_name: provider_name.into(),
            plan,
            windows,
        }
    }

    pub fn window(&self, label: &str) -> Option<&UsageWindow> {
        self.windows.iter().find(|w| w.label == label)
    }
}

/// Maps usage samples onto rolling plan windows and computes % remaining
/// against plan capacities.
pub struct UsageComputation;

/// One window spec: label plus its length in seconds.
pub const WINDOW_SPECS: [(&str, i64); 3] = [
    ("Rolling", 5 * 3600),
    ("Weekly", 7 * 86_400),
    ("Monthly", 30 * 86_400),
];

impl UsageComputation {
    /// `now` is seconds since the Unix epoch.
    pub fn windows(
        samples: &[UsageSample],
        provider: &str,
        capacities: &std::collections::HashMap<String, i64>,
        now: i64,
    ) -> Vec<UsageWindow> {
        WINDOW_SPECS
            .iter()
            .map(|(label, seconds)| {
                let cutoff = now - seconds;
                let in_window: Vec<&UsageSample> =
                    samples.iter().filter(|s| s.timestamp >= cutoff).collect();
                let raw_used: i64 = in_window.iter().map(|s| s.tokens.total()).sum();
                // Capacities are measured in weighted tokens (cache read ×0.1,
                // write ×1.25) — raw cache traffic would blow past any capacity.
                let weighted_used: f64 = in_window.iter().map(|s| s.tokens.weighted()).sum();
                let capacity = capacities
                    .get(&format!("{provider}|{label}"))
                    .copied()
                    .unwrap_or(0);
                let percent = if capacity > 0 {
                    Some((100.0 * (1.0 - weighted_used / capacity as f64)).max(0.0))
                } else {
                    None
                };
                UsageWindow::with_id(
                    format!("{provider}-{label}"),
                    *label,
                    raw_used,
                    percent,
                    None,
                )
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const NOW: i64 = 1_700_000_000;
    const HOUR: i64 = 3600;

    fn sample(offset_secs: i64, tokens: TokenUsage) -> UsageSample {
        UsageSample::new(NOW - offset_secs, tokens)
    }

    fn capacities(pairs: &[(&str, i64)]) -> HashMap<String, i64> {
        pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
    }

    /// `percentNilWithoutCapacity` — no capacity means no percentage.
    #[test]
    fn percent_nil_without_capacity() {
        let windows = UsageComputation::windows(
            &[sample(0, TokenUsage::new(1000, 0, 0, 0))],
            "Codex",
            &HashMap::new(),
            NOW,
        );
        assert!(windows.iter().all(|w| w.percent_remaining.is_none()));
        assert_eq!(windows[0].tokens_used, 1000);
    }

    /// `percentUsesConfiguredCapacity` — % is computed against the capacity.
    #[test]
    fn percent_uses_configured_capacity() {
        let caps = capacities(&[("Codex|Rolling", 10_000)]);
        // 5,000 of 10,000 weighted → 50% remaining.
        let windows = UsageComputation::windows(
            &[sample(0, TokenUsage::new(5000, 0, 0, 0))],
            "Codex",
            &caps,
            NOW,
        );
        let rolling = windows.iter().find(|w| w.label == "Rolling").unwrap();
        assert_eq!(rolling.percent_remaining, Some(50.0));
        // Weekly/Monthly have no capacity.
        assert!(windows
            .iter()
            .find(|w| w.label == "Weekly")
            .unwrap()
            .percent_remaining
            .is_none());
    }

    /// `sumsOnlySamplesInsideWindow` — each window counts only its own span.
    #[test]
    fn sums_only_samples_inside_window() {
        // 1h old: inside Rolling(5h) and Weekly, outside nothing.
        // 10d old: inside Weekly(7d)? no — outside. Inside Monthly only.
        let samples = vec![
            sample(HOUR, TokenUsage::new(100, 0, 0, 0)),
            sample(10 * 86_400, TokenUsage::new(200, 0, 0, 0)),
        ];
        let windows = UsageComputation::windows(&samples, "Codex", &HashMap::new(), NOW);
        let get = |label: &str| {
            windows
                .iter()
                .find(|w| w.label == label)
                .unwrap()
                .tokens_used
        };
        assert_eq!(get("Rolling"), 100);
        assert_eq!(get("Weekly"), 100);
        assert_eq!(get("Monthly"), 300);
    }

    /// `codexRollingCapacityProducesPercent` — cache traffic is weighted, so
    /// raw cache reads do not blow past the capacity.
    #[test]
    fn cache_reads_are_weighted_in_percent() {
        let caps = capacities(&[("Codex|Rolling", 10_000)]);
        // 50,000 raw cache reads → 5,000 weighted (×0.1) → 50% remaining.
        let windows = UsageComputation::windows(
            &[sample(0, TokenUsage::new(0, 0, 50_000, 0))],
            "Codex",
            &caps,
            NOW,
        );
        let rolling = windows.iter().find(|w| w.label == "Rolling").unwrap();
        assert_eq!(rolling.tokens_used, 50_000);
        assert_eq!(rolling.percent_remaining, Some(50.0));
    }

    #[test]
    fn percent_clamps_at_zero() {
        let caps = capacities(&[("Codex|Rolling", 1_000)]);
        let windows = UsageComputation::windows(
            &[sample(0, TokenUsage::new(9_000, 0, 0, 0))],
            "Codex",
            &caps,
            NOW,
        );
        let rolling = windows.iter().find(|w| w.label == "Rolling").unwrap();
        assert_eq!(rolling.percent_remaining, Some(0.0));
    }

    /// `reasoningTokensCountTowardTotals` — reasoning counts in both totals.
    #[test]
    fn reasoning_counts_toward_totals() {
        let tokens = TokenUsage::with_reasoning(10, 20, 0, 0, 30);
        assert_eq!(tokens.total(), 60);
        assert_eq!(tokens.weighted(), 60.0);
    }

    /// `weightedTokensDiscountCacheReads` — 0.1x read, 1.25x write.
    #[test]
    fn weighted_tokens_discount_cache_reads() {
        let tokens = TokenUsage::new(0, 0, 1_000, 1_000);
        assert_eq!(tokens.weighted(), 100.0 + 1250.0);
        assert_eq!(tokens.total(), 2_000);
    }

    /// `legacyTokenUsageDecodesWithoutReasoning` — older payloads have no
    /// `reasoning` key; serde's `default` covers it.
    #[test]
    fn legacy_token_usage_decodes_without_reasoning() {
        let json = r#"{"input":1,"output":2,"cacheRead":3,"cacheWrite":4}"#;
        let tokens: TokenUsage = serde_json::from_str(json).unwrap();
        assert_eq!(tokens.reasoning, 0);
        assert_eq!(tokens.total(), 10);
    }

    #[test]
    fn window_lookup_by_label() {
        let usage = ProviderUsage::new(
            "Codex",
            None,
            vec![UsageWindow::new("Rolling", 1, Some(50.0), None)],
        );
        assert!(usage.window("Rolling").is_some());
        assert!(usage.window("Weekly").is_none());
    }

    /// The wire keys are camelCase and the frontend reads them by name. A
    /// snake_case read finds nothing, and inside a lookup with a fallback that
    /// failure is silent: the notifications pane read `provider_name`, so it
    /// never used the provider's own window list and quietly fell through to a
    /// hardcoded one that happened to look right.
    #[test]
    fn provider_usage_wire_keys_are_camel_case() {
        let usage = ProviderUsage::new(
            "Claude",
            None,
            vec![UsageWindow::new("Rolling", 0, Some(80.0), None)],
        );
        let json = serde_json::to_string(&usage).expect("serialises");
        assert!(json.contains("\"providerName\""), "got {json}");
        assert!(json.contains("\"windows\""), "got {json}");
        assert!(!json.contains("provider_name"), "snake_case leaked: {json}");
        assert!(!json.contains("tokens_used"), "snake_case leaked: {json}");
        assert!(
            !json.contains("percent_remaining"),
            "snake_case leaked: {json}"
        );
    }
}
