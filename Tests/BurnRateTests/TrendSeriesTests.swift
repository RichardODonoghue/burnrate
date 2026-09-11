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

    @Test func cutoffSpansRangeInWholeDays() {
        let cal = Calendar.current
        for (range, days) in [(ModelsView.Range.today, 0), (.week, 6), (.month, 29)] {
            let cutoff = ModelsView.trendCutoff(for: range, now: now)
            #expect(cal.component(.hour, from: cutoff) == 0)
            #expect(cal.dateComponents([.day], from: cutoff, to: cal.startOfDay(for: now)).day == days)
        }
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
