//! Chart domains, ticks and lookups for the dashboard.
//!
//! Ported 1:1 from `Sources/BurnRateCore/ChartData.swift`. This module is what
//! the UI turns into pixels and nothing more: the Swift build drew its charts
//! with Swift Charts, which we do not have, so the maths lives here and the
//! frontend only lays out and strokes. Getting these rules right is the whole
//! job — the first port drew a 0–100 line chart with five gridlines and looked
//! nothing like the Swift app.
//!
//! The rules, all of which the first port got wrong:
//!   - the X domain **scales down to the data**, so an hour of history in a
//!     7-day range plots that hour instead of leaving 6.9 empty days;
//!   - tick *style* follows the **visible span**, not the selected range, so a
//!     chart scaled to a few hours gets hourly marks;
//!   - the Y domain is **padded** by 15% (min 5 points) so a nearly-flat line
//!     is not flattened against the frame, and clamped to 0…100;
//!   - Y ticks are at multiples of 10, falling back to 5 when that would leave
//!     fewer than three lines.
//!
//! Still to port: the daily/ranking chart windows (see `PARITY.md`).

use crate::formatting::TokenFormat;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Trailing time windows the dashboard can show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ChartRange {
    /// 24h
    Today,
    /// 7d
    Week,
    /// 30d
    Month,
}

impl ChartRange {
    /// The label the Swift build shows, and the order the picker uses.
    pub fn label(self) -> &'static str {
        match self {
            ChartRange::Today => "24h",
            ChartRange::Week => "7d",
            ChartRange::Month => "30d",
        }
    }

    pub const ALL: [ChartRange; 3] = [ChartRange::Today, ChartRange::Week, ChartRange::Month];

    pub fn from_label(label: &str) -> Option<ChartRange> {
        match label {
            "24h" | "today" | "day" => Some(ChartRange::Today),
            "7d" | "week" => Some(ChartRange::Week),
            "30d" | "month" => Some(ChartRange::Month),
            _ => None,
        }
    }

    /// Trailing window behind "now" — ranges are rolling, not calendar.
    pub fn span_seconds(self) -> i64 {
        match self {
            ChartRange::Today => 24 * 3600,
            ChartRange::Week => 7 * 86_400,
            ChartRange::Month => 30 * 86_400,
        }
    }
}

/// One point of vendor-reported remaining-% history.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemainingSample {
    pub provider: String,
    pub label: String,
    /// Seconds since the Unix epoch.
    pub date: i64,
    pub remaining: f64,
}

/// One line on the remaining-over-time chart. A provider can contribute several
/// series (Claude Weekly *and* Claude Fable); scoped weeklies draw dashed and
/// faded.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrendSeries {
    /// Stable identity, "provider|label".
    pub key: String,
    /// Display name; scoped series are "Provider Window".
    pub name: String,
    pub provider: String,
    pub scoped: bool,
    /// (epoch seconds, percent remaining), chronological.
    pub samples: Vec<(i64, f64)>,
}

pub struct TrendChartData;

impl TrendChartData {
    /// Model-scoped quotas (Claude's Fable) come from `weekly_scoped`, so they
    /// chart on the Weekly graph. Anything outside the three known windows
    /// belongs to Weekly too.
    pub fn canonical_trend_label(label: &str) -> &str {
        match label {
            "Rolling" | "Weekly" | "Monthly" => label,
            _ => "Weekly",
        }
    }

    /// Trailing start of the visible span for the range filter.
    pub fn trend_cutoff(range: ChartRange, now: i64) -> i64 {
        now - range.span_seconds()
    }

