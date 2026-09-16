import Foundation

/// Token counts for one usage event.
public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Reasoning/thinking tokens. Providers that report these separately
    /// (OpenCode's DeepSeek et al.) exclude them from `output` — confirmed
    /// against rows where reasoning > output.
    public var reasoning: Int = 0

    public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    // `reasoning` was added after samples were first persisted (Claude's
    // incremental cache), so decode older payloads without it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(Int.self, forKey: .input)
        output = try container.decode(Int.self, forKey: .output)
        cacheRead = try container.decode(Int.self, forKey: .cacheRead)
        cacheWrite = try container.decode(Int.self, forKey: .cacheWrite)
        reasoning = try container.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0
    }

    public static var zero: TokenUsage { TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0) }

    public var total: Int { input + output + cacheRead + cacheWrite + reasoning }

    /// Cache-discounted tokens (Anthropic-style billing weights): cache reads
    /// count 0.1x, cache writes 1.25x. Use this for plan-limit %.
    public var weighted: Double {
        Double(input) + Double(output) + Double(reasoning)
            + Double(cacheRead) * 0.1 + Double(cacheWrite) * 1.25
    }
}

/// One usage event: tokens consumed at a point in time.
public struct UsageSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let tokens: TokenUsage
    /// Vendor request identifier, when present (Claude). Used to dedupe
    /// repeated log lines for the same request.
    public var requestId: String?
    /// Model identifier when the source records it (e.g. "claude-opus-5").
    public var model: String?
    /// Vendor-reported cost in USD when available (OpenCode only).
    public var cost: Double?
    /// Sub-source within a multi-provider source. OpenCode records the
    /// upstream provider here: "opencode-go" (Go), "opencode" (Zen),
    /// "ollama"/"lmstudio"/"omlx" (local runtimes).
    public var sourceTag: String?

    public init(
        timestamp: Date,
        tokens: TokenUsage,
        requestId: String? = nil,
        model: String? = nil,
        cost: Double? = nil,
        sourceTag: String? = nil
    ) {
        self.timestamp = timestamp
        self.tokens = tokens
        self.requestId = requestId
        self.model = model
        self.cost = cost
        self.sourceTag = sourceTag
    }
}

/// Aggregated usage for one plan window (Rolling / Weekly / Monthly).
public struct UsageWindow: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    /// Raw tokens (all cache traffic included) — informational display,
    /// verified by tests.
    public let tokensUsed: Int
    /// nil when the user has not configured a plan capacity for this window.
    public let percentRemaining: Double?
    /// When the window resets (provider APIs supply this; local parsing can't).
    public let resetsAt: Date?

    public init(id: String, label: String, tokensUsed: Int, percentRemaining: Double?, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.tokensUsed = tokensUsed
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
    }
}

/// Latest usage for one provider.
public struct ProviderUsage: Equatable, Sendable {
    public let providerName: String
    /// Vendor plan tier when known (e.g. "Team 5x", "Max 20x", "Go").
    public let plan: String?
    public let windows: [UsageWindow]

    public init(providerName: String, plan: String?, windows: [UsageWindow]) {
        self.providerName = providerName
        self.plan = plan
        self.windows = windows
    }

    public func window(withLabel label: String) -> UsageWindow? {
        windows.first { $0.label == label }
    }
}

/// Maps usage samples onto rolling plan windows and computes % remaining
/// against user-configured capacities.
public enum UsageComputation {
    static let windowSpecs: [(label: String, seconds: TimeInterval)] = [
        ("Rolling", 5 * 3600),
        ("Weekly", 7 * 86400),
        ("Monthly", 30 * 86400),
    ]

    public static func windows(
        samples: [UsageSample],
        provider: String,
        capacities: [String: Int],
        now: Date = Date()
    ) -> [UsageWindow] {
        windowSpecs.map { spec in
            let cutoff = now.addingTimeInterval(-spec.seconds)
            let inWindow = samples.filter { $0.timestamp >= cutoff }
            let rawUsed = inWindow.reduce(0) { $0 + $1.tokens.total }
            // Capacities are measured in weighted tokens (cache read ×0.1,
            // write ×1.25) — raw cache traffic would blow past any capacity.
            let weightedUsed = inWindow.reduce(0.0) { $0 + $1.tokens.weighted }
            let capacity = capacities["\(provider)|\(spec.label)"] ?? 0
            let percent: Double? = capacity > 0
                ? max(0, 100 * (1 - weightedUsed / Double(capacity)))
                : nil
            return UsageWindow(
                id: "\(provider)-\(spec.label)",
                label: spec.label,
                tokensUsed: rawUsed,
                percentRemaining: percent,
                resetsAt: nil
            )
        }
    }
}
