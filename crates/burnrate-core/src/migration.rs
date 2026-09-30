//! One-time import of the Swift app's persisted history.
//!
//! The Swift build kept two histories in `UserDefaults`, under the bundle id
//! `com.burnrate.desktop`:
//!
//!   - `remainingHistory` — the trend chart's sample list, seven days of
//!     five-minute polls, ~6,700 records in practice;
//!   - `modelUsageHistory` — thirty days of per-model daily buckets.
//!
//! Both are JSON, and both encode `Date` the way `JSONEncoder` does by default:
//! **seconds since 2001-01-01**, not the Unix epoch.
//!
//! That offset is the whole difficulty. Read without it, every sample lands 31
//! years in the past, the retention filter drops the lot, and the migration
//! reports success while importing nothing. It is worth being loud about because
//! the failure is silent.
//!
//! Parsing goes through the shims below rather than the real structs. Swift
//! writes `date` as a *fractional* number while `RemainingSample.date` is an
//! integer, and `ModelUsageEntry` does not implement `Deserialize` at all. The
//! shims also document the wire format, which is the part that has to match
//! someone else's encoder.

use serde::Deserialize;

use crate::charts::RemainingSample;
use crate::model::TokenUsage;
use crate::usage::{DailyModelUsage, ModelUsageAggregator, ModelUsageEntry};

/// Seconds between the Unix epoch and Swift's reference date, 2001-01-01.
pub const APPLE_REFERENCE_OFFSET: i64 = 978_307_200;

/// Seven days, matching `ModelUsageViewModel.remainingRetention`.
pub const REMAINING_RETENTION_SECONDS: i64 = 7 * 86_400;
/// Thirty days, matching `ModelUsageAggregator.daily(days: 30)`.
pub const MODEL_HISTORY_DAYS: i64 = 30;

#[derive(Debug, thiserror::Error)]
pub enum MigrationError {
    #[error("the Swift history is not valid JSON: {0}")]
    Json(#[from] serde_json::Error),
}

/// One `remainingHistory` record as Swift writes it.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftRemainingSample {
    provider: String,
    label: String,
    /// Seconds since 2001-01-01. Fractional — Swift's `Date` keeps sub-second
    /// precision, and it is stored as `Double`.
    date: f64,
    remaining: f64,
}

/// One `modelUsageHistory` record as Swift writes it.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftDailyModelUsage {
    /// Seconds since 2001-01-01, at local start of day.
    day: f64,
    entries: Vec<SwiftModelUsageEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftModelUsageEntry {
    provider: String,
    model: String,
    tokens: TokenUsage,
    cost: f64,
    requests: i64,
    /// Present in the real payload; defaulted because it is a later addition and
    /// an older snapshot would not have it.
    #[serde(default)]
    source_tag: Option<String>,
}

/// Provider names that changed between Swift versions.
///
/// The Swift build names its OpenCode quota provider `"OpenCode"` in
/// `OpenCodeGoUsageAPI` and `"OpenCode Go"` in the log source — two names for one
/// product, in the reference app itself. This app uses `"OpenCode Go"`
/// throughout. Left alone, the imported history would draw a second, parallel
/// trend line for a provider already on the chart, and list a second breakdown
/// row for a model already in the table.
fn normalise_provider(name: &str) -> &str {
    match name {
        "OpenCode" => "OpenCode Go",
        other => other,
    }
}

/// Converts a Swift reference-date value to a Unix timestamp.
pub fn unix_from_apple_reference(apple: f64) -> i64 {
    (apple + APPLE_REFERENCE_OFFSET as f64) as i64
}

/// Reads a Swift `remainingHistory` blob into trend samples.
///
/// Samples dated in the future are dropped: a clock that ran fast would
/// otherwise place points beyond the chart's X domain, where they stretch the
/// axis and leave the real line bunched at one end.
pub fn import_remaining_history(
    json: &[u8],
    now: i64,
) -> Result<Vec<RemainingSample>, MigrationError> {
    let raw: Vec<SwiftRemainingSample> = serde_json::from_slice(json)?;
    let cutoff = now - REMAINING_RETENTION_SECONDS;
    let mut samples: Vec<RemainingSample> = raw
        .into_iter()
        .map(|sample| RemainingSample {
            provider: normalise_provider(&sample.provider).to_string(),
            label: sample.label,
            date: unix_from_apple_reference(sample.date),
            remaining: sample.remaining,
        })
        .filter(|sample| sample.date >= cutoff && sample.date <= now)
        .collect();
    samples.sort_by_key(|sample| sample.date);
    samples.dedup_by(|a, b| a.provider == b.provider && a.label == b.label && a.date == b.date);
    Ok(samples)
}