    /// The window labels the picker offers, in canonical order.
    ///
    /// A port of `ModelsView.trendLabels(providerFilter:range:)`, which builds
    /// the list from a `preferred` sequence and filters that — the order is
    /// Rolling, Weekly, Monthly, *not* alphabetical. Sorting the labels gave
    /// Monthly, Rolling, Weekly, which put the default selection in the middle
    /// of the group and read as a mistake.
    ///
    /// Also scoped the way Swift scopes it: by the provider filter and the
    /// range cutoff. Offering a window the visible data cannot fill is how the
    /// picker ends up with an option that renders as an empty graph.
    pub fn trend_labels(
        samples: &[RemainingSample],
        provider_filter: Option<&str>,
        cutoff: i64,
    ) -> Vec<String> {
        const PREFERRED: [&str; 3] = ["Rolling", "Weekly", "Monthly"];
        let present: BTreeSet<&str> = samples
            .iter()
            .filter(|sample| {
                if sample.date < cutoff {
                    return false;
                }
                match provider_filter {
                    Some(filter) => sample.provider == filter,
                    None => true,
                }
            })
            .map(|sample| Self::canonical_trend_label(&sample.label))
            .collect();
        if present.is_empty() {
            return PREFERRED.iter().map(|label| label.to_string()).collect();
        }
        let mut labels: Vec<String> = PREFERRED
            .iter()
            .filter(|label| present.contains(*label))
            .map(|label| label.to_string())
            .collect();
        // Any label outside the preferred three, sorted — unreachable while
        // `canonical_trend_label` folds unknowns into Weekly, kept so a new
        // window type cannot silently vanish from the picker.
        let mut extras: Vec<String> = present
            .iter()
            .filter(|label| !PREFERRED.contains(label))
            .map(|label| label.to_string())
            .collect();
        extras.sort();
        extras.dedup();
        labels.extend(extras);
        labels
    }

    /// Per-provider series for a window over the visible range, from the flat
    /// sample list the poller accumulates.
    pub fn build_trend_series(
        samples: &[RemainingSample],
        label: &str,
        provider_filter: Option<&str>,
        cutoff: i64,
    ) -> Vec<TrendSeries> {
        use std::collections::BTreeMap;
        let mut grouped: BTreeMap<String, Vec<&RemainingSample>> = BTreeMap::new();
        for sample in samples {
            if Self::canonical_trend_label(&sample.label) != label {
                continue;
            }
            if let Some(filter) = provider_filter {
                if sample.provider != filter {
                    continue;
                }
            }
            if sample.date < cutoff {
                continue;
            }
            grouped
                .entry(format!("{}|{}", sample.provider, sample.label))
                .or_default()
                .push(sample);
        }

        grouped
            .into_iter()
            .map(|(key, mut points)| {
                points.sort_by_key(|sample| sample.date);
                let first = points[0];
                let scoped = first.label != label;
                let name = if scoped {
                    format!("{} {}", first.provider, first.label)
                } else {
                    first.provider.clone()
                };
                TrendSeries {
                    key,
                    name,
                    provider: first.provider.clone(),
                    scoped,
                    samples: points
                        .iter()
                        .map(|sample| (sample.date, sample.remaining))
                        .collect(),
                }
            })
            .collect()
    }

    /// X-axis tick style follows the **visible** span, so a chart scaled down
    /// to a few hours gets hourly ticks even in a 7d range.
    pub fn trend_x_hourly(span: i64) -> bool {
        span < 3 * 86_400
    }

    /// Hourly gridline stride: 1h zoomed in, 6h for a couple of days, 12h beyond.
    pub fn trend_hour_stride(span: i64) -> i64 {
        if span < 6 * 3600 {
            1
        } else if span < 36 * 3600 {
            6
        } else {
            12
        }
    }

    /// The X domain. Scales down to the data actually available: with only an
    /// hour of history in a 7-day range, the plot spans that hour instead of
    /// leaving six empty days. Empty series fall back to the full range.
    pub fn trend_x_domain(series: &[TrendSeries], cutoff: i64, now: i64) -> (i64, i64) {
        let dates: Vec<i64> = series
            .iter()
            .flat_map(|line| line.samples.iter().map(|(date, _)| *date))
            .collect();
        let (Some(earliest), Some(latest)) =
            (dates.iter().min().copied(), dates.iter().max().copied())
        else {
            return (cutoff, now);
        };
        // A little lead-in so the first point is not glued to the edge.
        let span = (latest - earliest).max(60);
        let lower = cutoff.max(earliest - (span as f64 * 0.02) as i64);
        let upper = now.max(latest);
        // Below this the axis labels become unreadable.
        const MINIMUM_SPAN: i64 = 5 * 60;
        if upper - lower < MINIMUM_SPAN {
            return (lower, lower + MINIMUM_SPAN);
        }
        (lower, upper)
    }

