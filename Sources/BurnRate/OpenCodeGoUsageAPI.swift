import Foundation

/// OpenCode Go usage from OpenCode's own quota endpoint — the same data the
/// OpenCode TUI shows. Vendor-authoritative %, no capacity guessing.
///
/// GET https://opencode.ai/zen/go/v1/usage
/// Auth: Bearer API key from ~/.local/share/opencode/auth.json
///       ("opencode-go" entry, type "api") — created by `/connect` in OpenCode.
///
/// Response: {"usage": {"rolling": {"status": "ok", "percent": 2,
///           "resetsAt": "...Z"}, "weekly": {...}, "monthly": {...}}}
/// `percent` is percent USED (0–100).
actor OpenCodeGoUsageAPIProvider: UsageProvider {
    nonisolated let name = "OpenCode"

    nonisolated static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    nonisolated static let minInterval: TimeInterval = 60
    nonisolated static let backoff: TimeInterval = 300

    private var lastWindows: [UsageWindow]?
    private var lastFetch: Date = .distantPast
    private var errorBackoffUntil: Date = .distantPast

    private let authURL: URL

    init(authURL: URL? = nil) {
        self.authURL = authURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode/auth.json")
    }

    func fetchUsage(capacities: [String: Int]) async -> ProviderUsage? {
        let now = Date()
        if now < errorBackoffUntil || now.timeIntervalSince(lastFetch) < Self.minInterval {
            return lastWindows.map { ProviderUsage(providerName: name, plan: "Go", windows: $0) }
        }
        lastFetch = now
        do {
            let windows = try await performFetch()
            lastWindows = windows
            return ProviderUsage(providerName: name, plan: "Go", windows: windows)
        } catch {
            errorBackoffUntil = now.addingTimeInterval(Self.backoff)
            return lastWindows.map { ProviderUsage(providerName: name, plan: "Go", windows: $0) }
        }
    }

    private func performFetch() async throws -> [UsageWindow] {
        guard let key = Self.readAPIKey(at: authURL) else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.parseWindows(data)
    }

    /// API key from OpenCode's auth.json (written by `/connect`).
    nonisolated static func readAPIKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goEntry = obj["opencode-go"] as? [String: Any]
        else { return nil }
        return goEntry["key"] as? String
    }

    // MARK: - Parsing (internal for tests)

    static func parseWindows(_ data: Data) throws -> [UsageWindow] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = obj["usage"] as? [String: Any]
        else { throw URLError(.cannotParseResponse) }

        var windows: [UsageWindow] = []
        // Both providers' short rolling windows share the "Rolling" label.
        for (label, key) in [("Rolling", "rolling"), ("Weekly", "weekly"), ("Monthly", "monthly")] {
            guard let entry = usage[key] as? [String: Any] else { continue }
            let used = (entry["percent"] as? Double)
                .map { min(100, max(0, $0)) } ?? 0
            windows.append(UsageWindow(
                id: "OpenCode-\(label)",
                label: label,
                tokensUsed: 0,
                weightedUsed: 0,
                percentRemaining: 100 - used,
                resetsAt: (entry["resetsAt"] as? String).flatMap(LogDate.parse)
            ))
        }
        return windows
    }
}
