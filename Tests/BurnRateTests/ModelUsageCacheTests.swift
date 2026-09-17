import BurnRateCore
import Foundation
import Testing
@testable import BurnRate

/// The Models view's persisted snapshot must not resurrect synthetic rows
/// written by older builds.
@MainActor
struct ModelUsageCacheTests {
    @Test func cachedSyntheticEntriesAreScrubbed() throws {
        let suite = UserDefaults(suiteName: "model-cache-\(UUID().uuidString)")!
        let synthetic = ModelUsageEntry(provider: "Claude", model: "<synthetic>", tokens: .zero,
                                        cost: 0, requests: 3, sourceTag: nil)
        let real = ModelUsageEntry(provider: "Claude", model: "claude-opus-5",
                                   tokens: TokenUsage(input: 5, output: 1, cacheRead: 0, cacheWrite: 0),
                                   cost: 0, requests: 1, sourceTag: nil)
        let cached = [DailyModelUsage(day: Date(), entries: [synthetic, real])]
        suite.set(try JSONEncoder().encode(cached), forKey: "modelUsageHistory")

        let viewModel = ModelUsageViewModel(sources: [], defaults: suite)
        let models = viewModel.daily.flatMap { $0.entries.map(\.model) }
        #expect(models == ["claude-opus-5"])
        #expect(viewModel.totals.count == 1)
    }

    @Test func daysWithOnlySyntheticEntriesAreDropped() throws {
        let suite = UserDefaults(suiteName: "model-cache-\(UUID().uuidString)")!
        let synthetic = ModelUsageEntry(provider: "Claude", model: "<synthetic>", tokens: .zero,
                                        cost: 0, requests: 1, sourceTag: nil)
        suite.set(try JSONEncoder().encode([DailyModelUsage(day: Date(), entries: [synthetic])]),
                  forKey: "modelUsageHistory")

        let viewModel = ModelUsageViewModel(sources: [], defaults: suite)
        #expect(viewModel.daily.isEmpty)
        #expect(viewModel.totals.isEmpty)
    }
}
