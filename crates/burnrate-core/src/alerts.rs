//! Alert rules and the pure evaluators behind milestone, burn-rate and daily
//! cost notifications.
//!
//! Ported 1:1 from `Sources/BurnRateCore/Alerts.swift` and `AlertDefaults.swift`.
//! Parity tests: `MilestoneEvaluatorTests`, `BurnRateEvaluatorTests`,
//! `MilestoneNotifierTests`.

use serde::{Deserialize, Serialize};

/// One notification rule: notify each time a provider window's remaining %
/// drops past another `step` increment (e.g. step 10 fires at 90, 80, 70…
/// remaining). One rule per provider+window.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Milestone {
    pub provider: String,
    pub window_label: String,
    /// Increment in percentage points (e.g. 10 = notify at 90/80/70… remaining).
    pub step: f64,
}

/// Wire shape, including the legacy fixed-threshold field the Swift build
/// wrote before rules became increments.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MilestoneWire {
    provider: String,
    window_label: String,
    #[serde(default)]
    step: Option<f64>,
    /// Legacy: a single fixed threshold, superseded by `step`.
    #[serde(default)]
    percent_remaining: Option<f64>,
}

impl<'de> Deserialize<'de> for Milestone {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = MilestoneWire::deserialize(deserializer)?;
        let step = match wire.step {
            Some(step) => step,
            None => match wire.percent_remaining {
                // Legacy fixed-threshold rule: keep its level covered by
                // reusing the threshold as the increment.
                Some(legacy) => legacy.round().clamp(1.0, 50.0),
                None => 20.0,
            },
        };
        Ok(Milestone { provider: wire.provider, window_label: wire.window_label, step })
    }
}

impl Milestone {
    pub fn new(provider: &str, window_label: &str, step: f64) -> Self {
        Self {
            provider: provider.to_string(),
            window_label: window_label.to_string(),
            step,
        }
    }

    /// Identity excludes the step so one window can never hold two rules.
    pub fn key(&self) -> String {
        format!("{}|{}", self.provider, self.window_label)
    }

    /// Collapse duplicates to one rule per provider+window, keeping the
    /// smallest increment (covers the most levels).
    pub fn coalesce(milestones: &[Milestone]) -> Vec<Milestone> {
        let mut best: std::collections::HashMap<String, Milestone> =
            std::collections::HashMap::new();
        for milestone in milestones {
            match best.get(&milestone.key()) {
                Some(existing) if existing.step <= milestone.step => continue,
                _ => {
                    best.insert(milestone.key(), milestone.clone());
                }
            }
        }
        // Deterministic order so the settings UI and the tests agree.
        let mut out: Vec<(String, Milestone)> = best.into_iter().collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out.into_iter().map(|(_, milestone)| milestone).collect()
    }
}

/// One burn-rate alert: notify when a provider window's remaining % drops by at
/// least `percent_drop` within a trailing `minutes` window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BurnAlert {
    pub provider: String,
    pub window_label: String,
    pub percent_drop: f64,
    pub minutes: i64,
}

impl BurnAlert {
    pub fn new(provider: &str, window_label: &str, percent_drop: f64, minutes: i64) -> Self {
        Self {
            provider: provider.to_string(),
            window_label: window_label.to_string(),
            percent_drop,
            minutes,
        }
    }

    pub fn key(&self) -> String {
        format!(
            "{}|{}|{}|{}",
            self.provider, self.window_label, self.percent_drop, self.minutes
        )
    }
}

/// Alert when one provider's daily local-log spend (USD) exceeds the limit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CostAlert {
    pub provider: String,
    pub daily_limit_usd: f64,
}

impl CostAlert {
    pub fn new(provider: &str, daily_limit_usd: f64) -> Self {
        Self {
            provider: provider.to_string(),
            daily_limit_usd,
        }
    }
}

/// Shipped default alert rules, shared by every platform's settings store.
pub struct AlertDefaults;

impl AlertDefaults {
    pub fn milestones() -> Vec<Milestone> {
        vec![
            Milestone::new("Claude", "Rolling", 20.0),
            Milestone::new("Claude", "Weekly", 20.0),
            Milestone::new("Codex", "Rolling", 20.0),
        ]
    }

    pub fn burn_alerts() -> Vec<BurnAlert> {
        vec![BurnAlert::new("Claude", "Rolling", 15.0, 30)]
    }
}

/// Pure increment logic for milestone crossings.
pub struct MilestoneEvaluator;

