import Foundation

/// Token counts for one usage event.
struct TokenUsage: Equatable {
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    static var zero: TokenUsage { TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0) }

    var total: Int { input + output + cacheRead + cacheWrite }

    /// Cache-discounted tokens (Anthropic-style billing weights): cache reads
    /// count 0.1x, cache writes 1.25x. Use this for plan-limit %.
    var weighted: Double {
        Double(input) + Double(output) + Double(cacheRead) * 0.1 + Double(cacheWrite) * 1.25
    }
}

/// One usage event: tokens consumed at a point in time.
struct UsageSample: Equatable {
    let timestamp: Date
    let tokens: TokenUsage
}

/// Aggregated usage for one plan window (5hr / Weekly / Monthly).
struct UsageWindow: Equatable, Identifiable {
    let id: String
    let label: String
    /// Raw tokens (all cache traffic included) — informational display.
    let tokensUsed: Int
    /// Cache-discounted tokens — the unit plan capacities are measured in.
    let weightedUsed: Double
    /// nil when the user has not configured a plan capacity for this window.
    let percentRemaining: Double?
    /// When the window resets (provider APIs supply this; local parsing can't).
    let resetsAt: Date?
}

/// Latest usage for one provider.
struct ProviderUsage: Equatable {
    let providerName: String
    /// Vendor plan tier when known (e.g. "Team 5x", "Max 20x", "Go").
    let plan: String?
    let windows: [UsageWindow]

    func window(withLabel label: String) -> UsageWindow? {
        windows.first { $0.label == label }
    }
}

/// Maps usage samples onto rolling plan windows and computes % remaining
/// against user-configured capacities.
enum UsageComputation {
    static let windowSpecs: [(label: String, seconds: TimeInterval)] = [
        ("5hr", 5 * 3600),
        ("Weekly", 7 * 86400),
        ("Monthly", 30 * 86400),
    ]

    static func windows(
        samples: [UsageSample],
        provider: String,
        capacities: [String: Int],
        now: Date = Date()
    ) -> [UsageWindow] {
        windowSpecs.map { spec in
            let cutoff = now.addingTimeInterval(-spec.seconds)
            let inWindow = samples.filter { $0.timestamp >= cutoff }
            let rawUsed = inWindow.reduce(0) { $0 + $1.tokens.total }
            let weightedUsed = inWindow.reduce(0.0) { $0 + $1.tokens.weighted }
            let capacity = capacities["\(provider)|\(spec.label)"] ?? 0
            let percent: Double? = capacity > 0
                ? max(0, 100 * (1 - weightedUsed / Double(capacity)))
                : nil
            return UsageWindow(
                id: "\(provider)-\(spec.label)",
                label: spec.label,
                tokensUsed: rawUsed,
                weightedUsed: weightedUsed,
                percentRemaining: percent,
                resetsAt: nil
            )
        }
    }
}
