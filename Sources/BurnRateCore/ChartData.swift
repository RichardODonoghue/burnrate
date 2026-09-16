import Foundation

/// One point of vendor-reported remaining-% history for a plan window.
public struct RemainingSample: Codable, Equatable, Sendable {
    public let provider: String
    public let label: String
    public let date: Date
    public let remaining: Double

    public init(provider: String, label: String, date: Date, remaining: Double) {
        self.provider = provider
        self.label = label
        self.date = date
        self.remaining = remaining
    }
}

/// Trailing time windows the dashboard can show.
public enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case today = "24h", week = "7d", month = "30d"

    public var id: String { rawValue }

    /// Trailing window behind "now" — ranges are rolling, not calendar.
    public var span: TimeInterval {
        switch self {
        case .today: 24 * 3600
        case .week: 7 * 86400
        case .month: 30 * 86400
        }
    }
}

/// One line on the remaining-over-time chart. A provider can contribute
/// several series (Claude Weekly + Claude Fable); scoped weeklies are drawn
/// dashed and faded by the UI.
public typealias TrendSeries = (
    key: String, name: String, provider: String, scoped: Bool,
    samples: [(date: Date, remaining: Double)]
)

/// Platform-independent chart data: windowing, domains, ticks and hover
/// lookups. The UI layer only turns these into pixels, so a GTK/Direct2D
/// front-end reuses all of it.
public enum TrendChartData {
    /// Model-scoped quotas (Fable today) come from weekly_scoped kinds, so
    /// they chart on the Weekly graph. Anything outside the three known
    /// windows belongs to Weekly.
    public static func canonicalTrendLabel(_ label: String) -> String {
        switch label {
        case "Rolling", "Weekly", "Monthly": label
        default: "Weekly"
        }
    }

    /// Trailing start of the visible span for the range filter.
    public static func trendCutoff(for range: ChartRange, now: Date) -> Date {
        now.addingTimeInterval(-range.span)
    }

    /// Per-provider series for a window over the visible range.
    public static func buildTrendSeries(
        samples: [RemainingSample],
        label: String,
        providerFilter: String?,
        cutoff: Date
    ) -> [TrendSeries] {
        let filtered = samples.filter {
            canonicalTrendLabel($0.label) == label
                && (providerFilter == nil || $0.provider == providerFilter)
                && $0.date >= cutoff
        }
        let dict = Dictionary(grouping: filtered, by: { "\($0.provider)|\($0.label)" })
        return dict.keys.sorted().map { key in
            let points = dict[key]!.sorted { $0.date < $1.date }
            let provider = points[0].provider
            let pointLabel = points[0].label
            let scoped = pointLabel != label
            let name = scoped ? "\(provider) \(pointLabel)" : provider
            return (key, name, provider, scoped,
                    points.map { (date: $0.date, remaining: $0.remaining) })
        }
    }

    /// X-axis tick style follows the *visible* span, so a chart scaled down to
    /// a few hours of data gets hourly ticks even in a 7d range.
    public static func trendXHourly(span: TimeInterval) -> Bool {
        span < 3 * 86400
    }

    /// Hourly gridline stride for a span: 1h when zoomed in, 6h for a couple
    /// of days, 12h beyond.
    public static func trendHourStride(span: TimeInterval) -> Int {
        switch span {
        case ..<(6 * 3600): return 1
        case ..<(36 * 3600): return 6
        default: return 12
        }
    }

    /// The X domain for the trend chart. Scales down to the data actually
    /// available: with only an hour of history in a 7-day range, the plot
    /// spans that hour instead of leaving 6.9 empty days. Empty series fall
    /// back to the full selected range.
    public static func trendXDomain(
        series: [TrendSeries],
        cutoff: Date,
        now: Date
    ) -> ClosedRange<Date> {
        let dates = series.flatMap { $0.samples.map(\.date) }
        guard let earliest = dates.min(), let latest = dates.max() else {
            return cutoff...now
        }
        // A little lead-in so the first point isn't glued to the edge.
        let span = max(latest.timeIntervalSince(earliest), 60)
        let lower = max(cutoff, earliest.addingTimeInterval(-span * 0.02))
        let upper = max(now, latest)
        let minimumSpan: TimeInterval = 5 * 60
        guard upper.timeIntervalSince(lower) >= minimumSpan else {
            return lower...(lower.addingTimeInterval(minimumSpan))
        }
        return lower...upper
    }

