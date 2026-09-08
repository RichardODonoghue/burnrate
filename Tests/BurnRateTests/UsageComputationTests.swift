import Foundation
import Testing
@testable import BurnRate

struct UsageComputationTests {
    private func date(_ secondsAgo: Double, from now: Date) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    @Test func sumsOnlySamplesInsideWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let samples = [
            UsageSample(timestamp: date(60, from: now), tokens: .init(input: 100, output: 0, cacheRead: 0, cacheWrite: 0)),
            UsageSample(timestamp: date(4 * 3600, from: now), tokens: .init(input: 200, output: 0, cacheRead: 0, cacheWrite: 0)),
            UsageSample(timestamp: date(6 * 3600, from: now), tokens: .init(input: 999, output: 0, cacheRead: 0, cacheWrite: 0)),
        ]
        let windows = UsageComputation.windows(samples: samples, provider: "Claude", capacities: [:], now: now)
        let fiveHour = windows.first { $0.label == "5hr" }
        #expect(fiveHour?.tokensUsed == 300)
    }

    @Test func weightedTokensDiscountCacheReads() {
        let now = Date()
        // Raw: 12M total; weighted: 1M + 11M×0.1 = 2.1M
        let samples = [UsageSample(timestamp: now, tokens: .init(input: 1_000_000, output: 0, cacheRead: 11_000_000, cacheWrite: 0))]
        let windows = UsageComputation.windows(
            samples: samples,
            provider: "Claude",
            capacities: ["Claude|5hr": 4_200_000],
            now: now
        )
        let fiveHour = windows.first { $0.label == "5hr" }
        #expect(fiveHour?.percentRemaining == 50)
        #expect(fiveHour?.tokensUsed == 12_000_000)
    }

    @Test func percentUsesConfiguredCapacity() {
        let now = Date()
        let samples = [UsageSample(timestamp: now, tokens: .init(input: 250, output: 0, cacheRead: 0, cacheWrite: 0))]
        let windows = UsageComputation.windows(
            samples: samples,
            provider: "Claude",
            capacities: ["Claude|5hr": 1000],
            now: now
        )
        #expect(windows.first { $0.label == "5hr" }?.percentRemaining == 75)
    }

    @Test func percentNilWithoutCapacity() {
        let windows = UsageComputation.windows(samples: [], provider: "Codex", capacities: [:], now: Date())
        #expect(windows.allSatisfy { $0.percentRemaining == nil })
    }

    @Test func percentClampsAtZero() {
        let now = Date()
        let samples = [UsageSample(timestamp: now, tokens: .init(input: 2000, output: 0, cacheRead: 0, cacheWrite: 0))]
        let windows = UsageComputation.windows(
            samples: samples,
            provider: "Claude",
            capacities: ["Claude|5hr": 1000],
            now: now
        )
        #expect(windows.first { $0.label == "5hr" }?.percentRemaining == 0)
    }

    @Test func tokensFormatting() {
        #expect(StatusItemManager.formatTokens(850) == "850")
        #expect(StatusItemManager.formatTokens(42_300) == "42.3k")
        #expect(StatusItemManager.formatTokens(5_600_000) == "5.60M")
    }
}