/// Reads a Swift `modelUsageHistory` blob into daily buckets.
///
/// Buckets older than the retention window are dropped, and synthetic models are
/// filtered out exactly as `ModelUsageAggregator` filters them from a live parse
/// — a persisted snapshot must not be the one place `<synthetic>` gets through.
pub fn import_model_history(json: &[u8], now: i64) -> Result<Vec<DailyModelUsage>, MigrationError> {
    let raw: Vec<SwiftDailyModelUsage> = serde_json::from_slice(json)?;
    let cutoff = crate::poller::local_start_of_day(now - (MODEL_HISTORY_DAYS - 1) * 86_400);
    let mut days: Vec<DailyModelUsage> = raw
        .into_iter()
        .map(|day| DailyModelUsage {
            day: unix_from_apple_reference(day.day),
            entries: day
                .entries
                .into_iter()
                .filter(|entry| ModelUsageAggregator::is_displayable(Some(&entry.model)))
                .map(|entry| ModelUsageEntry {
                    provider: normalise_provider(&entry.provider).to_string(),
                    model: entry.model,
                    tokens: entry.tokens,
                    cost: entry.cost,
                    requests: entry.requests,
                    source_tag: entry.source_tag,
                })
                .collect(),
        })
        .filter(|day| day.day >= cutoff && !day.entries.is_empty())
        .collect();
    days.sort_by_key(|day| day.day);
    // Two records for one day would double-count it in every total. Keyed by UTC
    // day, as the merge is, because Swift's day boundaries are not ours.
    days.dedup_by_key(|day| day.day.div_euclid(86_400));
    Ok(days)
}

/// Merges freshly parsed daily buckets into the persisted history.
///
/// A day present in both keeps the freshly parsed version, because the live
/// parse is by definition current; a day only the persisted copy knows about is
/// kept, which is the whole reason for persisting. That case is real: the Claude
/// parser skips log files untouched for 31 days, so a day's logs can be rotated
/// away while the history still needs to show it.
pub fn merge_daily(
    persisted: &[DailyModelUsage],
    fresh: &[DailyModelUsage],
) -> Vec<DailyModelUsage> {
    // Days are matched by **UTC calendar day**, not by their epoch. Two sources
    // can disagree about where a local day starts — the Swift app bucketed with
    // a fixed +12 while this one follows the offset in effect, so after New
    // Zealand's daylight-saving change the same date arrived as two epochs an
    // hour apart. Matched by epoch that is two days, and every total for those
    // dates is counted twice. A local day is always within 14 hours of its UTC
    // day, so the UTC day is the stable key.
    let key = |day: &DailyModelUsage| day.day.div_euclid(86_400);
    let mut merged: Vec<DailyModelUsage> = fresh.to_vec();
    for day in persisted {
        if !merged.iter().any(|candidate| key(candidate) == key(day)) {
            merged.push(day.clone());
        }
    }
    merged.sort_by_key(|day| day.day);
    merged
}

