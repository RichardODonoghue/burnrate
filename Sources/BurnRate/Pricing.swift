import Foundation

/// Per-token USD costs for one model.
struct ModelPricing: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?
}

/// Model pricing from LiteLLM's public table (same source tokscale uses),
/// cached on disk and refreshed every 24h. Used to estimate cost for
/// providers that don't report it (Claude logs have costUSD null).
final class PricingService: @unchecked Sendable {
    static let shared = PricingService()

    nonisolated static let pricingURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    nonisolated static let refreshInterval: TimeInterval = 24 * 3600

    private var table: [String: ModelPricing] = [:]
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private let lock = NSLock()
    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BurnRate/pricing.json")
        loadCache()
    }

    func bootstrap() {
        Task { await refreshIfNeeded() }
    }

    func refreshIfNeeded(now: Date = Date()) async {
        let task: Task<Void, Never>? = lock.withLock {
            var due = false
            if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.refreshInterval {
                due = false
            } else {
                due = true
                lastRefresh = now
            }
            if due && refreshTask == nil {
                let newTask = Task { await self.refreshFromNetwork() }
                refreshTask = newTask
                return newTask
            }
            return refreshTask
        }
        if let task { await task.value }
    }

    private func refreshFromNetwork() async {
        do {
            var request = URLRequest(url: Self.pricingURL)
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try Self.parse(data)
            setTable(decoded)
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL)
        } catch {
            // Keep whatever cache we loaded; estimation just stays partial.
        }
    }

    private func setTable(_ newTable: [String: ModelPricing]) {
        lock.withLock { table = newTable }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        setTable((try? Self.parse(data)) ?? [:])
        lastRefresh = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
    }

    // MARK: - Lookup

    /// Estimated cost for a usage sample with no vendor-reported cost.
    func estimate(model: String, tokens: TokenUsage) -> Double? {
        guard let pricing = lookup(model) else { return nil }
        var cost = Double(tokens.input) * pricing.input + Double(tokens.output) * pricing.output
        if let cacheRead = pricing.cacheRead { cost += Double(tokens.cacheRead) * cacheRead }
        if let cacheWrite = pricing.cacheWrite { cost += Double(tokens.cacheWrite) * cacheWrite }
        return cost
    }

    /// Cost of a sample: vendor-reported if present, else estimated.
    func cost(of sample: UsageSample) -> Double {
        sample.cost ?? sample.model.flatMap { estimate(model: $0, tokens: sample.tokens) } ?? 0
    }

    /// Lookup order: exact bare key, longest bare-key prefix of the model
    /// (date/version suffixes), then keys whose bare name the model startsWith.
    nonisolated func lookup(_ model: String) -> ModelPricing? {
        Self.lookup(model, in: table)
    }

    nonisolated static func lookup(_ model: String, in table: [String: ModelPricing]) -> ModelPricing? {
        let name = model.lowercased()
        if let exact = table[name] { return exact }
        // Longest bare key that prefixes the model id.
        let prefixed = table
            .filter { name.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }
        if let prefixed { return prefixed.value }
        // Model id carries a suffix the table key lacks (e.g. dated snapshots).
        let suffixed = table
            .filter { $0.key.hasPrefix(name) }
            .max { $0.key.count < $1.key.count }
        return suffixed?.value
    }

    // MARK: - Parsing (internal for tests)

    static func parse(_ data: Data) throws -> [String: ModelPricing] {
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var out: [String: ModelPricing] = [:]
        for (key, value) in raw {
            guard let entry = value as? [String: Any],
                  let input = entry["input_cost_per_token"] as? Double,
                  let output = entry["output_cost_per_token"] as? Double
            else { continue }
            // Only bare model keys ("claude-opus-5"), not provider-prefixed
            // variants ("anthropic.claude-...", "vertex_ai/...").
            guard !key.contains("/"), !key.contains(".") else { continue }
            out[key.lowercased()] = ModelPricing(
                input: input,
                output: output,
                cacheRead: entry["cache_read_input_token_cost"] as? Double,
                cacheWrite: entry["cache_creation_input_token_cost"] as? Double
            )
        }
        return out
    }
}