impl MilestoneEvaluator {
    /// Grid levels below 100 for an increment, descending (20 → 80, 60, 40, 20).
    pub fn thresholds(step: f64) -> Vec<f64> {
        if !(step > 0.0 && step < 100.0) {
            return Vec::new();
        }
        let mut levels = Vec::new();
        let mut k = 1.0;
        while k * step < 100.0 {
            levels.push((k * step).round());
            k += 1.0;
        }
        // Descending, as the Swift original sorts: highest level first.
        levels.sort_by(|a, b| a.partial_cmp(b).expect("grid levels are finite"));
        levels.reverse();
        levels
    }

    /// Highest grid level crossed downward from previous to current, else
    /// `None`. A `None` previous (first observation) never fires.
    pub fn crossed_threshold(
        previous_remaining: Option<f64>,
        current_remaining: f64,
        step: f64,
    ) -> Option<f64> {
        let previous = previous_remaining?;
        Self::thresholds(step)
            .into_iter()
            .find(|level| previous > *level && current_remaining <= *level)
    }
}

/// One reading of a window's remaining %.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reading {
    /// Seconds since the Unix epoch.
    pub date: i64,
    pub remaining: f64,
}

/// What a burn-rate detection found.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BurnDetection {
    pub drop: f64,
    pub baseline: f64,
    pub current: f64,
}

/// Pure burn-rate detection over a timestamped remaining-% history.
pub struct BurnRateEvaluator;

