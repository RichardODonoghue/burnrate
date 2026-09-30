//! Formatting helpers shared by every platform's menus and dashboards.
//!
//! Ported 1:1 from the Swift app's `Formatting.swift`. Parity tests:
//! `UsageComputationTests.tokensFormatting`, `UsageComputationTests.relativeTimeBuckets`.

/// Compact token counts: 850, 42.3k, 1.2m, 3.6b, 1.1t.
pub struct TokenFormat;

impl TokenFormat {
    pub fn format(count: i64) -> String {
        let value = count as f64;
        if value < 1_000.0 {
            return count.to_string();
        }
        if value < 1_000_000.0 {
            return format!("{}k", Self::trim(value / 1_000.0));
        }
        if value < 1_000_000_000.0 {
            return format!("{}m", Self::trim(value / 1_000_000.0));
        }
        if value < 1_000_000_000_000.0 {
            return format!("{}b", Self::trim(value / 1_000_000_000.0));
        }
        format!("{}t", Self::trim(value / 1_000_000_000_000.0))
    }

    /// Rounds to 2 decimals then drops trailing zeros: 10.0 → "10", 1.5 → "1.5",
    /// 1.25 → "1.25". Mirrors Swift's `%.2f` + regex trim.
    fn trim(value: f64) -> String {
        let two_dp = format!("{value:.2}");
        if !two_dp.contains('.') {
            return two_dp;
        }
        two_dp
            .trim_end_matches('0')
            .trim_end_matches('.')
            .to_string()
    }
}

/// FNV-1a over the bytes of `text`.
///
/// `std::hash::DefaultHasher` is seeded per process, so anything derived from it
/// differs between launches: a model's colour would change on every start, and a
/// token fingerprint would make every poll look like a plan switch. This is
/// stable across processes and across platforms.
pub fn stable_hash(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    hash
}

/// Compact relative time: "in 45m", "in 5h", "in 3d" (or "now"). Keeps menu
/// rows narrow — a full date was the widest line in the dropdown.
pub struct RelativeTime;

impl RelativeTime {
    /// `date` and `now` are seconds since the Unix epoch.
    pub fn format(date: i64, now: i64) -> String {
        let seconds = date - now;
        if seconds <= 0 {
            return "now".to_string();
        }
        let seconds = seconds as f64;
        if seconds < 3600.0 {
            return format!("in {}m", (seconds / 60.0).ceil() as i64);
        }
        if seconds < 86_400.0 {
            let hours = (seconds / 3600.0) as i64;
            let minutes = ((seconds % 3600.0) / 60.0) as i64;
            return if minutes > 0 {
                format!("in {hours}h {minutes}m")
            } else {
                format!("in {hours}h")
            };
        }
        format!("in {}d", (seconds / 86_400.0).ceil() as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000;

    /// `tokensFormatting` — the compact suffixes and their trimming.
    #[test]
    fn tokens_formatting() {
        assert_eq!(TokenFormat::format(0), "0");
        assert_eq!(TokenFormat::format(850), "850");
        assert_eq!(TokenFormat::format(999), "999");
        assert_eq!(TokenFormat::format(1_000), "1k");
        assert_eq!(TokenFormat::format(42_300), "42.3k");
        assert_eq!(TokenFormat::format(10_000), "10k");
        assert_eq!(TokenFormat::format(1_250_000), "1.25m");
        assert_eq!(TokenFormat::format(1_000_000_000), "1b");
        assert_eq!(TokenFormat::format(3_600_000_000), "3.6b");
        assert_eq!(TokenFormat::format(1_100_000_000_000), "1.1t");
    }

    /// `relativeTimeBuckets` — each bucket and its rounding.
    #[test]
    fn relative_time_buckets() {
        assert_eq!(RelativeTime::format(NOW, NOW), "now");
        assert_eq!(RelativeTime::format(NOW - 60, NOW), "now");
        assert_eq!(RelativeTime::format(NOW + 45 * 60, NOW), "in 45m");
        // Seconds under a minute round up to 1m rather than showing "in 0m".
        assert_eq!(RelativeTime::format(NOW + 1, NOW), "in 1m");
        assert_eq!(RelativeTime::format(NOW + 3600, NOW), "in 1h");
        assert_eq!(RelativeTime::format(NOW + 3600 + 30 * 60, NOW), "in 1h 30m");
        assert_eq!(RelativeTime::format(NOW + 3 * 86_400, NOW), "in 3d");
        // Just under a day stays in hours, not "in 1d".
        assert_eq!(RelativeTime::format(NOW + 86_399, NOW), "in 23h 59m");
    }
}