    /// Midnight + noon ticks across the visible span (7d/30d ranges). Explicit
    /// dates rather than a stride, so ticks land exactly on 00:00/12:00 local.
    pub fn trend_tick_dates(cutoff: i64, now: i64, local_offset_seconds: i64) -> Vec<i64> {
        use crate::usage::start_of_day;
        let mut ticks = Vec::new();
        let mut day = start_of_day(cutoff, local_offset_seconds);
        let mut guard = 0;
        while day <= now && guard < 400 {
            guard += 1;
            if day >= cutoff {
                ticks.push(day);
            }
            let noon = day + 12 * 3600;
            if noon >= cutoff && noon <= now {
                ticks.push(noon);
            }
            day += 86_400;
        }
        ticks.sort_unstable();
        ticks
    }

    /// Midnight ticks read as the weekday, noon ticks as "12pm".
    pub fn trend_tick_label(date: i64, local_offset_seconds: i64) -> String {
        use crate::usage::start_of_day;
        let day_start = start_of_day(date, local_offset_seconds);
        if date - day_start == 12 * 3600 {
            return "12pm".to_string();
        }
        const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        let days = day_start.div_euclid(86_400);
        // 1970-01-01 was a Thursday (index 4).
        let index = (days + 4).rem_euclid(7) as usize;
        WEEKDAYS[index].to_string()
    }

    /// Nearest point per series to the hovered date, for a tooltip.
    pub fn nearest_rows(series: &[TrendSeries], at: i64) -> Vec<(&str, f64)> {
        series
            .iter()
            .filter_map(|line| {
                Self::nearest_point(&line.samples, at)
                    .map(|(_, remaining)| (line.name.as_str(), remaining))
            })
            .collect()
    }

