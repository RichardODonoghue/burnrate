import BurnRateCore
import Foundation
import Testing

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

    // MARK: Synthetic placeholder rows

    @Test func aggregatorSkipsSyntheticModels() {
        let buckets = [(provider: "Claude", samples: [
            sample("claude-opus-5", 100, minutesAgo: 5),
            sample("<synthetic>", 0, minutesAgo: 5),
        ])]
        let daily = ModelUsageAggregator.daily(buckets: buckets, days: 30, now: now)
        #expect(daily.allSatisfy { $0.entries.allSatisfy { $0.model != "<synthetic>" } })

        let totals = ModelUsageAggregator.totals(buckets: buckets)
        #expect(totals.count == 1)
        #expect(!totals.contains { $0.model == "<synthetic>" })
    }

    @Test func displayablePredicate() {
        #expect(ModelUsageAggregator.isDisplayable(model: "claude-opus-5"))
        #expect(ModelUsageAggregator.isDisplayable(model: nil))
        #expect(!ModelUsageAggregator.isDisplayable(model: "<synthetic>"))
    }

    // MARK: Sub-source tags (OpenCode Go vs Zen)
    private func taggedSample(_ model: String, tag: String, tokens: Int, minutesAgo: Double) -> UsageSample {
        UsageSample(
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            tokens: TokenUsage(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0),
            model: model,
            cost: nil,
            sourceTag: tag
        )
    }

    @Test func sameModelOnDifferentSourcesStaysSeparate() {
        let buckets = [(provider: "OpenCode", samples: [
            taggedSample("deepseek-v4-flash", tag: "opencode-go", tokens: 100, minutesAgo: 10),
            taggedSample("deepseek-v4-flash", tag: "opencode", tokens: 40, minutesAgo: 20),
        ])]
        let entries = ModelUsageAggregator.totals(buckets: buckets)
        #expect(entries.count == 2)
        #expect(entries.first { $0.sourceTag == "opencode-go" }?.totalTokens == 100)
        #expect(entries.first { $0.sourceTag == "opencode" }?.totalTokens == 40)
        // Distinct ids so SwiftUI lists and cache merges don't collide.
        #expect(Set(entries.map(\.id)).count == 2)
    }

    @Test func tagLabelsReadAsServices() {
        #expect(ModelUsageEntry.tagLabel(for: "opencode-go") == "Go")
        #expect(ModelUsageEntry.tagLabel(for: "opencode") == "Zen")
        #expect(ModelUsageEntry.tagLabel(for: "ollama") == "Ollama")
        #expect(ModelUsageEntry.tagLabel(for: "custom-thing") == "custom-thing")

        let entry = ModelUsageEntry(provider: "OpenCode", model: "deepseek-v4-flash", tokens: .zero,
                                    cost: 0, requests: 0, sourceTag: "opencode-go")
        #expect(entry.displayName == "deepseek-v4-flash · Go")

        // Untagged sources (Claude, Codex) keep their plain names.
        let plain = ModelUsageEntry(provider: "Claude", model: "claude-opus-5", tokens: .zero,
                                    cost: 0, requests: 0, sourceTag: nil)
        #expect(plain.displayName == "claude-opus-5")
        #expect(plain.tagLabel == nil)
    }

    @Test func reasoningTokensCountTowardTotals() {
        let samples = [
            UsageSample(
                timestamp: now.addingTimeInterval(-60),
                tokens: TokenUsage(input: 100, output: 10, cacheRead: 0, cacheWrite: 0, reasoning: 40),
                model: "deepseek-v4-flash",
                cost: nil,
                sourceTag: "opencode-go"
            )
        ]
        let entries = ModelUsageAggregator.totals(buckets: [("OpenCode", samples)])
        #expect(entries.first?.tokens.reasoning == 40)
        #expect(entries.first?.totalTokens == 150)
    }

    @Test func legacyTokenUsageDecodesWithoutReasoning() throws {
        // Samples were persisted before `reasoning` existed.
        let json = #"{"input":10,"output":2,"cacheRead":3,"cacheWrite":4}"#
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(decoded.reasoning == 0)
        #expect(decoded.total == 19)
    }
}

struct ModelUsageTotalsTests {
    private let now = Date()

    private func entry(_ model: String, input: Int, cost: Double, requests: Int) -> ModelUsageEntry {
        ModelUsageEntry(provider: "P", model: model,
                        tokens: TokenUsage(input: input, output: 0, cacheRead: 0, cacheWrite: 0),
                        cost: cost, requests: requests, sourceTag: nil)
    }

    @Test func totalsFromDailyMergesAcrossDays() {
        let daily = [
            DailyModelUsage(day: now, entries: [entry("m", input: 100, cost: 1, requests: 1)]),
            DailyModelUsage(day: now.addingTimeInterval(-86400),
                            entries: [entry("m", input: 50, cost: 0.5, requests: 2)]),
        ]
        let totals = ModelUsageAggregator.totals(fromDaily: daily)
        #expect(totals.count == 1)
        #expect(totals[0].totalTokens == 150)
        #expect(totals[0].requests == 3)
        #expect(abs(totals[0].cost - 1.5) < 0.0001)
    }

    @Test func totalsFromDailyKeepsSeparateModels() {
        let daily = [
            DailyModelUsage(day: now, entries: [
                entry("a", input: 10, cost: 0, requests: 1),
                entry("b", input: 20, cost: 0, requests: 1),
            ]),
        ]
        #expect(ModelUsageAggregator.totals(fromDaily: daily).count == 2)
    }
}
