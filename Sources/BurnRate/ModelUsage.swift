import Foundation

// MARK: - Aggregation

/// Usage totals for one (provider, model) pair.
struct ModelUsageEntry: Identifiable, Codable, Equatable {
    var provider: String
    var model: String
    var tokens: TokenUsage
    var cost: Double
    var requests: Int

    var id: String { "\(provider)|\(model)" }
    var totalTokens: Int { tokens.total }
}

/// One day of per-model usage (day is local start-of-day).
struct DailyModelUsage: Codable, Equatable {
    var day: Date
    var entries: [ModelUsageEntry]
}

enum ModelUsageAggregator {
    /// Buckets samples into per-day per-model totals over the trailing
    /// `days`, merging across providers.
    static func daily(
        buckets: [(provider: String, samples: [UsageSample])],
        days: Int,
        now: Date = Date()
    ) -> [DailyModelUsage] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 86400))
        var byDay: [Date: [String: ModelUsageEntry]] = [:]
        for bucket in buckets {
            for sample in bucket.samples where sample.timestamp >= start {
                let day = calendar.startOfDay(for: sample.timestamp)
                let model = sample.model ?? "unknown"
                let key = "\(bucket.provider)|\(model)"
                var entry = byDay[day]?[key]
                    ?? ModelUsageEntry(provider: bucket.provider, model: model, tokens: .zero, cost: 0, requests: 0)
                entry.tokens.input += sample.tokens.input
                entry.tokens.output += sample.tokens.output
                entry.tokens.cacheRead += sample.tokens.cacheRead
                entry.tokens.cacheWrite += sample.tokens.cacheWrite
                entry.cost += sample.cost ?? PricingService.shared.cost(of: sample)
                entry.requests += 1
                byDay[day, default: [:]][key] = entry
            }
        }
        return byDay
            .map { DailyModelUsage(day: $0.key, entries: $0.value.map(\.value).sorted { $0.totalTokens > $1.totalTokens }) }
            .sorted { $0.day < $1.day }
    }

    /// Flat totals over all provided samples, sorted by tokens.
    static func totals(buckets: [(provider: String, samples: [UsageSample])]) -> [ModelUsageEntry] {
        var byKey: [String: ModelUsageEntry] = [:]
        for bucket in buckets {
            for sample in bucket.samples {
                let model = sample.model ?? "unknown"
                let key = "\(bucket.provider)|\(model)"
                var entry = byKey[key]
                    ?? ModelUsageEntry(provider: bucket.provider, model: model, tokens: .zero, cost: 0, requests: 0)
                entry.tokens.input += sample.tokens.input
                entry.tokens.output += sample.tokens.output
                entry.tokens.cacheRead += sample.tokens.cacheRead
                entry.tokens.cacheWrite += sample.tokens.cacheWrite
                entry.cost += sample.cost ?? PricingService.shared.cost(of: sample)
                entry.requests += 1
                byKey[key] = entry
            }
        }
        return byKey.values.sorted { $0.totalTokens > $1.totalTokens }
    }
}

// MARK: - Model burn detection

/// Alert when one model consumes more than `tokens` within a trailing
/// `minutes` window (from local logs).
struct ModelBurnAlert: Codable, Identifiable, Hashable {
    var provider: String
    var model: String
    var tokens: Int
    var minutes: Int

    var id: String { key }
    var key: String { "\(provider)|\(model)|\(tokens)|\(minutes)" }
}

enum ModelBurnEvaluator {
    /// The first model exceeding its alert threshold within the trailing
    /// window, else nil. Tokens are summed across all samples in-window.
    static func detect(
        samples: [UsageSample],
        alert: ModelBurnAlert,
        now: Date,
        pollInterval: TimeInterval
    ) -> (model: String, tokens: Int)? {
        let start = now.addingTimeInterval(-Double(alert.minutes) * 60 - pollInterval / 2)
        var perModel: [String: Int] = [:]
        for sample in samples where sample.timestamp >= start {
            perModel[sample.model ?? "unknown", default: 0] += sample.tokens.total
        }
        for (model, tokens) in perModel.sorted(by: { $0.value > $1.value })
        where tokens >= alert.tokens && modelMatches(alert.model, model) {
            return (model, tokens)
        }
        return nil
    }

    private static func modelMatches(_ pattern: String, _ model: String) -> Bool {
        pattern == "*" || model.lowercased().contains(pattern.lowercased())
    }
}