    /// Nearest sample to `date` in a date-sorted series. Binary search: a
    /// tooltip tracks the pointer, and a linear scan per hover event over
    /// thousands of points is wasteful.
    pub fn nearest_point(samples: &[(i64, f64)], at: i64) -> Option<(i64, f64)> {
        if samples.is_empty() {
            return None;
        }
        let mut low = 0usize;
        let mut high = samples.len() - 1;
        while low < high {
            let mid = (low + high) / 2;
            if samples[mid].0 < at {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        let candidate = samples[low];
        if low == 0 {
            return Some(candidate);
        }
        let previous = samples[low - 1];
        let previous_gap = (previous.0 - at).abs();
        let candidate_gap = (candidate.0 - at).abs();
        Some(if previous_gap <= candidate_gap {
            previous
        } else {
            candidate
        })
    }

    /// Auto-scaled Y domain: spans the visible data plus padding so lines are
    /// not flattened when the range is narrow, clamped to 0…100 otherwise.
    /// Empty series give the full domain.
    pub fn remaining_domain(series: &[TrendSeries]) -> (f64, f64) {
        let values: Vec<f64> = series
            .iter()
            .flat_map(|line| line.samples.iter().map(|(_, percent)| *percent))
            .collect();
        if values.is_empty() {
            return (0.0, 100.0);
        }
        let low = values.iter().cloned().fold(f64::INFINITY, f64::min);
        let high = values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let pad = ((high - low) * 0.15).max(5.0);
        let lower = (low - pad).floor().max(0.0);
        let upper = (high + pad).ceil().min(100.0);
        if lower < upper {
            return (lower, upper);
        }
        // A flat line at 0% or 100% would give an empty domain.
        if lower == 0.0 {
            (0.0, 10.0)
        } else {
            (lower - 10.0, lower)
        }
    }

    /// Gridline values at multiples of 10 inside the domain, or multiples of 5
    /// when that would leave fewer than three lines.
    pub fn y_ticks(domain: (f64, f64)) -> Vec<f64> {
        for step in [10.0_f64, 5.0] {
            let first = (domain.0 / step).ceil() * step;
            let mut ticks = Vec::new();
            let mut value = first;
            while value <= domain.1 {
                // Snap away float drift from repeated addition.
                let snapped = (value / step).round() * step;
                if snapped >= domain.0 && snapped <= domain.1 {
                    ticks.push(snapped);
                }
                value += step;
            }
            if ticks.len() >= 3 {
                return ticks;
            }
        }
        vec![domain.0, domain.1]
    }

    /// Latest vendor-reported Rolling remaining % per provider, honoring the
    /// provider filter, worst first — that is the order the Swift card lists.
    pub fn latest_rolling(
        samples: &[RemainingSample],
        provider_filter: Option<&str>,
    ) -> Vec<(String, f64)> {
        use std::collections::HashMap;
        let mut latest: HashMap<&str, (i64, f64)> = HashMap::new();
        for sample in samples {
            if sample.label != "Rolling" {
                continue;
            }
            if let Some(filter) = provider_filter {
                if sample.provider != filter {
                    continue;
                }
            }
            let better = match latest.get(sample.provider.as_str()) {
                Some((date, _)) => sample.date > *date,
                None => true,
            };
            if better {
                latest.insert(sample.provider.as_str(), (sample.date, sample.remaining));
            }
        }
        let mut rows: Vec<(String, f64)> = latest
            .into_iter()
            .map(|(provider, (_, remaining))| (provider.to_string(), remaining))
            .collect();
        rows.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 86_400;
    const UTC: i64 = 0;
    const NOW: i64 = 1_800_000_000;

    fn series(name: &str, scoped: bool, points: &[(i64, f64)]) -> TrendSeries {
        TrendSeries {
            key: format!("{name}|Weekly"),
            name: name.to_string(),
            provider: name.split(' ').next().unwrap_or(name).to_string(),
            scoped,
            samples: points.to_vec(),
        }
    }

    fn samples(
        count: i64,
        provider: &str,
        label: &str,
        from: f64,
        step: f64,
    ) -> Vec<RemainingSample> {
        (0..count)
            .map(|index| RemainingSample {
                provider: provider.to_string(),
                label: label.to_string(),
                date: NOW - (count - 1 - index) * 300,
                remaining: from + step * index as f64,
            })
            .collect()
    }

    #[test]
    fn range_labels_and_spans() {
        assert_eq!(
            ChartRange::ALL.map(|range| range.label()),
            ["24h", "7d", "30d"]
        );
        assert_eq!(ChartRange::Today.span_seconds(), 24 * 3600);
        assert_eq!(ChartRange::Week.span_seconds(), 7 * DAY);
        assert_eq!(ChartRange::Month.span_seconds(), 30 * DAY);
        assert_eq!(ChartRange::from_label("7d"), Some(ChartRange::Week));
        assert_eq!(ChartRange::from_label("nope"), None);
    }

    /// `tickStyleFollowsVisibleSpanNotSelectedRange`.
    #[test]
    fn tick_style_follows_the_visible_span() {
        assert!(TrendChartData::trend_x_hourly(2 * 3600));
        assert!(TrendChartData::trend_x_hourly(2 * DAY));
        assert!(!TrendChartData::trend_x_hourly(4 * DAY));
        assert!(!TrendChartData::trend_x_hourly(7 * DAY));
    }

    /// `hourlyStrideWidensWithSpan`. The Swift switch is on half-open ranges
    /// (`case ..<(6 * 3600)`), so exactly 6h already strides by 6.
    #[test]
    fn hourly_stride_widens_with_span() {
        assert_eq!(TrendChartData::trend_hour_stride(3600), 1);
        assert_eq!(TrendChartData::trend_hour_stride(6 * 3600 - 1), 1);
        assert_eq!(TrendChartData::trend_hour_stride(6 * 3600), 6);
        assert_eq!(TrendChartData::trend_hour_stride(12 * 3600), 6);
        assert_eq!(TrendChartData::trend_hour_stride(36 * 3600 - 1), 6);
        assert_eq!(TrendChartData::trend_hour_stride(36 * 3600), 12);
        assert_eq!(TrendChartData::trend_hour_stride(3 * DAY), 12);
    }

    /// `xDomainShrinksToAvailableData` — the fix for a 7d range showing six
    /// empty days when there is an hour of history.
    #[test]
    fn x_domain_shrinks_to_available_data() {
        let points = samples(6, "Claude", "Rolling", 80.0, -1.0);
        let line = series(
            "Claude",
            false,
            &points
                .iter()
                .map(|s| (s.date, s.remaining))
                .collect::<Vec<_>>(),
        );
        let (low, high) = TrendChartData::trend_x_domain(&[line], NOW - 7 * DAY, NOW);
        // The domain must hug the data, not the 7-day range.
        assert!(high - low < 3600, "span was {}s", high - low);
        assert!(high <= NOW);
    }

    /// `narrowRangePadsAndTightensDomain` / `domainClampsTo0And100`.
    #[test]
    fn remaining_domain_pads_and_clamps() {
        let narrow = vec![series("Claude", false, &[(NOW, 48.0), (NOW + 60, 50.0)])];
        let (low, high) = TrendChartData::remaining_domain(&narrow);
        assert!(low < 48.0 && high > 50.0, "padded: {low}..{high}");
        assert!(low >= 0.0 && high <= 100.0);

        // A flat line at 100% must not produce an empty domain.
        let flat = vec![series("Claude", false, &[(NOW, 100.0), (NOW + 60, 100.0)])];
        let (low, high) = TrendChartData::remaining_domain(&flat);
        assert!(high > low, "got {low}..{high}");
        assert!(high <= 100.0);
        assert_eq!(TrendChartData::remaining_domain(&[]), (0.0, 100.0));
    }

    #[test]
    fn y_ticks_are_multiples_with_at_least_three() {
        let ticks = TrendChartData::y_ticks((0.0, 100.0));
        assert!(ticks.len() >= 3);
        assert!(ticks.iter().all(|value| (value % 10.0).abs() < 1e-9));
        assert_eq!(ticks[0], 0.0);
        assert_eq!(ticks[ticks.len() - 1], 100.0);

        // A domain too narrow for three multiples falls back to the two bounds,
        // as the Swift build does rather than drawing a bare chart.
        let narrow = TrendChartData::y_ticks((47.0, 53.0));
        assert_eq!(narrow, vec![47.0, 53.0]);

        // A 30-point domain fits three lines at a stride of 10.
        let mid = TrendChartData::y_ticks((40.0, 70.0));
        assert_eq!(mid, vec![40.0, 50.0, 60.0, 70.0]);
    }

    /// `tickDatesAreMidnightsAndNoonsInSpan`.
    #[test]
    fn tick_dates_are_midnights_and_noons() {
        let ticks = TrendChartData::trend_tick_dates(NOW - 3 * DAY, NOW, UTC);
        assert!(ticks.len() >= 5, "got {}", ticks.len());
        for tick in &ticks {
            let within_day = tick.rem_euclid(DAY);
            assert!(
                within_day == 0 || within_day == 12 * 3600,
                "tick at {within_day}s"
            );
        }
        // Midnight reads as a weekday, noon as 12pm.
        let midnight = ticks.iter().find(|t| t.rem_euclid(DAY) == 0).unwrap();
        let noon = ticks
            .iter()
            .find(|t| t.rem_euclid(DAY) == 12 * 3600)
            .unwrap();
        assert_eq!(TrendChartData::trend_tick_label(*noon, UTC), "12pm");
        assert!(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            .contains(&TrendChartData::trend_tick_label(*midnight, UTC).as_str()));
    }

    /// `nearestPointBinarySearchesSortedSamples`.
    #[test]
    fn nearest_point_binary_searches() {
        let points = vec![(0, 10.0), (100, 20.0), (200, 30.0)];
        assert_eq!(
            TrendChartData::nearest_point(&points, 95),
            Some((100, 20.0))
        );
        assert_eq!(TrendChartData::nearest_point(&points, 5), Some((0, 10.0)));
        assert_eq!(
            TrendChartData::nearest_point(&points, 500),
            Some((200, 30.0))
        );
        assert_eq!(TrendChartData::nearest_point(&[], 5), None);
    }

    /// The picker's options come out in canonical order, not alphabetical.
    #[test]
    fn trend_labels_are_in_canonical_order_not_alphabetical() {
        // All three present. Alphabetical would be Monthly, Rolling, Weekly.
        let mut all = samples(2, "Claude", "Rolling", 80.0, -1.0);
        all.extend(samples(2, "Claude", "Weekly", 40.0, -1.0));
        all.extend(samples(2, "Claude", "Monthly", 90.0, -1.0));
        assert_eq!(
            TrendChartData::trend_labels(&all, None, NOW - DAY),
            vec!["Rolling", "Weekly", "Monthly"]
        );
    }

    #[test]
    fn trend_labels_fold_scoped_windows_into_their_canonical_label() {
        // Claude's Fable is a scoped Weekly: not its own option, and not a
        // second "Weekly" either.
        let all = samples(2, "Claude", "Fable", 40.0, -1.0);
        assert_eq!(
            TrendChartData::trend_labels(&all, None, NOW - DAY),
            vec!["Weekly"]
        );
    }

    #[test]
    fn trend_labels_are_scoped_to_the_provider_filter() {
        let mut all = samples(2, "Claude", "Rolling", 80.0, -1.0);
        all.extend(samples(2, "Codex", "Monthly", 50.0, -1.0));
        assert_eq!(
            TrendChartData::trend_labels(&all, Some("Claude"), NOW - DAY),
            vec!["Rolling"],
            "a window only the filtered-out provider has is not offered"
        );
        assert_eq!(
            TrendChartData::trend_labels(&all, Some("Codex"), NOW - DAY),
            vec!["Monthly"]
        );
    }

    #[test]
    fn trend_labels_respect_the_range_cutoff() {
        let mut all = samples(2, "Claude", "Rolling", 80.0, -1.0);
        // Ten days old, so outside a 7-day range. Built by hand rather than via
        // `samples`, whose step argument moves the *remaining* value, not the date.
        all.push(RemainingSample {
            provider: "Claude".to_string(),
            label: "Monthly".to_string(),
            date: NOW - 10 * DAY,
            remaining: 90.0,
        });
        assert_eq!(
            TrendChartData::trend_labels(&all, None, NOW - 7 * DAY),
            vec!["Rolling"],
            "a window whose only samples predate the range is not offered"
        );
        assert_eq!(
            TrendChartData::trend_labels(&all, None, NOW - 30 * DAY),
            vec!["Rolling", "Monthly"],
            "the same sample is in range for 30d"
        );
    }

    #[test]
    fn trend_labels_offer_everything_when_there_is_no_history() {
        // Nothing to plot yet: the Swift build offers the full set, so the
        // picker is not empty and does not jump when the first sample lands.
        assert_eq!(
            TrendChartData::trend_labels(&[], None, NOW - DAY),
            vec!["Rolling", "Weekly", "Monthly"]
        );
    }

    /// Scoped weekly windows chart on the Weekly graph and are flagged.
    #[test]
    fn scoped_windows_fold_into_weekly() {
        assert_eq!(TrendChartData::canonical_trend_label("Fable"), "Weekly");
        let mut all = samples(3, "Claude", "Rolling", 80.0, -1.0);
        all.extend(samples(3, "Claude", "Fable", 40.0, -1.0));
        let built = TrendChartData::build_trend_series(&all, "Weekly", None, NOW - DAY);
        assert_eq!(built.len(), 1, "Rolling is not the weekly graph");
        assert!(built[0].scoped);
        assert_eq!(built[0].name, "Claude Fable");
    }

    #[test]
    fn trend_series_honours_the_cutoff_and_filter() {
        let mut all = samples(10, "Claude", "Rolling", 80.0, -1.0);
        all.extend(samples(10, "Codex", "Rolling", 60.0, -1.0));
        let both = TrendChartData::build_trend_series(&all, "Rolling", None, NOW - DAY);
        assert_eq!(both.len(), 2);
        let filtered =
            TrendChartData::build_trend_series(&all, "Rolling", Some("Codex"), NOW - DAY);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].provider, "Codex");
        // A cutoff that excludes everything gives no series.
        assert!(TrendChartData::build_trend_series(&all, "Rolling", None, NOW + DAY).is_empty());
    }

    /// `rollingCardHonorsProviderFilter` and the worst-first ordering.
    #[test]
    fn latest_rolling_is_worst_first() {
        let all = vec![
            RemainingSample {
                provider: "Claude".into(),
                label: "Rolling".into(),
                date: NOW - 600,
                remaining: 84.0,
            },
            RemainingSample {
                provider: "Claude".into(),
                label: "Rolling".into(),
                date: NOW,
                remaining: 80.0,
            },
            RemainingSample {
                provider: "Codex".into(),
                label: "Rolling".into(),
                date: NOW,
                remaining: 30.0,
            },
            RemainingSample {
                provider: "Codex".into(),
                label: "Weekly".into(),
                date: NOW,
                remaining: 5.0,
            },
        ];
        let rows = TrendChartData::latest_rolling(&all, None);
        assert_eq!(rows.len(), 2, "Weekly is not the rolling card");
        assert_eq!(rows[0].0, "Codex", "worst first");
        assert_eq!(rows[1].0, "Claude");
        assert_eq!(rows[1].1, 80.0, "the latest reading, not the first");
        assert_eq!(
            TrendChartData::latest_rolling(&all, Some("Claude")).len(),
            1
        );
    }

    #[test]
    fn nearest_rows_covers_every_series() {
        let a = series("Claude", false, &[(NOW - 300, 80.0), (NOW, 75.0)]);
        let b = series("Codex", false, &[(NOW - 300, 40.0), (NOW, 35.0)]);
        let both = vec![a, b];
        let rows = TrendChartData::nearest_rows(&both, NOW - 100);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], ("Claude", 75.0));
        assert_eq!(rows[1], ("Codex", 35.0));
    }
}

