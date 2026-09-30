//! Prints what a poll actually finds on this machine.
//!
//!     cargo run -p burnrate-core --example poll_once
//!
//! The unit tests use fixtures; this uses the real `~/.claude`, `~/.codex` and
//! OpenCode database, which is the only way to catch a schema that has drifted.

use burnrate_core::charts::TrendChartData;
use burnrate_core::poller::Poller;
use burnrate_core::settings::Settings;
use burnrate_core::usage::ModelUsageAggregator;

fn main() {
    let mut poller = Poller::new();
    poller.load_pricing_cache();
    let settings = Settings {
        poll_interval_seconds: 60,
        ..Settings::default()
    };

    let result = poller.poll(&settings);

    println!("=== providers ===");
    if result.usage.is_empty() {
        println!("  (none)");
    }
    for provider in &result.usage {
        let plan = provider.plan.clone().unwrap_or_else(|| "—".into());
        println!("  {} [{plan}]", provider.provider_name);
        for window in &provider.windows {
            let percent = window
                .percent_remaining
                .map(|value| format!("{value:.1}%"))
                .unwrap_or_else(|| "--".into());
            println!(
                "    {:<8} {percent:>8}  {} tokens",
                window.label, window.tokens_used
            );
        }
    }

    println!("\n=== not detected ===");
    if result.missing.is_empty() {
        println!("  (nothing missing)");
    }
    for line in &result.missing {
        println!("  {line}");
    }

    println!("\n=== models (top 8) ===");
    // The real pricing cache, so the example reports the same estimated costs the
    // app does for models whose source reports none (Claude's logs never do).
    let mut pricing = pricing_table();
    let totals = ModelUsageAggregator::totals(&result.batches, &mut pricing);
    if totals.is_empty() {
        println!("  (none)");
    }
    for entry in totals.iter().take(8) {
        println!(
            "  {:<34} {:>12} tokens  {} req",
            entry.display_name(),
            entry.total_tokens(),
            entry.requests
        );
    }

    println!("\n=== spend today (USD) ===");
    if result.spend_today.is_empty() {
        println!("  (none reported)");
    }
    for (provider, amount) in &result.spend_today {
        println!("  {provider}: ${amount:.2}");
    }

    println!("\n=== chart history ===");
    println!(
        "  remaining-history samples: {}",
        result.remaining_history.len()
    );
    // The range the dashboard would draw for a 30-day view.
    let cutoff = TrendChartData::trend_cutoff(burnrate_core::charts::ChartRange::Month, result.at);
    for label in ["Rolling", "Weekly", "Monthly"] {
        let series =
            TrendChartData::build_trend_series(&result.remaining_history, label, None, cutoff);
        if series.is_empty() {
            continue;
        }
        let domain = TrendChartData::remaining_domain(&series);
        println!("  {label}: {} series, y-domain {:?}", series.len(), domain);
    }

    println!("  sample batches: {}", result.batches.len());
    for (provider, samples) in &result.batches {
        println!("    {provider}: {} samples", samples.len());
    }
    println!("\n  notifications raised: {}", result.notifications.len());
}

/// The cached LiteLLM price table, or an empty one if it has not been fetched.
fn pricing_table() -> burnrate_core::usage::PricingTable {
    let path = burnrate_core::paths::AppPaths::detect()
        .app_directory()
        .join("pricing.json");
    match std::fs::read(&path) {
        Ok(bytes) => {
            burnrate_core::usage::PricingTable::from_litellm_json(&bytes).unwrap_or_default()
        }
        Err(_) => burnrate_core::usage::PricingTable::default(),
    }
}
