use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tauri::{AppHandle, Manager, Wry};

use burnrate_core::charts::{axis_label, metric_value, ChartRange, Metric, TrendChartData};
use burnrate_core::formatting::TokenFormat;
use burnrate_core::menu::StatusMenuBuilder;
use burnrate_core::paths::AppPaths;
use burnrate_core::poller::{local_start_of_day, local_utc_offset_seconds};
use burnrate_core::usage::{DailyModelUsage, ModelUsageAggregator, ModelUsageEntry};

use crate::wire::{
    platform_info, AppPane, Bar, DailyBar, Dashboard, Figure, Point, Series, Snapshot, Tick,
    XAxisStyle,
};
use crate::{now_unix, AppState};

// MARK: - Commands

/// Everything the window renders, in one call. All chart arithmetic happens
/// here and in `burnrate_core::charts`, so the axes cannot drift from the Swift
/// build's.
#[tauri::command]
pub(crate) fn snapshot(
    app: AppHandle<Wry>,
    pane: Option<AppPane>,
    range: Option<String>,
    metric: Option<String>,
    window_label: Option<String>,
    provider_filter: Option<String>,
) -> Snapshot {
    let state = app.state::<Arc<AppState>>();
    let last = state.last.lock().expect("result lock").clone();
    let usage = last
        .as_ref()
        .map(|result| result.usage.clone())
        .unwrap_or_default();
    let missing = last
        .as_ref()
        .map(|result| result.missing.clone())
        .unwrap_or_default();
    let remaining = StatusMenuBuilder::worst_rolling_remaining(&usage);
    let update = state.update_status();
    let poller = state.poller.lock().expect("poller lock");

    let now = now_unix() as i64;
    let offset = local_utc_offset_seconds();
    let range = range
        .as_deref()
        .and_then(ChartRange::from_label)
        .unwrap_or(ChartRange::Week);
    let metric = match metric.as_deref() {
        Some("cost") => Metric::Cost,
        _ => Metric::Tokens,
    };

    // --- trend ------------------------------------------------------------
    let history = poller.remaining_history().to_vec();
    let cutoff = TrendChartData::trend_cutoff(range, now);
    // Claude's model-scoped weekly folds into Weekly, so the picker offers
    // whichever canonical labels the visible data actually contains, in
    // canonical order (Rolling, Weekly, Monthly) — not alphabetical.
    let window_labels: Vec<String> =
        TrendChartData::trend_labels(&history, provider_filter.as_deref(), cutoff);
    let requested = window_label.unwrap_or_else(|| "Rolling".to_string());
    let window_label = if window_labels.contains(&requested) {
        requested
    } else {
        window_labels.first().cloned().unwrap_or(requested)
    };

    let built = TrendChartData::build_trend_series(
        &history,
        &window_label,
        provider_filter.as_deref(),
        cutoff,
    );
    let series: Vec<Series> = built
        .iter()
        .map(|line| Series {
            key: line.key.clone(),
            name: line.name.clone(),
            provider: line.provider.clone(),
            scoped: line.scoped,
            points: line
                .samples
                .iter()
                .map(|(x, y)| Point { x: *x, y: *y })
                .collect(),
        })
        .collect();

    let (x_low, x_high) = TrendChartData::trend_x_domain(&built, cutoff, now);
    let span = x_high - x_low;
    let (x_style, x_ticks) = if TrendChartData::trend_x_hourly(span) {
        // Hourly marks, snapped to the hour so the grid is regular.
        let stride = TrendChartData::trend_hour_stride(span) * 3600;
        let first = x_low.div_euclid(3600) * 3600;
        let mut ticks = Vec::new();
        let mut at = first;
        while at <= x_high {
            if at >= x_low {
                ticks.push(Tick {
                    at,
                    label: hour_label(at, offset),
                });
            }
            at += stride;
        }
        (
            XAxisStyle::Hourly {
                stride_hours: stride / 3600,
            },
            ticks,
        )
    } else {
        let ticks = TrendChartData::trend_tick_dates(x_low, x_high, offset)
            .into_iter()
            .map(|at| Tick {
                at,
                label: TrendChartData::trend_tick_label(at, offset),
            })
            .collect();
        (XAxisStyle::Daily, ticks)
    };

    let y_domain = TrendChartData::remaining_domain(&built);
    let y_ticks = TrendChartData::y_ticks(y_domain);

    // --- daily and ranking, scoped to the selected range --------------------
    let daily_all = last
        .as_ref()
        .map(|result| result.model_daily.clone())
        .unwrap_or_default();
    let daily_start = now - range.span_seconds();
    // Each slot is computed with the offset in effect **on that day**, not with
    // today's. New Zealand moved from +12 to +13 on 27 September, so building
    // every slot with the current offset put each earlier slot an hour off —
    // matching no stored bucket at all. The chart showed four days of bars and
    // five empty slots, which is the "quite bare" graph with no usage before the
    // 26th.
    let today_start = local_start_of_day(now);
    // A slot per calendar day in the range, up to and including today.
    //
    // The first version emitted only the days that had data. That made the axis
    // index-based, so a day with no samples silently closed up and looked
    // identical to a day that was fully spent, and the last slot was whatever
    // partial day the poll happened to land in. Both read as artifacting on the
    // right-hand end of the chart. Days are calendar slots now, and gaps are gaps.
    let by_day: HashMap<i64, &DailyModelUsage> =
        daily_all.iter().map(|day| (day.day, day)).collect();
    let mut daily: Vec<DailyBar> = Vec::new();
    for cursor in daily_slots(daily_start, now, &local_start_of_day) {
        let bars: Vec<Bar> = by_day
            .get(&cursor)
            .map(|day| {
                day.entries
                    .iter()
                    .filter(|entry| {
                        provider_filter
                            .as_deref()
                            .map(|filter| entry.provider == filter)
                            .unwrap_or(true)
                    })
                    .map(|entry| bar_for(entry, metric))
                    .collect()
            })
            .unwrap_or_default();
        let total = bars.iter().map(|bar| bar.value).sum();
        daily.push(DailyBar {
            day: cursor,
            total,
            total_text: axis_label(total, metric),
            bars,
        });
    }
    let daily_max = daily.iter().map(|day| day.total).fold(0.0_f64, f64::max);
    let daily_ticks = nice_ticks(0.0, daily_max);
    let daily_y_labels: Vec<String> = daily_ticks
        .iter()
        .map(|value| axis_label(*value, metric))
        .collect();

    // Whether there is anything at all for this filter over the full 30 days —
    // the Swift view's `filteredDaily.isEmpty` check.
    let has_data = daily_all.iter().any(|day| {
        day.entries.iter().any(|entry| {
            provider_filter
                .as_deref()
                .is_none_or(|f| entry.provider == f)
        })
    });

    // Totals are aggregated from the in-range buckets, not the full 30 days:
    // otherwise a narrow range would list models it is not showing.
    let in_range: Vec<DailyModelUsage> = daily_all
        .iter()
        .filter(|day| day.day >= daily_start)
        .cloned()
        .collect();
    let mut totals = ModelUsageAggregator::totals_from_daily(&in_range);
    if let Some(filter) = provider_filter.as_deref() {
        totals.retain(|entry| entry.provider == filter);
    }
    let table: Vec<Bar> = totals.iter().map(|entry| bar_for(entry, metric)).collect();
    let ranking: Vec<Bar> = table.iter().take(8).cloned().collect();
    // The ranking's value axis, from the same nice-number rule as the daily
    // chart, and empty for cost (as Swift draws it).
    let ranking_max = ranking.iter().map(|bar| bar.value).fold(0.0_f64, f64::max);
    let ranking_ticks = if metric == Metric::Tokens {
        nice_ticks(0.0, ranking_max)
    } else {
        Vec::new()
    };
    let ranking_tick_labels: Vec<String> = ranking_ticks
        .iter()
        .map(|value| axis_label(*value, metric))
        .collect();

    // --- snapshot cards ---------------------------------------------------
    remember_models(&totals);

    let rolling: Vec<Figure> = TrendChartData::latest_rolling(&history, provider_filter.as_deref())
        .into_iter()
        .map(|(provider, percent)| Figure {
            key: provider.clone(),
            label: provider,
            value: format!("{percent:.0}%"),
        })
        .collect();

    let today_entries: Vec<&ModelUsageEntry> = daily_all
        .iter()
        .find(|day| day.day == today_start)
        .map(|day| day.entries.iter().collect())
        .unwrap_or_default();
    let tokens_today: i64 = today_entries.iter().map(|entry| entry.total_tokens()).sum();
    let requests_today: i64 = today_entries.iter().map(|entry| entry.requests).sum();
    let cost_today: f64 = today_entries.iter().map(|entry| entry.cost).sum();

    // Models the price table could not resolve, so the breakdown can say why a
    // cost is missing instead of leaving a column of dashes unexplained.
    //
    // Reuses the poller guard opened at the top of this function. Taking the lock
    // again here is a self-deadlock — `std::sync::Mutex` is not reentrant, and
    // `snapshot` runs on the main thread, so the whole app hangs rather than just
    // this command. The Linux tray smoke test caught it: with the main thread
    // blocked, the D-Bus property call stopped answering.
    let unpriced_models: Vec<String> = poller.pricing_state().1;

    let provider_names: Vec<String> = {
        let mut names: Vec<String> = totals.iter().map(|entry| entry.provider.clone()).collect();
        names.sort();
        names.dedup();
        names
    };

    Snapshot {
        pane: pane.unwrap_or(AppPane::Usage),
        settings: state.settings(),
        usage,
        missing,
        remaining,
        app_version: app.package_info().version.to_string(),
        core_version: state.core_version.clone(),
        settings_path: AppPaths::detect().settings_file().display().to_string(),
        update_available: update.available.clone(),
        update_state: update.state.clone(),
        update_busy: update.busy,
        can_install_update: update.can_install,
        last_poll_unix: last.as_ref().map(|result| result.at as u64).unwrap_or(0),
        poll_count: poller.poll_count(),
        platforms: platform_info(),
        dashboard: Dashboard {
            range,
            range_label: range.label().to_string(),
            metric,
            metric_label: metric.label().to_string(),
            window_label,
            provider_filter: provider_filter.clone(),
            window_labels,
            provider_names,
            rolling,
            tokens_today: (tokens_today > 0).then_some(tokens_today),
            requests_today,
            cost_today,
            series,
            x_domain: (x_low, x_high),
            x_style,
            x_ticks,
            y_domain,
            y_ticks,
            daily,
            daily_y_ticks: daily_ticks,
            daily_y_labels,
            daily_maximum: daily_max,
            has_data,
            ranking,
            ranking_ticks,
            ranking_tick_labels,
            table,
            unpriced_models,
        },
        spend_today: last
            .as_ref()
            .map(|result| result.spend_today.clone())
            .unwrap_or_default(),
    }
}