// MARK: - Metric, palette and per-model colouring

/// Tokens or cost, the metric switch on both bar charts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Metric {
    Tokens,
    Cost,
}

impl Metric {
    pub fn label(self) -> &'static str {
        match self {
            Metric::Tokens => "Tokens",
            Metric::Cost => "Cost",
        }
    }

    pub const ALL: [Metric; 2] = [Metric::Tokens, Metric::Cost];
}

/// The eight-colour palette, as 0–255 RGB, in the Swift build's order.
pub const PALETTE: [(u8, u8, u8); 8] = [
    (217, 120, 87),
    (64, 140, 242),
    (51, 173, 112),
    (184, 115, 217),
    (242, 158, 61),
    (77, 184, 199),
    (212, 92, 140),
    (140, 153, 89),
];

/// A stable colour for a model name.
///
/// The Swift build used `abs(model.hashValue) % palette.count`, which is
/// seeded per process, so the same model got a different colour between launches
/// — and a different one again here, since Rust's `Hash` is randomised too. The
/// Swift build's chart legends and table were *consistent within a session*,
/// which is the property that actually matters, so this is an FNV-1a hash:
/// deterministic, so a model's colour is the same on every launch and on every
/// platform.
pub fn colour_for_model(model: &str) -> (u8, u8, u8) {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in model.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    PALETTE[(hash % PALETTE.len() as u64) as usize]
}