impl BurnRateEvaluator {
    /// Returns the detection when remaining fell by at least the alert's
    /// `percent_drop` over its trailing window, else `None`.
    ///
    /// `history` must hold the window's readings in chronological order (oldest
    /// first); the last entry is the current one. A baseline is only used if it
    /// is at least `minutes` old, so a freshly started app can't fire on a
    /// partial window. Times are seconds since the Unix epoch.
    pub fn detect(
        history: &[Reading],
        alert: &BurnAlert,
        now: i64,
        poll_interval: i64,
    ) -> Option<BurnDetection> {
        // Baseline: oldest reading within the trailing window (+ one poll of
        // slack, since polls land on 5-minute boundaries).
        let window_start = now - alert.minutes * 60 - poll_interval;
        let baseline = history
            .iter()
            .find(|reading| reading.date >= window_start)?;
        // Require the window to actually span `minutes`.
        if now - baseline.date < alert.minutes * 60 - poll_interval / 2 {
            return None;
        }
        // History is appended chronologically; last entry is the current reading.
        let latest = history.last()?;
        if latest.date < baseline.date {
            return None;
        }
        let drop = baseline.remaining - latest.remaining;
        if drop < alert.percent_drop {
            return None;
        }
        Some(BurnDetection {
            drop,
            baseline: baseline.remaining,
            current: latest.remaining,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000;
    const MINUTE: i64 = 60;

    /// `gridForStep10` / `gridForStep20` — the descending level grid.
    #[test]
    fn grid_for_step() {
        assert_eq!(
            MilestoneEvaluator::thresholds(10.0),
            vec![90.0, 80.0, 70.0, 60.0, 50.0, 40.0, 30.0, 20.0, 10.0]
        );
        assert_eq!(
            MilestoneEvaluator::thresholds(20.0),
            vec![80.0, 60.0, 40.0, 20.0]
        );
        assert_eq!(MilestoneEvaluator::thresholds(50.0), vec![50.0]);
        // Out-of-range steps produce no grid.
        assert!(MilestoneEvaluator::thresholds(0.0).is_empty());
        assert!(MilestoneEvaluator::thresholds(100.0).is_empty());
    }

    /// `crossesOnExactLanding` — landing exactly on a level counts.
    #[test]
    fn crosses_on_exact_landing() {
        assert_eq!(
            MilestoneEvaluator::crossed_threshold(Some(81.0), 80.0, 10.0),
            Some(80.0)
        );
    }

    /// `crossesDownPastLevel` — a big drop reports the highest level crossed.
    #[test]
    fn crosses_down_past_level() {
        assert_eq!(
            MilestoneEvaluator::crossed_threshold(Some(95.0), 10.0, 10.0),
            Some(90.0)
        );
    }

    /// `noCrossWhenStillAbove` — staying above every level never fires.
    #[test]
    fn no_cross_when_still_above() {
        assert_eq!(
            MilestoneEvaluator::crossed_threshold(Some(95.0), 91.0, 10.0),
            None
        );
    }

    /// `noCrossWhenRecoveringAboveLevel` — going up is not a crossing.
    #[test]
    fn no_cross_when_recovering_above_level() {
        assert_eq!(
            MilestoneEvaluator::crossed_threshold(Some(50.0), 80.0, 10.0),
            None
        );
    }

    /// `noFireOnFirstObservation` — no previous reading means no crossing.
    #[test]
    fn no_fire_on_first_observation() {
        assert_eq!(MilestoneEvaluator::crossed_threshold(None, 5.0, 10.0), None);
    }

    /// `duplicatesCollapseToOneRuleKeepingSmallestStep`.
    #[test]
    fn duplicates_collapse_to_one_rule_keeping_smallest_step() {
        let merged = Milestone::coalesce(&[
            Milestone::new("Claude", "Rolling", 25.0),
            Milestone::new("Claude", "Rolling", 10.0),
            Milestone::new("Claude", "Weekly", 20.0),
        ]);
        assert_eq!(merged.len(), 2);
        let rolling = merged.iter().find(|m| m.window_label == "Rolling").unwrap();
        assert_eq!(rolling.step, 10.0);
    }

    /// `burns_fires_on_fast_drop` — a 20-point drop in 30 minutes.
    #[test]
    fn fires_on_fast_drop() {
        let alert = BurnAlert::new("Claude", "Rolling", 15.0, 30);
        let history = vec![
            Reading {
                date: NOW - 30 * MINUTE,
                remaining: 80.0,
            },
            Reading {
                date: NOW,
                remaining: 55.0,
            },
        ];
        let found = BurnRateEvaluator::detect(&history, &alert, NOW, 300).unwrap();
        assert_eq!(found.drop, 25.0);
        assert_eq!(found.baseline, 80.0);
        assert_eq!(found.current, 55.0);
    }

    /// `noFireOnSlowBurn` — the same drop spread over too long never fires.
    #[test]
    fn no_fire_on_slow_burn() {
        let alert = BurnAlert::new("Claude", "Rolling", 15.0, 30);
        let history = vec![
            Reading {
                date: NOW - 90 * MINUTE,
                remaining: 80.0,
            },
            Reading {
                date: NOW,
                remaining: 55.0,
            },
        ];
        // The only reading in the trailing window is the current one, so there
        // is no baseline old enough to judge.
        assert!(BurnRateEvaluator::detect(&history, &alert, NOW, 300).is_none());
    }

    /// `noFireWithTooLittleHistory` — a fresh app has no baseline.
    #[test]
    fn no_fire_with_too_little_history() {
        let alert = BurnAlert::new("Claude", "Rolling", 15.0, 30);
        let history = vec![Reading {
            date: NOW,
            remaining: 40.0,
        }];
        assert!(BurnRateEvaluator::detect(&history, &alert, NOW, 300).is_none());
        assert!(BurnRateEvaluator::detect(&[], &alert, NOW, 300).is_none());
    }

    /// `noFireWhenRemainingIncreases` — usage going down is not a burn.
    #[test]
    fn no_fire_when_remaining_increases() {
        let alert = BurnAlert::new("Claude", "Rolling", 15.0, 30);
        let history = vec![
            Reading {
                date: NOW - 30 * MINUTE,
                remaining: 40.0,
            },
            Reading {
                date: NOW,
                remaining: 60.0,
            },
        ];
        assert!(BurnRateEvaluator::detect(&history, &alert, NOW, 300).is_none());
    }

    /// `ignoresHistoryOlderThanWindow` — readings before the window are skipped.
    #[test]
    fn ignores_history_older_than_window() {
        let alert = BurnAlert::new("Claude", "Rolling", 15.0, 30);
        let history = vec![
            // Outside the window: must not become the baseline.
            Reading {
                date: NOW - 120 * MINUTE,
                remaining: 99.0,
            },
            Reading {
                date: NOW - 30 * MINUTE,
                remaining: 80.0,
            },
            Reading {
                date: NOW,
                remaining: 60.0,
            },
        ];
        let found = BurnRateEvaluator::detect(&history, &alert, NOW, 300).unwrap();
        assert_eq!(
            found.baseline, 80.0,
            "baseline is the oldest in-window reading"
        );
    }

    /// `emptyHistoryNeverFires`.
    #[test]
    fn empty_history_never_fires() {
        let alert = BurnAlert::new("Claude", "Rolling", 15.0, 30);
        assert!(BurnRateEvaluator::detect(&[], &alert, NOW, 300).is_none());
    }
}