/// Recorded so `model_colours` can return the palette for every model on screen.
///
/// A process-wide lock, not a `thread_local`: `snapshot` fills this and
/// `model_colours` reads it, and those are two separate commands with no promise
/// of landing on the same thread. It works today only because both happen to be
/// dispatched on the main thread — a change to either would silently strip every
/// chart of its model colours.
fn remember_models(entries: &[ModelUsageEntry]) {
    let mut models = MODELS_SEEN.lock().expect("models lock");
    models.clear();
    models.extend(entries.iter().map(|entry| entry.display_name()));
}

fn bar_for(entry: &ModelUsageEntry, metric: Metric) -> Bar {
    let value = metric_value(metric, entry.total_tokens(), entry.cost);
    Bar {
        key: entry.display_name(),
        provider: entry.provider.clone(),
        label: entry.display_name(),
        value,
        cost: entry.cost,
        tokens: entry.total_tokens(),
        input: entry.tokens.input,
        output: entry.tokens.output,
        cache: entry.tokens.cache_read + entry.tokens.cache_write,
        reasoning: entry.tokens.reasoning,
        requests: entry.requests,
        value_text: axis_label(value, metric),
        // Matches `ModelUsageEntry.annotation(_:)`: tokens carry a " tok" unit,
        // cost is bare dollars to the cent. The unit is not decoration — the bar
        // is unlabelled by an axis on the cost metric, so "$12.50" alone has to
        // say what it is.
        annotation: match metric {
            Metric::Tokens => format!("{} tok", TokenFormat::format(entry.total_tokens())),
            Metric::Cost => format!("${:.2}", entry.cost),
        },
    }
}