/// A compact axis label, ported from `ModelsView.axisLabel(_:metric:)`.
///
/// ```text
/// metric == .cost
///     ? (abs(value) < 1000 ? String(format: "$%g", value)
///                          : "$" + TokenFormat.format(Int(value)))
///     : TokenFormat.format(Int(value))
/// ```
///
/// Tokens shorten through `TokenFormat` (1.2m). Costs below $1000 go through
/// `%g`, which is not the same as printing the number: `%g` keeps six
/// significant digits and drops trailing zeros, so `0.1 + 0.2` labels as
/// `$0.3` rather than `$0.30000000000000004`. `format!("{value}")` in Rust
/// prints the shortest *round-tripping* form, so it agrees on most values and
/// disagrees exactly where a float artefact appears — which is the case the
/// user sees on a cost axis.
pub fn axis_label(value: f64, metric: Metric) -> String {
    match metric {
        Metric::Cost if value.abs() < 1000.0 => format!("${}", percent_g(value)),
        Metric::Cost => format!("${}", TokenFormat::format(value as i64)),
        Metric::Tokens => TokenFormat::format(value as i64),
    }
}

/// C's `%g` at the default precision of six significant digits.
///
/// `%g` picks fixed or exponent notation by the decimal exponent: fixed while
/// `-4 <= exp < 6`, exponent otherwise, and drops trailing zeros either way.
fn percent_g(value: f64) -> String {
    if !value.is_finite() {
        return format!("{value}");
    }
    if value == 0.0 {
        return "0".to_string();
    }
    let exponent = value.abs().log10().floor() as i32;
    if !(-4..6).contains(&exponent) {
        // Exponent form. `%.5e` gives the mantissa at precision 6, then the
        // exponent is normalised to the minimum two digits `%g` prints.
        let formatted = format!("{value:.5e}");
        let (mantissa, power) = formatted.split_once('e').expect("%e has an exponent");
        let mantissa = trim_trailing_zeros(mantissa);
        let power: i32 = power.parse().expect("%e exponent is an integer");
        let sign = if power < 0 { "-" } else { "+" };
        return format!("{mantissa}e{sign}{:02}", power.abs());
    }
    // Fixed form: precision is the remaining significant digits.
    let decimals = (5 - exponent).max(0) as usize;
    trim_trailing_zeros(&format!("{value:.decimals$}"))
}