    /// Midnight + noon ticks across the visible span (7d/30d ranges).
    /// Explicit dates (not a stride) so ticks land exactly on 00:00/12:00.
    public static func trendTickDates(
        cutoff: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        var ticks: [Date] = []
        var day = calendar.startOfDay(for: cutoff)
        while day <= now {
            if day >= cutoff { ticks.append(day) }
            if let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day),
               noon >= cutoff && noon <= now {
                ticks.append(noon)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ticks.sorted()
    }

    /// Midnight ticks read as the weekday, noon ticks as 12pm.
    public static func trendTickLabel(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.component(.hour, from: date) == 12 { return "12pm" }
        // `shortWeekdaySymbols` avoids `Date.FormatStyle`, which is not
        // available in swift-corelibs-foundation on Linux.
        let weekday = calendar.component(.weekday, from: date)
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }

    /// Nearest point per series to the hovered date, for a tooltip.
    public static func nearestRows(
        series: [TrendSeries],
        at date: Date
    ) -> [(name: String, provider: String, scoped: Bool, remaining: Double)] {
        series.compactMap { s in
            guard let point = nearestPoint(in: s.samples, to: date) else { return nil }
            return (s.name, s.provider, s.scoped, point.remaining)
        }
    }

    /// Nearest sample to `date` in a date-sorted series. Binary search: a
    /// tooltip tracks the pointer, and a linear scan per hover event over
    /// thousands of points is wasteful.
    public static func nearestPoint(
        in samples: [(date: Date, remaining: Double)],
        to date: Date
    ) -> (date: Date, remaining: Double)? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date { low = mid + 1 } else { high = mid }
        }
        // `low` is the first index at or after `date`; compare with its neighbour.
        let candidate = samples[low]
        guard low > 0 else { return candidate }
        let previous = samples[low - 1]
        return abs(previous.date.timeIntervalSince(date)) <= abs(candidate.date.timeIntervalSince(date))
            ? previous
            : candidate
    }

    /// Day bucket containing `date`. Bars span whole days, so hovering empty
    /// space between them must not pop a tooltip.
    public static func dayBucket(
        for date: Date,
        in days: [DailyModelUsage],
        calendar: Calendar = .current
    ) -> DailyModelUsage? {
        days.first { calendar.isDate($0.day, inSameDayAs: date) }
    }

    /// Auto-scaled Y domain for the trend chart: spans the visible data plus
    /// padding so lines aren't flattened when the range is narrow, clamped to
    /// 0…100 elsewhere. Empty series → full domain.
    public static func remainingDomain(_ series: [TrendSeries]) -> ClosedRange<Double> {
        let values = series.flatMap { $0.samples.map(\.remaining) }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let pad = max((high - low) * 0.15, 5)
        let lower = max(0, (low - pad).rounded(.down))
        let upper = min(100, (high + pad).rounded(.up))
        guard lower < upper else { return lower == 0 ? 0...10 : (lower - 10)...lower }
        return lower...upper
    }

    /// Gridline values at multiples of 10 inside the domain (5 when that
    /// would leave fewer than three lines).
    public static func yTicks(in domain: ClosedRange<Double>) -> [Double] {
        for step in [10.0, 5.0] {
            let ticks = stride(from: (domain.lowerBound / step).rounded(.up) * step,
                               through: domain.upperBound, by: step)
                .map { ($0 / step).rounded() * step }
                .filter { $0 >= domain.lowerBound && $0 <= domain.upperBound }
            if ticks.count >= 3 { return ticks }
        }
        return [domain.lowerBound, domain.upperBound]
    }

    /// Latest vendor-reported Rolling remaining % per provider, honoring the
    /// provider filter.
    public static func latestRolling(
        samples: [RemainingSample],
        providerFilter: String?
    ) -> [(provider: String, remaining: Double)] {
        var latest: [String: (date: Date, remaining: Double)] = [:]
        for sample in samples
        where sample.label == "Rolling" && (providerFilter == nil || sample.provider == providerFilter) {
            if let current = latest[sample.provider] {
                if sample.date > current.date { latest[sample.provider] = (sample.date, sample.remaining) }
            } else {
                latest[sample.provider] = (sample.date, sample.remaining)
            }
        }
        return latest.map { (provider: $0.key, remaining: $0.value.remaining) }
            .sorted { $0.remaining < $1.remaining }
    }
}
