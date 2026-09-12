import Foundation
import Testing
@testable import BurnRate

struct TrendSeriesTests {
    private let now = Date()

    private func sample(
        _ provider: String,
        _ label: String,
        hoursAgo: Double,
        remaining: Double = 80
    ) -> RemainingSample {
        RemainingSample(
            provider: provider,
            label: label,
            date: now.addingTimeInterval(-hoursAgo * 3600),
            remaining: remaining
        )
    }

    @Test func cutoffIsTrailingWindow() {
        for (range, span) in [(ModelsView.Range.today, 24 * 3600.0), (.week, 7 * 86400.0), (.month, 30 * 86400.0)] {
            let cutoff = ModelsView.trendCutoff(for: range, now: now)
            #expect(abs(cutoff.timeIntervalSince(now.addingTimeInterval(-span))) < 0.001)
        }
    }

    @Test func axisLabelsShortenUnits() {
        #expect(ModelsView.axisLabel(850, metric: .tokens) == "850")
        #expect(ModelsView.axisLabel(2_500_000, metric: .tokens) == "2.5m")
        #expect(ModelsView.axisLabel(3_600_000_000, metric: .tokens) == "3.6b")
        #expect(ModelsView.axisLabel(0.5, metric: .cost) == "$0.5")
        #expect(ModelsView.axisLabel(2500, metric: .cost) == "$2.5k")
    }

    @Test func tickStrideFollowsRangeNotWindow() {
        #expect(ModelsView.trendXHourly(range: .today))
        #expect(!ModelsView.trendXHourly(range: .week))
        #expect(!ModelsView.trendXHourly(range: .month))
    }

    @Test func tickDatesAreMidnightsAndNoonsInSpan() {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: now).addingTimeInterval(-2 * 86400)
        let ticks = ModelsView.trendTickDates(cutoff: cutoff, now: now)
        #expect(!ticks.isEmpty)
        #expect(ticks == ticks.sorted())
        #expect(ticks.allSatisfy { $0 >= cutoff && $0 <= now })
        #expect(ticks.allSatisfy {
            let hour = cal.component(.hour, from: $0)
            return hour == 0 || hour == 12
        })
        // Each spanned day contributes its midnight; each full day a noon.
        let midnights = ticks.filter { cal.component(.hour, from: $0) == 0 }
        #expect(midnights.count == 3)
        #expect(ModelsView.trendTickLabel(cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!) == "12pm")
        #expect(ModelsView.trendTickLabel(midnights[0]) != "12pm")
    }

    @Test func tooltipPicksNearestPointPerSeries() {
        let series: [ModelsView.TrendSeries] = [
            (key: "Claude|Rolling", name: "Claude", provider: "Claude", scoped: false, samples: [
                (date: now.addingTimeInterval(-3600), remaining: 70),
                (date: now.addingTimeInterval(-1800), remaining: 68),
            ]),
            (key: "Empty|x", name: "Empty", provider: "Empty", scoped: false, samples: []),
        ]
        let rows = ModelsView.nearestRows(series: series, at: now.addingTimeInterval(-2000))
        #expect(rows.count == 1)
        #expect(rows[0].name == "Claude")
        #expect(rows[0].remaining == 68)
    }

    @Test func todayRangeDropsOlderPoints() {
        let samples = [
            sample("Claude", "Rolling", hoursAgo: 0.2, remaining: 70),
            sample("Claude", "Rolling", hoursAgo: 30, remaining: 90),
        ]
        let series = ModelsView.buildTrendSeries(
            samples: samples, label: "Rolling", providerFilter: nil,
            cutoff: ModelsView.trendCutoff(for: .today, now: now)
        )
        #expect(series.count == 1)
        #expect(series[0].samples.count == 1)
        #expect(series[0].samples[0].remaining == 70)
    }

    @Test func weekRangeKeepsDaysButDropsOlderWeeks() {
        let samples = [
            sample("Claude", "Weekly", hoursAgo: 72, remaining: 60),
            sample("Claude", "Weekly", hoursAgo: 240, remaining: 95),
        ]
        let series = ModelsView.buildTrendSeries(
            samples: samples, label: "Weekly", providerFilter: nil,
            cutoff: ModelsView.trendCutoff(for: .week, now: now)
        )
        #expect(series.count == 1)
        #expect(series[0].samples.map(\.remaining) == [60])
    }

    @Test func allOutOfRangeYieldsNoSeries() {
        let samples = [sample("Claude", "Rolling", hoursAgo: 30, remaining: 90)]
        let series = ModelsView.buildTrendSeries(
            samples: samples, label: "Rolling", providerFilter: nil,
            cutoff: ModelsView.trendCutoff(for: .today, now: now)
        )
        #expect(series.isEmpty)
    }

    @Test func scopedWeeklyFoldsIntoWeeklyGraph() {
        let samples = [
            sample("Claude", "Weekly", hoursAgo: 5, remaining: 60),
            sample("Claude", "Fable", hoursAgo: 5, remaining: 75),
        ]
        let series = ModelsView.buildTrendSeries(
            samples: samples, label: "Weekly", providerFilter: nil,
            cutoff: ModelsView.trendCutoff(for: .week, now: now)
        )
        #expect(series.count == 2)
        #expect(series.contains { $0.name == "Claude" && !$0.scoped })
        #expect(series.contains { $0.name == "Claude Fable" && $0.scoped })
    }

    @Test func providerFilterAppliesWithinRange() {
        let samples = [
            sample("Claude", "Rolling", hoursAgo: 1, remaining: 70),
            sample("OpenCode", "Rolling", hoursAgo: 1, remaining: 85),
        ]
        let series = ModelsView.buildTrendSeries(
            samples: samples, label: "Rolling", providerFilter: "OpenCode",
            cutoff: ModelsView.trendCutoff(for: .today, now: now)
        )
        #expect(series.count == 1)
        #expect(series[0].provider == "OpenCode")
    }
}