/// Drops trailing zeros after a decimal point: "1.50000" → "1.5", "10.00" → "10".
fn trim_trailing_zeros(text: &str) -> String {
    if !text.contains('.') {
        return text.to_string();
    }
    text.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// The metric value for an entry, which is what the bar length encodes.
pub fn metric_value(metric: Metric, total_tokens: i64, cost: f64) -> f64 {
    match metric {
        Metric::Tokens => total_tokens as f64,
        Metric::Cost => cost,
    }
}

#[cfg(test)]
mod palette_tests {
    use super::*;

    #[test]
    fn metric_labels() {
        assert_eq!(Metric::Tokens.label(), "Tokens");
        assert_eq!(Metric::Cost.label(), "Cost");
    }

    /// Model colours must be stable across calls, or a legend and its bar chart
    /// would disagree — and across processes, so they must not use `Hash`.
    #[test]
    fn model_colour_is_deterministic() {
        let first = colour_for_model("claude-opus-5");
        let second = colour_for_model("claude-opus-5");
        assert_eq!(first, second, "same model, same colour, every call");
        assert!(PALETTE.contains(&first), "must come from the palette");
        // Different models generally differ, and both are in the palette.
        assert!(PALETTE.contains(&colour_for_model("gpt-5")));
    }

    #[test]
    fn metric_value_selects_the_channel() {
        assert_eq!(metric_value(Metric::Tokens, 1234, 9.99), 1234.0);
        assert_eq!(metric_value(Metric::Cost, 1234, 9.99), 9.99);
    }

    /// Axis labels go through `TokenFormat` for tokens and `%g` for small costs.
    #[test]
    fn axis_labels_match_the_swift_format() {
        assert_eq!(axis_label(0.0, Metric::Tokens), "0");
        assert_eq!(axis_label(850.0, Metric::Tokens), "850");
        assert_eq!(axis_label(1_200_000.0, Metric::Tokens), "1.2m");
        assert_eq!(axis_label(3_652_595_073.0, Metric::Tokens), "3.65b");
        // Cost under $1000 is `%g`, not a rounded integer: `$13` would lose the
        // cents the label is there to show.
        assert_eq!(axis_label(12.5, Metric::Cost), "$12.5");
        assert_eq!(axis_label(0.05, Metric::Cost), "$0.05");
        assert_eq!(axis_label(999.9, Metric::Cost), "$999.9");
        assert_eq!(axis_label(0.0, Metric::Cost), "$0");
        // $1000 and up shortens like tokens, with the dollar sign kept.
        assert_eq!(axis_label(1500.0, Metric::Cost), "$1.5k");
        assert_eq!(axis_label(2_400_000.0, Metric::Cost), "$2.4m");
    }

    /// `%g` keeps six significant digits and drops the rest, which is what stops
    /// a summed cost from labelling as `$0.30000000000000004`.
    #[test]
    fn percent_g_is_not_plain_float_printing() {
        assert_eq!(percent_g(0.1 + 0.2), "0.3");
        assert_eq!(percent_g(1.0 / 3.0), "0.333333");
        assert_eq!(percent_g(0.0), "0");
        assert_eq!(percent_g(-4.25), "-4.25");
        assert_eq!(percent_g(123_456.0), "123456");
        // Below 1e-4 `%g` switches to exponent notation.
        assert_eq!(percent_g(0.00001), "1e-05");
    }
}