/// One epoch per local calendar day from `daily_start` to `now`, inclusive.
///
/// Each slot is that day's local midnight, which is the same value the day
/// buckets are keyed by — using today's offset for every slot is what left the
/// chart with four bars and five empty slots, because New Zealand moved from +12
/// to +13 on 27 September and every earlier slot was an hour off.
///
/// The walk steps to the *following noon* before asking for a midnight. A local
/// day is 23 or 25 hours across a daylight-saving change, so stepping by a fixed
/// 86,400 is ambiguous; aiming at noon is twelve hours from either midnight and
/// cannot land in a neighbouring day or repeat one.
///
/// `day_start` is a parameter rather than a direct call so a transition can be
/// tested without depending on the machine's timezone.
pub(crate) fn daily_slots(daily_start: i64, now: i64, day_start: &dyn Fn(i64) -> i64) -> Vec<i64> {
    let today_start = day_start(now);
    let mut slots = Vec::new();
    let mut probe = day_start(daily_start);
    loop {
        let day = day_start(probe);
        if day > today_start {
            break;
        }
        slots.push(day);
        probe = day + 86_400 + 43_200;
    }
    slots
}

/// Gridlines for a token or cost axis, at "nice" magnitudes.
///
/// Steps scale with the span — 1, 2 or 5 times a power of ten, sized to land on
/// roughly five gridlines whatever the magnitude. Fixed steps chosen by span do
/// not scale: every branch is a small number, so a large span lands on one huge
/// step and the axis gets thousands of gridlines.
pub(crate) fn nice_ticks(low: f64, high: f64) -> Vec<f64> {
    const TARGET_TICKS: f64 = 5.0;
    if !high.is_finite() || !low.is_finite() || high <= low {
        return vec![low];
    }
    let span = high - low;
    let raw = span / TARGET_TICKS;
    let magnitude = 10f64.powf(raw.log10().floor());
    let normalised = raw / magnitude;
    // 1, 2, 5, 10 — the "nice" multipliers, so labels read 1e9 / 2e9 rather
    // than 1.37e9.
    let step = magnitude
        * if normalised <= 1.0 {
            1.0
        } else if normalised <= 2.0 {
            2.0
        } else if normalised <= 5.0 {
            5.0
        } else {
            10.0
        };
    if step <= 0.0 || !step.is_finite() {
        return vec![low];
    }
    let mut ticks = Vec::new();
    let mut value = (low / step).ceil() * step;
    // A cap as a backstop: the step is derived from the span, so this cannot
    // trip, but a degenerate input should draw nothing rather than hang.
    while value <= high && ticks.len() < 64 {
        ticks.push(value);
        value += step;
    }
    ticks
}

/// "14:00" in the machine's local time.
fn hour_label(at: i64, offset: i64) -> String {
    let local = at + offset;
    let minutes = (local.rem_euclid(3600)) / 60;
    let hour = (local.div_euclid(3600)) % 24;
    format!("{hour:02}:{minutes:02}")
}

/// Model names the app has seen, so the palette can be returned for all of them.
pub(crate) fn state_snapshot_entries() -> Vec<String> {
    MODELS_SEEN.lock().expect("models lock").clone()
}

/// Model names seen in the last snapshot, filled in by `snapshot`.
static MODELS_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
