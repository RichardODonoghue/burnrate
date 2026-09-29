//! Platform-independent BurnRate logic.
//!
//! Everything here is pure Rust with no Tauri, UI or OS-framework dependency:
//! local log parsing, vendor quota APIs, throttling, alert evaluation, chart
//! aggregation. Ported 1:1 from the Swift `BurnRateCore` target, whose 111 tests
//! are the parity spec (see `PARITY.md`).

/// Crate version, surfaced in the UI so the app can report which core it runs.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// One quota window (5-hour, weekly, monthly, …) for a single provider.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageWindow {
    /// Display label, e.g. "5-hour", "Weekly", "Monthly".
    pub label: String,
    /// Percent *remaining* (0–100), when the provider reports percentages.
    pub percent_remaining: Option<f64>,
    /// Percent *used* (0–100), when the provider only reports usage.
    pub percent_used: Option<f64>,
    /// When this window resets, if known.
    pub resets_at: Option<Timestamp>,
    /// Plan capacity in tokens, for providers that only report local tokens.
    pub capacity: Option<i64>,
}

/// Seconds since the Unix epoch. A real date/time type lands with the
/// reset-relative-formatting port; kept dependency-light for now.
pub type Timestamp = i64;

impl UsageWindow {
    /// Remaining percent, deriving it from `used` when necessary.
    pub fn remaining(&self) -> Option<f64> {
        self.percent_remaining
            .or_else(|| self.percent_used.map(|used| 100.0 - used))
    }
}

/// Percent remaining as the menu shows it: "42%" or "--" when unknown.
pub fn format_remaining(window: &UsageWindow) -> String {
    match window.remaining() {
        Some(percent) => format!("{:.0}%", percent.clamp(0.0, 100.0)),
        None => "--".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(remaining: Option<f64>, used: Option<f64>) -> UsageWindow {
        UsageWindow {
            label: "Weekly".into(),
            percent_remaining: remaining,
            percent_used: used,
            resets_at: None,
            capacity: None,
        }
    }

    #[test]
    fn uses_remaining_when_present() {
        assert_eq!(format_remaining(&window(Some(42.4), None)), "42%");
    }

    #[test]
    fn derives_remaining_from_used() {
        assert_eq!(format_remaining(&window(None, Some(15.0))), "85%");
    }

    #[test]
    fn unknown_percent_shows_dashes() {
        assert_eq!(format_remaining(&window(None, None)), "--");
    }

    #[test]
    fn clamps_out_of_range_values() {
        assert_eq!(format_remaining(&window(Some(-3.0), None)), "0%");
        assert_eq!(format_remaining(&window(Some(140.0), None)), "100%");
    }
}
