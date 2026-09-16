import Foundation

// MARK: - Aggregation

/// Usage totals for one (provider, model[, sub-source]) triple.
public struct ModelUsageEntry: Identifiable, Codable, Equatable, Sendable {
    public var provider: String
    public var model: String
    public var tokens: TokenUsage
    public var cost: Double
    public var requests: Int
    /// Sub-source tag (OpenCode's providerID: "opencode-go", "opencode", …).
    public var sourceTag: String?

    public init(
        provider: String,
        model: String,
        tokens: TokenUsage,
        cost: Double,
        requests: Int,
        sourceTag: String?
    ) {
        self.provider = provider
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.requests = requests
        self.sourceTag = sourceTag
    }

    public var id: String {
        sourceTag.map { "\(provider)|\($0)|\(model)" } ?? "\(provider)|\(model)"
    }
    public var totalTokens: Int { tokens.total }

    /// Friendly sub-source name: "Go", "Zen", "Ollama", "LM Studio", "OMLX".
    public var tagLabel: String? { sourceTag.map(Self.tagLabel(for:)) }

    /// Model name, qualified by the sub-source when there is one — Go's
    /// models and Zen's are distinct services and must read differently.
    public var displayName: String { tagLabel.map { "\(model) · \($0)" } ?? model }

    public static func tagLabel(for tag: String) -> String {
        switch tag {
        case "opencode-go": "Go"
        case "opencode": "Zen"
        case "ollama": "Ollama"
        case "lmstudio": "LM Studio"
        case "omlx": "OMLX"
        default: tag
        }
    }
}

/// One day of per-model usage (day is local start-of-day).
public struct DailyModelUsage: Codable, Equatable, Sendable {
    public var day: Date
    public var entries: [ModelUsageEntry]

    public init(day: Date, entries: [ModelUsageEntry]) {
        self.day = day
        self.entries = entries
    }
}

public enum ModelUsageAggregator {
    /// Claude Code emits zero-usage placeholder turns with model
    /// "<synthetic>"; they are not a model and must never be counted or
    /// listed, including when they arrive from a persisted snapshot.
    public static func isDisplayable(model: String?) -> Bool {
        guard let model else { return true }
        return model != "<synthetic>"
    }

    /// Buckets samples into per-day per-model totals over the trailing
    /// `days`, merging across providers.
    public static func daily(
        buckets: [(provider: String, samples: [UsageSample])],
        days: Int,
        now: Date = Date()
    ) -> [DailyModelUsage] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 86400))
        var byDay: [Date: [String: ModelUsageEntry]] = [:]
        for bucket in buckets {
            for sample in bucket.samples where sample.timestamp >= start {
                guard isDisplayable(model: sample.model) else { continue }
                let day = calendar.startOfDay(for: sample.timestamp)
                let key = entryKey(provider: bucket.provider, sample: sample)
                var entry = byDay[day]?[key] ?? makeEntry(provider: bucket.provider, sample: sample)
                add(sample, to: &entry)
                byDay[day, default: [:]][key] = entry
            }
        }
        return byDay
            .map { DailyModelUsage(day: $0.key, entries: $0.value.map(\.value).sorted { $0.totalTokens > $1.totalTokens }) }
            .sorted { $0.day < $1.day }
    }

    /// Flat totals over all provided samples, sorted by tokens.
    public static func totals(buckets: [(provider: String, samples: [UsageSample])]) -> [ModelUsageEntry] {
        var byKey: [String: ModelUsageEntry] = [:]
        for bucket in buckets {
            for sample in bucket.samples where isDisplayable(model: sample.model) {
                let key = entryKey(provider: bucket.provider, sample: sample)
                var entry = byKey[key] ?? makeEntry(provider: bucket.provider, sample: sample)
                add(sample, to: &entry)
                byKey[key] = entry
            }
        }
        return byKey.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Flat totals rebuilt from day buckets (instant display, range filters).
    public static func totals(fromDaily daily: [DailyModelUsage]) -> [ModelUsageEntry] {
        var byKey: [String: ModelUsageEntry] = [:]
        for day in daily {
            for entry in day.entries {
                guard var merged = byKey[entry.id] else {
                    byKey[entry.id] = entry
                    continue
                }
                merged.tokens.input += entry.tokens.input
                merged.tokens.output += entry.tokens.output
                merged.tokens.cacheRead += entry.tokens.cacheRead
                merged.tokens.cacheWrite += entry.tokens.cacheWrite
                merged.tokens.reasoning += entry.tokens.reasoning
                merged.cost += entry.cost
                merged.requests += entry.requests
                byKey[entry.id] = merged
            }
        }
        return byKey.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    // MARK: - Shared accumulation

    private static func entryKey(provider: String, sample: UsageSample) -> String {
        let model = sample.model ?? "unknown"
        return sample.sourceTag.map { "\(provider)|\($0)|\(model)" } ?? "\(provider)|\(model)"
    }

    private static func makeEntry(provider: String, sample: UsageSample) -> ModelUsageEntry {
        ModelUsageEntry(provider: provider, model: sample.model ?? "unknown",
                        tokens: .zero, cost: 0, requests: 0, sourceTag: sample.sourceTag)
    }

    private static func add(_ sample: UsageSample, to entry: inout ModelUsageEntry) {
        entry.tokens.input += sample.tokens.input
        entry.tokens.output += sample.tokens.output
        entry.tokens.cacheRead += sample.tokens.cacheRead
        entry.tokens.cacheWrite += sample.tokens.cacheWrite
        entry.tokens.reasoning += sample.tokens.reasoning
        entry.cost += sample.cost ?? PricingService.shared.cost(of: sample)
        entry.requests += 1
    }
}
