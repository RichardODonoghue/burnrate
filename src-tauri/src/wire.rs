use serde::{Deserialize, Serialize};

use burnrate_core::charts::{ChartRange, Metric};
use burnrate_core::model::ProviderUsage;
use burnrate_core::settings::Settings;

/// What the window shows.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AppPane {
    Usage,
    Notifications,
    Widgets,
    About,
}

/// A chart point in the units the Swift Charts plot used, so the frontend only
/// turns x/y into pixels and never does arithmetic of its own.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Point {
    pub(crate) x: i64,
    pub(crate) y: f64,
}

/// One line on the trend chart.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Series {
    pub(crate) key: String,
    pub(crate) name: String,
    pub(crate) provider: String,
    /// Model-scoped windows (Claude's Fable) draw dashed and faded.
    pub(crate) scoped: bool,
    pub(crate) points: Vec<Point>,
}

/// A gridline or tick label on either axis.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Tick {
    pub(crate) at: i64,
    pub(crate) label: String,
}

/// How the X axis should be labelled, chosen from the *visible* span.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum XAxisStyle {
    /// Hourly marks, striding by `stride_hours`.
    Hourly { stride_hours: i64 },
    /// Midnight (weekday) and noon (12pm) per day.
    Daily,
}

/// One bar in the daily or ranking chart.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Bar {
    /// Which model or provider the colour comes from.
    pub(crate) key: String,
    pub(crate) provider: String,
    pub(crate) label: String,
    pub(crate) value: f64,
    pub(crate) cost: f64,
    /// Token total. The breakdown table shows the four channels below instead,
    /// which is why they travel separately — the first version of that table put
    /// this total in the INPUT column and left the rest as dashes.
    pub(crate) tokens: i64,
    pub(crate) input: i64,
    pub(crate) output: i64,
    /// Cache reads plus cache writes, as `ModelsView` sums them into one column.
    pub(crate) cache: i64,
    pub(crate) reasoning: i64,
    pub(crate) requests: i64,
    /// `axisLabel(value, metric)` — "1.2m", "$12.5". Pre-formatted here so the
    /// frontend never formats a figure of its own, which is how axes drift.
    pub(crate) value_text: String,
    /// The ranking chart's trailing annotation: "1.2m tok" or "$12.50".
    pub(crate) annotation: String,
}

/// Everything the Usage pane draws. The Swift layout, section for section:
/// snapshot cards, remaining over time, daily usage by model, top models,
/// breakdown table.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Dashboard {
    pub(crate) range: ChartRange,
    /// `ChartRange.label()` — "24h", "7d", "30d". The card titles read this, and
    /// read `rangeLabel` for two releases before the field existed, so both
    /// charts were titled "Top models (undefined)".
    pub(crate) range_label: String,
    pub(crate) metric: Metric,
    /// `Metric.label()` — "Tokens", "Cost". The titles capitalise these, and
    /// `Metric` itself serialises lowercase, so the chart read "(tokens)".
    pub(crate) metric_label: String,
    pub(crate) window_label: String,
    pub(crate) provider_filter: Option<String>,
    /// Window labels actually present, for the picker.
    pub(crate) window_labels: Vec<String>,
    pub(crate) provider_names: Vec<String>,

    // snapshot cards
    pub(crate) rolling: Vec<Figure>,
    pub(crate) tokens_today: Option<i64>,
    pub(crate) requests_today: i64,
    pub(crate) cost_today: f64,

    // trend
    pub(crate) series: Vec<Series>,
    pub(crate) x_domain: (i64, i64),
    pub(crate) x_style: XAxisStyle,
    pub(crate) x_ticks: Vec<Tick>,
    pub(crate) y_domain: (f64, f64),
    pub(crate) y_ticks: Vec<f64>,

    // daily stacked bars
    pub(crate) daily: Vec<DailyBar>,
    pub(crate) daily_y_ticks: Vec<f64>,
    /// `daily_y_ticks` as `axisLabel` renders them, so the axis needs no
    /// formatting in the frontend.
    pub(crate) daily_y_labels: Vec<String>,
    /// The tallest day, for the daily chart's Y domain.
    pub(crate) daily_maximum: f64,

    /// Whether the 30-day history has any entries for the current filter. The
    /// Swift view branches on `filteredDaily.isEmpty` and shows an
    /// unavailable-view instead of the cards; an empty chart series is not the
    /// same condition, because the trend history outlives the model history.
    pub(crate) has_data: bool,

    // ranking + table
    pub(crate) ranking: Vec<Bar>,
    /// The ranking chart's value axis. Only drawn for the token metric, as in
    /// `ModelsView`, where a dollar axis under eight bars is noise.
    pub(crate) ranking_ticks: Vec<f64>,
    pub(crate) ranking_tick_labels: Vec<String>,
    pub(crate) table: Vec<Bar>,
    /// Models with no entry in the LiteLLM price table. Their COST cell reads
    /// "—" because the figure is genuinely unknown, and saying so is better than
    /// a confident zero — or than a silently empty column.
    pub(crate) unpriced_models: Vec<String>,
}

/// A labelled figure for the snapshot cards.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Figure {
    pub(crate) key: String,
    pub(crate) label: String,
    pub(crate) value: String,
}

/// One day in the stacked chart: its bars and its total.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DailyBar {
    pub(crate) day: i64,
    pub(crate) total: f64,
    pub(crate) total_text: String,
    pub(crate) bars: Vec<Bar>,
}

/// The full state the frontend renders from, in one payload.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Snapshot {
    pub(crate) pane: AppPane,
    pub(crate) settings: Settings,
    pub(crate) usage: Vec<ProviderUsage>,
    pub(crate) missing: Vec<String>,
    /// Percent remaining for the icon severity, from the Rolling windows.
    pub(crate) remaining: Option<f64>,
    pub(crate) app_version: String,
    pub(crate) core_version: String,
    /// Where settings live. Shown in About, so it travels with the payload
    /// rather than needing a command of its own.
    pub(crate) settings_path: String,
    /// The newer version GitHub is offering, if any.
    pub(crate) update_available: Option<String>,
    /// One line of updater state for the About pane.
    pub(crate) update_state: String,
    pub(crate) update_busy: bool,
    /// False where the app cannot replace itself, so the pane offers the page.
    pub(crate) can_install_update: bool,
    pub(crate) last_poll_unix: u64,
    pub(crate) poll_count: u64,
    pub(crate) platforms: PlatformInfo,
    pub(crate) dashboard: Dashboard,
    pub(crate) spend_today: std::collections::HashMap<String, f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PlatformInfo {
    pub(crate) os: &'static str,
    /// Linux needs WebKitGTK / libayatana at runtime; say so up front.
    pub(crate) runtime_dependencies: Vec<&'static str>,
}

pub(crate) fn platform_info() -> PlatformInfo {
    let (os, deps): (&'static str, Vec<&'static str>) = if cfg!(target_os = "macos") {
        ("macOS", vec![])
    } else if cfg!(target_os = "windows") {
        ("Windows", vec!["WebView2 (preinstalled on Windows 11)"])
    } else {
        (
            "Linux",
            vec!["libwebkit2gtk-4.1-0", "libayatana-appindicator3-1"],
        )
    };
    PlatformInfo {
        os,
        runtime_dependencies: deps,
    }
}
