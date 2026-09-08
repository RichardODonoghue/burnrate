import Foundation
import Testing
@testable import BurnRate

struct ModelUsageTests {
    private let now = Date()
    private func sample(_ model: String?, _ tokens: Int, minutesAgo: Double, cost: Double? = nil) -> UsageSample {
        UsageSample(
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            tokens: TokenUsage(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0),
            model: model,
            cost: cost
        )
    }

    @Test func aggregatesPerDayPerModel() {
        let yesterday = -60.0 * 60 * 26 // 26h ago → previous local day
        let buckets = [(provider: "OpenCode", samples: [
            sample("grok-4.6", 100, minutesAgo: 10, cost: 0.5),
            sample("grok-4.6", 200, minutesAgo: 20, cost: 1.0),
            sample("kimi-k3", 50, minutesAgo: 15),
            sample("grok-4.6", 400, minutesAgo: yesterday, cost: 2.0),
        ])]
        let daily = ModelUsageAggregator.daily(buckets: buckets, days: 30, now: now)
        #expect(daily.count == 2)

        let today = daily.first { Calendar.current.isDateInToday($0.day) }
        #expect(today?.entries.count == 2)
        let grok = today?.entries.first { $0.model == "grok-4.6" }
        #expect(grok?.totalTokens == 300)
        #expect(grok?.cost == 1.5)
        #expect(grok?.requests == 2)
    }

    @Test func totalsMergeAcrossDays() {
        let yesterday = -60.0 * 60 * 26
        let buckets = [(provider: "OpenCode", samples: [
            sample("grok-4.6", 100, minutesAgo: 10),
            sample("grok-4.6", 400, minutesAgo: yesterday),
        ])]
        let totals = ModelUsageAggregator.totals(buckets: buckets)
        #expect(totals.count == 1)
        #expect(totals[0].totalTokens == 500)
    }

    @Test func samplesWithoutModelGroupAsUnknown() {
        let buckets = [(provider: "Claude", samples: [sample(nil, 100, minutesAgo: 5)])]
        let totals = ModelUsageAggregator.totals(buckets: buckets)
        #expect(totals[0].model == "unknown")
    }

    @Test func modelBurnDetectsSpikingModel() {
        let alert = ModelBurnAlert(provider: "Claude", model: "opus", tokens: 1_000_000, minutes: 30)
        let samples = [
            sample("claude-opus-5", 900_000, minutesAgo: 20),
            sample("claude-haiku-4", 500_000, minutesAgo: 10),
            sample("claude-opus-5", 300_000, minutesAgo: 5),
        ]
        let hit = ModelBurnEvaluator.detect(samples: samples, alert: alert, now: now, pollInterval: 300)
        #expect(hit?.model == "claude-opus-5")
        #expect(hit?.tokens == 1_200_000)
    }

    @Test func modelBurnIgnoresOutsideWindow() {
        let alert = ModelBurnAlert(provider: "Claude", model: "*", tokens: 1_000_000, minutes: 30)
        let samples = [sample("claude-opus-5", 2_000_000, minutesAgo: 90)]
        #expect(ModelBurnEvaluator.detect(samples: samples, alert: alert, now: now, pollInterval: 300) == nil)
    }

    @Test func modelBurnWildcardMatchesAnyModel() {
        let alert = ModelBurnAlert(provider: "Claude", model: "*", tokens: 800_000, minutes: 30)
        let samples = [sample("claude-haiku-4", 900_000, minutesAgo: 5)]
        #expect(ModelBurnEvaluator.detect(samples: samples, alert: alert, now: now, pollInterval: 300) != nil)
    }
}
