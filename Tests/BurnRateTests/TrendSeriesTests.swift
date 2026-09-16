import BurnRateCore
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
        for (range, span) in [(ChartRange.today, 24 * 3600.0), (.week, 7 * 86400.0), (.month, 30 * 86400.0)] {
            let cutoff = TrendChartData.trendCutoff(for: range, now: now)
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

    @Test func tickStyleFollowsVisibleSpanNotSelectedRange() {
        // A 7d range holding only an hour of data must still get hourly ticks.
        #expect(TrendChartData.trendXHourly(span: 3600))
        #expect(TrendChartData.trendXHourly(span: 2 * 86400))
        #expect(!TrendChartData.trendXHourly(span: 7 * 86400))
        #expect(!TrendChartData.trendXHourly(span: 30 * 86400))
    }

    @Test func hourlyStrideWidensWithSpan() {
        #expect(TrendChartData.trendHourStride(span: 2 * 3600) == 1)
        #expect(TrendChartData.trendHourStride(span: 12 * 3600) == 6)
        #expect(TrendChartData.trendHourStride(span: 2 * 86400) == 12)
    }

    @Test func xDomainShrinksToAvailableData() {
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        let series: [TrendSeries] = [
            ("Claude|Rolling", "Claude", "Claude", false,
             [(twoHoursAgo, 90), (now, 80)]),
        ]
        // Selected range is a week, but only two hours of data exist: the
        // domain spans the data (plus a sliver of lead-in), not the week.
        let domain = TrendChartData.trendXDomain(series: series, cutoff: now.addingTimeInterval(-7 * 86400), now: now)
        #expect(domain.upperBound == now)
        #expect(domain.lowerBound > now.addingTimeInterval(-3 * 3600))
        #expect(domain.lowerBound <= twoHoursAgo)
    }

    @Test func xDomainFallsBackToFullRangeWhenEmpty() {
        let cutoff = now.addingTimeInterval(-86400)
        let domain = TrendChartData.trendXDomain(series: [], cutoff: cutoff, now: now)
        #expect(domain.lowerBound == cutoff)
        #expect(domain.upperBound == now)
    }

    @Test func tickDatesAreMidnightsAndNoonsInSpan() {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: now).addingTimeInterval(-2 * 86400)
        let ticks = TrendChartData.trendTickDates(cutoff: cutoff, now: now)
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
        #expect(TrendChartData.trendTickLabel(cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!) == "12pm")
        #expect(TrendChartData.trendTickLabel(midnights[0]) != "12pm")
    }

    @Test func tooltipPicksNearestPointPerSeries() {
        let series: [TrendSeries] = [
            (key: "Claude|Rolling", name: "Claude", provider: "Claude", scoped: false, samples: [
                (date: now.addingTimeInterval(-3600), remaining: 70),
                (date: now.addingTimeInterval(-1800), remaining: 68),
            ]),
            (key: "Empty|x", name: "Empty", provider: "Empty", scoped: false, samples: []),
        ]
        let rows = TrendChartData.nearestRows(series: series, at: now.addingTimeInterval(-2000))
        #expect(rows.count == 1)
        #expect(rows[0].name == "Claude")
        #expect(rows[0].remaining == 68)
    }

    @Test func nearestPointBinarySearchesSortedSamples() {
        let base = now
        let samples = [
            (date: base, remaining: 100.0),
            (date: base.addingTimeInterval(600), remaining: 90),
            (date: base.addingTimeInterval(1200), remaining: 80),
        ]
        #expect(TrendChartData.nearestPoint(in: samples, to: base.addingTimeInterval(580))?.remaining == 90)
        #expect(TrendChartData.nearestPoint(in: samples, to: base.addingTimeInterval(-100))?.remaining == 100)
        #expect(TrendChartData.nearestPoint(in: samples, to: base.addingTimeInterval(10_000))?.remaining == 80)
        #expect(TrendChartData.nearestPoint(in: [], to: base) == nil)
    }

    @Test func todayRangeDropsOlderPoints() {
        let samples = [
            sample("Claude", "Rolling", hoursAgo: 0.2, remaining: 70),
            sample("Claude", "Rolling", hoursAgo: 30, remaining: 90),
        ]
        let series = TrendChartData.buildTrendSeries(
            samples: samples, label: "Rolling", providerFilter: nil,
            cutoff: TrendChartData.trendCutoff(for: .today, now: now)
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
        let series = TrendChartData.buildTrendSeries(
            samples: samples, label: "Weekly", providerFilter: nil,
            cutoff: TrendChartData.trendCutoff(for: .week, now: now)
        )
        #expect(series.count == 1)
        #expect(series[0].samples.map(\.remaining) == [60])
    }

    @Test func allOutOfRangeYieldsNoSeries() {
        let samples = [sample("Claude", "Rolling", hoursAgo: 30, remaining: 90)]
        let series = TrendChartData.buildTrendSeries(
            samples: samples, label: "Rolling", providerFilter: nil,
            cutoff: TrendChartData.trendCutoff(for: .today, now: now)
        )
        #expect(series.isEmpty)
    }

    @Test func scopedWeeklyFoldsIntoWeeklyGraph() {
        let samples = [
            sample("Claude", "Weekly", hoursAgo: 5, remaining: 60),
            sample("Claude", "Fable", hoursAgo: 5, remaining: 75),
        ]
        let series = TrendChartData.buildTrendSeries(
            samples: samples, label: "Weekly", providerFilter: nil,
            cutoff: TrendChartData.trendCutoff(for: .week, now: now)
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
        let series = TrendChartData.buildTrendSeries(
            samples: samples, label: "Rolling", providerFilter: "OpenCode",
            cutoff: TrendChartData.trendCutoff(for: .today, now: now)
        )
        #expect(series.count == 1)
        #expect(series[0].provider == "OpenCode")
    }

    // MARK: Autoscale

    private func series(_ values: [Double]) -> [TrendSeries] {
        [("p|x", "P", "P", false, values.map { (date: now, remaining: $0) })]
    }

    @Test func emptySeriesUsesFullDomain() {
        #expect(TrendChartData.remainingDomain([]) == 0...100)
    }

    @Test func narrowRangePadsAndTightensDomain() {
        // Data spans 78–82: pad 5 → 73…87, not 0…100 (which would look flat).
        let domain = TrendChartData.remainingDomain(series([82, 80, 78]))
        #expect(domain == 73...87)
    }

    @Test func domainClampsTo0And100() {
        #expect(TrendChartData.remainingDomain(series([2, 0, 1])).lowerBound == 0)
        #expect(TrendChartData.remainingDomain(series([99, 100])).upperBound == 100)
    }

    @Test func flatSeriesGetsAWindow() {
        let domain = TrendChartData.remainingDomain(series([50, 50, 50]))
        #expect(domain == 45...55)
        #expect(domain.lowerBound < 50 && domain.upperBound > 50)
    }

    @Test func yTicksStayInsideDomain() {
        // 73…87: decade would be a single line, so step 5 kicks in.
        #expect(TrendChartData.yTicks(in: 73...87) == [75, 80, 85])
        let decade = TrendChartData.yTicks(in: 30...70)
        #expect(decade == [30, 40, 50, 60, 70])
    }

    // MARK: Daily-chart tooltip lookup

    @Test func dayBucketMatchesOnlySameDay() {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: now)
        let buckets = [
            DailyModelUsage(day: day, entries: []),
            DailyModelUsage(day: cal.date(byAdding: .day, value: -1, to: day)!, entries: []),
        ]

        // Any instant inside the day resolves to its bucket.
        let noon = cal.date(byAdding: .hour, value: 12, to: day)!
        #expect(TrendChartData.dayBucket(for: noon, in: buckets, calendar: cal)?.day == day)

        // Empty space between bars (a different day) resolves to nothing.
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: day)!
        #expect(TrendChartData.dayBucket(for: twoDaysAgo, in: buckets, calendar: cal) == nil)
    }

    // MARK: Usage-card filters

    @Test func rollingCardHonorsProviderFilter() {
        let samples = [
            sample("Claude", "Rolling", hoursAgo: 2, remaining: 40),
            sample("Claude", "Rolling", hoursAgo: 1, remaining: 35),   // newest wins
            sample("OpenCode", "Rolling", hoursAgo: 1, remaining: 80),
            sample("Claude", "Weekly", hoursAgo: 1, remaining: 90),    // wrong window
        ]

        let unfiltered = TrendChartData.latestRolling(samples: samples, providerFilter: nil)
        #expect(unfiltered.count == 2)

        let claudeOnly = TrendChartData.latestRolling(samples: samples, providerFilter: "Claude")
        #expect(claudeOnly.count == 1)
        #expect(claudeOnly.first?.provider == "Claude")
        #expect(claudeOnly.first?.remaining == 35)

        #expect(TrendChartData.latestRolling(samples: samples, providerFilter: "Codex").isEmpty)
    }
}
