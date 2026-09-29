//! Platform-independent BurnRate logic.
//!
//! Everything here is pure Rust with no Tauri, UI or OS-framework dependency:
//! local log parsing, vendor quota APIs, throttling, alert evaluation, chart
//! aggregation. Ported 1:1 from the Swift `BurnRateCore` target, whose 111 tests
//! are the parity spec (see `PARITY.md`).

pub mod alerts;
pub mod dial;
pub mod formatting;
pub mod icon;
pub mod menu;
pub mod model;

/// Crate version, surfaced in the UI so the app can report which core it runs.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Fixed token capacities (weighted: cache read ×0.1, write ×1.25) for
/// local-log providers, keyed "provider|windowLabel". Codex is the only
/// provider measured from logs; the quota APIs report their own %.
///
/// Capacities are predetermined — there is no UI to edit them.
pub fn plan_capacities_by_provider_window() -> std::collections::HashMap<String, i64> {
    [
        ("Codex|Rolling", 12_000_000),
        ("Codex|Weekly", 120_000_000),
        ("Codex|Monthly", 400_000_000),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{TokenUsage, UsageSample, UsageWindow};
    use std::collections::HashMap;

    #[test]
    fn capacities_are_keyed_provider_pipe_window() {
        let caps = plan_capacities_by_provider_window();
        assert_eq!(caps.get("Codex|Rolling"), Some(&12_000_000));
        assert_eq!(caps.get("Codex|Weekly"), Some(&120_000_000));
        assert_eq!(caps.get("Codex|Monthly"), Some(&400_000_000));
        // Only Codex is measured from local logs.
        assert_eq!(caps.len(), 3);
        assert!(!caps.keys().any(|key| key.starts_with("Claude")));
    }

    /// `codexLocalProviderProducesRemainingPercent` — the end-to-end shape a
    /// local provider produces, which is why the capacities exist.
    #[test]
    fn codex_local_provider_produces_remaining_percent() {
        let now = 1_700_000_000;
        let samples = vec![UsageSample::new(
            now - 60,
            TokenUsage::new(1_000_000, 0, 0, 0),
        )];
        let windows = model::UsageComputation::windows(
            &samples,
            "Codex",
            &plan_capacities_by_provider_window(),
            now,
        );
        let rolling = windows.iter().find(|w| w.label == "Rolling").unwrap();
        let percent = rolling.percent_remaining.expect("capacity configured");
        // 1M of 12M weighted → ~91.7% remaining.
        assert!((percent - 91.6).abs() < 0.2, "got {percent}");
    }

    #[test]
    fn providers_without_capacities_report_tokens_only() {
        let now = 1_700_000_000;
        let samples = vec![UsageSample::new(now - 60, TokenUsage::new(1_000, 0, 0, 0))];
        let windows = model::UsageComputation::windows(&samples, "Claude", &HashMap::new(), now);
        assert!(windows.iter().all(|w| w.percent_remaining.is_none()));
    }

    /// The window id is "provider-label" so history can be keyed per window.
    #[test]
    fn window_ids_are_provider_scoped() {
        let now = 1_700_000_000;
        let windows = model::UsageComputation::windows(&[], "Codex", &HashMap::new(), now);
        assert_eq!(windows[0].id, "Codex-Rolling");
        assert_eq!(windows[1].id, "Codex-Weekly");
        assert_eq!(windows[2].id, "Codex-Monthly");
    }

    #[test]
    fn usage_window_defaults_to_no_id_until_set() {
        let window = UsageWindow::new("Rolling", 10, Some(50.0), None);
        assert_eq!(window.label, "Rolling");
        assert_eq!(window.tokens_used, 10);
    }
}