/// Drops days outside the retention window.
///
/// The window runs back from today's local midnight, and is compared on the same
/// UTC-day key as the merge, so a day is never kept or dropped on the strength of
/// an hour of boundary disagreement.
pub fn prune_daily(days: Vec<DailyModelUsage>, now: i64) -> Vec<DailyModelUsage> {
    let cutoff = crate::poller::local_start_of_day(now - (MODEL_HISTORY_DAYS - 1) * 86_400);
    let cutoff_key = cutoff.div_euclid(86_400);
    days.into_iter()
        .filter(|day| day.day.div_euclid(86_400) >= cutoff_key)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_790_700_000;

    fn apple(unix: i64) -> f64 {
        (unix - APPLE_REFERENCE_OFFSET) as f64
    }

    /// The bug this module exists to avoid: reading Swift's dates as Unix
    /// timestamps drops everything, silently.
    #[test]
    fn swift_dates_are_reference_dates_not_unix_epochs() {
        // A sample taken now, as Swift writes it.
        assert_eq!(unix_from_apple_reference(apple(NOW)), NOW);
        // Read as Unix it would be 31 years early, i.e. 1995.
        assert!(apple(NOW) < 900_000_000.0);

        let json = format!(
            r#"[{{"provider":"Claude","label":"Rolling","date":{},"remaining":84.0}}]"#,
            apple(NOW)
        );
        let samples = import_remaining_history(json.as_bytes(), NOW).expect("parses");
        assert_eq!(samples.len(), 1, "the sample survives retention");
        assert_eq!(samples[0].date, NOW);
        assert_eq!(samples[0].remaining, 84.0);

        // The same JSON read *without* the offset keeps nothing at all, which is
        // the silent failure being guarded against.
        let naive = format!(
            r#"[{{"provider":"Claude","label":"Rolling","date":{},"remaining":84.0}}]"#,
            NOW
        );
        assert!(import_remaining_history(naive.as_bytes(), NOW)
            .expect("parses")
            .is_empty());
    }

    #[test]
    fn fractional_dates_round_to_whole_seconds() {
        // Swift stores `Date` as a Double, so the JSON has decimals.
        let json = format!(
            r#"[{{"provider":"Claude","label":"Rolling","date":{}.657534,"remaining":94}}]"#,
            apple(NOW)
        );
        let samples = import_remaining_history(json.as_bytes(), NOW).expect("parses");
        assert_eq!(samples[0].date, NOW, "truncated, not rejected");
    }

    #[test]
    fn remaining_import_prunes_and_sorts_and_dedupes() {
        let json = format!(
            r#"[
                {{"provider":"Claude","label":"Rolling","date":{},"remaining":10}},
                {{"provider":"Claude","label":"Rolling","date":{},"remaining":20}},
                {{"provider":"Claude","label":"Rolling","date":{},"remaining":30}},
                {{"provider":"Claude","label":"Rolling","date":{},"remaining":40}}
            ]"#,
            apple(NOW - 20 * 86_400), // past retention
            apple(NOW - 60),
            apple(NOW - 60),     // duplicate
            apple(NOW + 86_400), // in the future
        );
        let samples = import_remaining_history(json.as_bytes(), NOW).expect("parses");
        assert_eq!(samples.len(), 1, "got {samples:?}");
        assert_eq!(samples[0].remaining, 20.0);
    }

    #[test]
    fn model_import_converts_days_and_drops_synthetic_models() {
        let json = format!(
            r#"[{{"day":{},"entries":[
                {{"provider":"Claude","model":"claude-opus-5",
                  "tokens":{{"input":100,"output":20,"cacheRead":900,"cacheWrite":5,"reasoning":0}},
                  "cost":1.5,"requests":7,"sourceTag":null}},
                {{"provider":"Claude","model":"<synthetic>",
                  "tokens":{{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
                  "cost":0,"requests":1}}
            ]}}]"#,
            apple(NOW - 3_600)
        );
        let days = import_model_history(json.as_bytes(), NOW).expect("parses");
        assert_eq!(days.len(), 1);
        assert_eq!(
            days[0].entries.len(),
            1,
            "the synthetic turn is not a model"
        );
        let entry = &days[0].entries[0];
        assert_eq!(entry.model, "claude-opus-5");
        assert_eq!(entry.tokens.cache_read, 900);
        assert_eq!(entry.tokens.input, 100);
        assert_eq!(entry.requests, 7);
    }

    #[test]
    fn model_import_drops_empty_and_stale_days() {
        let json = format!(
            r#"[
                {{"day":{},"entries":[]}},
                {{"day":{},"entries":[{{"provider":"Claude","model":"m",
                  "tokens":{{"input":1,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
                  "cost":0,"requests":1}}]}}
            ]"#,
            apple(NOW - 3_600),       // no entries
            apple(NOW - 90 * 86_400), // outside 30 days
        );
        assert!(import_model_history(json.as_bytes(), NOW)
            .expect("parses")
            .is_empty());
    }

    /// Fresh data wins for a day, and a day only the persisted copy has survives.
    #[test]
    fn merge_keeps_rotated_days_and_prefers_fresh_ones() {
        let entry = |model: &str, requests: i64| ModelUsageEntry {
            provider: "Claude".to_string(),
            model: model.to_string(),
            tokens: TokenUsage::new(10, 5, 0, 0),
            cost: 0.0,
            requests,
            source_tag: None,
        };
        let persisted = vec![
            // Only the persisted copy knows this day; its logs have rotated away.
            DailyModelUsage {
                day: NOW - 20 * 86_400,
                entries: vec![entry("old", 1)],
            },
            // Both have it, with different content.
            DailyModelUsage {
                day: NOW - 86_400,
                entries: vec![entry("stale", 1)],
            },
        ];
        let fresh = vec![DailyModelUsage {
            day: NOW - 86_400,
            entries: vec![entry("current", 9)],
        }];

        let merged = merge_daily(&persisted, &fresh);
        assert_eq!(merged.len(), 2, "one day per calendar day");
        assert_eq!(merged[0].day, NOW - 20 * 86_400, "oldest first");
        assert_eq!(
            merged[0].entries[0].model, "old",
            "the rotated day survives"
        );
        assert_eq!(
            merged[1].entries[0].model, "current",
            "fresh replaces stale"
        );
        assert_eq!(merged[1].entries[0].requests, 9);
    }

    #[test]
    fn merge_of_nothing_is_empty_and_does_not_duplicate() {
        assert!(merge_daily(&[], &[]).is_empty());
        let day = DailyModelUsage {
            day: NOW,
            entries: vec![ModelUsageEntry {
                provider: "Claude".to_string(),
                model: "m".to_string(),
                tokens: TokenUsage::new(1, 0, 0, 0),
                cost: 0.0,
                requests: 1,
                source_tag: None,
            }],
        };
        // The same day on both sides must appear once, or every total doubles.
        let same = std::slice::from_ref(&day);
        assert_eq!(merge_daily(same, same).len(), 1);
    }

    /// `"OpenCode"` and `"OpenCode Go"` are one provider in the Swift app, under
    /// two names. Importing both would put a duplicate line on the chart.
    #[test]
    fn the_two_opencode_names_become_one() {
        let json = format!(
            r#"[{{"provider":"OpenCode","label":"Rolling","date":{},"remaining":99.0}},
                {{"provider":"OpenCode Go","label":"Rolling","date":{},"remaining":98.0}}]"#,
            apple(NOW - 120),
            apple(NOW - 60),
        );
        let samples = import_remaining_history(json.as_bytes(), NOW).expect("parses");
        assert_eq!(samples.len(), 2);
        assert!(
            samples
                .iter()
                .all(|sample| sample.provider == "OpenCode Go"),
            "{samples:?}"
        );

        // And in the daily history, where it would be a duplicate table row.
        let json = format!(
            r#"[{{"day":{},"entries":[{{"provider":"OpenCode","model":"deepseek-v4-pro",
                "tokens":{{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"reasoning":0}},
                "cost":0,"requests":1}}]}}]"#,
            apple(NOW - 3_600)
        );
        let days = import_model_history(json.as_bytes(), NOW).expect("parses");
        assert_eq!(days[0].entries[0].provider, "OpenCode Go");
    }

    /// The duplicate that actually happened: Swift bucketed with a fixed +12,
    /// this app follows the offset in effect, and after the daylight-saving
    /// change the same date arrived as two epochs an hour apart.
    #[test]
    fn merge_treats_an_hour_apart_as_the_same_day() {
        let entry = |requests: i64| ModelUsageEntry {
            provider: "Claude".to_string(),
            model: "claude-opus-5".to_string(),
            tokens: TokenUsage::new(100, 10, 0, 0),
            cost: 0.0,
            requests,
            source_tag: None,
        };
        // Same local date, two conventions: midnight at +12 and at +13.
        let utc_midnight = 1_790_611_200_i64; // a whole UTC day
        let swift = DailyModelUsage {
            day: utc_midnight + 43_200,
            entries: vec![entry(1)],
        };
        let ours = DailyModelUsage {
            day: utc_midnight + 46_800,
            entries: vec![entry(2)],
        };

        let merged = merge_daily(&[swift], &[ours]);
        assert_eq!(merged.len(), 1, "one local day, not two: {merged:?}");
        assert_eq!(merged[0].entries[0].requests, 2, "fresh wins");
    }

    #[test]
    fn prune_drops_days_past_retention() {
        let day = |offset: i64| DailyModelUsage {
            day: crate::usage::start_of_day(NOW - offset * 86_400, 0),
            entries: vec![],
        };
        let pruned = prune_daily(vec![day(40), day(10), day(1)], NOW);
        assert_eq!(pruned.len(), 2, "40 days old is out");
        assert_eq!(
            pruned[0].day,
            crate::usage::start_of_day(NOW - 10 * 86_400, 0)
        );
    }
}
