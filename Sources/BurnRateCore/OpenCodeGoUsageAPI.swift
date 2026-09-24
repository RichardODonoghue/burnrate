#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
public actor OpenCodeGoUsageAPIProvider: UsageProvider {
    public nonisolated let name = "OpenCode"

    public nonisolated static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    nonisolated static let minInterval: TimeInterval = 60
    nonisolated static let backoff: TimeInterval = 300

    private var cache = QuotaCache(minInterval: minInterval, backoff: backoff)
    /// Human-readable reason the last fetch produced no data (nil = healthy).
    public private(set) var lastStatus: String?

    /// Candidate credential locations, checked in order.
    public nonisolated let authURLs: [URL]

    public init(authURL: URL? = nil, paths: any AppPaths = FileManagerPaths()) {
        if let authURL {
            self.authURLs = [authURL]
        } else {
            self.authURLs = [
                paths.dataDirectory.appendingPathComponent("opencode/auth.json"),
                paths.homeDirectory.appendingPathComponent(".local/share/opencode/auth.json"),
                paths.configDirectory.appendingPathComponent("opencode/auth.json"),
            ]
        }
    }

    public func fetchUsage(capacities: [String: Int]) async -> ProviderUsage? {
        let now = Date()
        guard cache.shouldFetch(now: now) else {
            return cache.windows.map { ProviderUsage(providerName: name, plan: "Go", windows: $0) }
        }
        cache.noteFetch(now: now)
        do {
            let windows = try await performFetch()
            cache.noteSuccess(windows)
            return ProviderUsage(providerName: name, plan: "Go", windows: windows)
        } catch {
            cache.noteFailure(now: now)
            return cache.windows.map { ProviderUsage(providerName: name, plan: "Go", windows: $0) }
        }
    }

    public func invalidateCache() {
        cache.invalidate()
    }

    private func performFetch() async throws -> [UsageWindow] {
        guard let key = Self.readAPIKey(at: authURLs) else {
            lastStatus = "no OpenCode key in \(authURLs.map(\.path).joined(separator: ", "))"
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode
        guard code == 200 else {
            lastStatus = "OpenCode usage request failed (HTTP \(code.map(String.init) ?? "?"))"
            throw URLError(.badServerResponse)
        }
        lastStatus = nil
        return try Self.parseWindows(data)
    }

    /// API key from OpenCode's auth.json (written by `/connect`), or nil.
    public nonisolated static func readAPIKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let goEntry = obj["opencode-go"] as? [String: Any]
        else { return nil }
        return goEntry["key"] as? String
    }

    /// First of several candidate locations that holds a key.
    public nonisolated static func readAPIKey(at urls: [URL]) -> String? {
        for url in urls {
            if let key = readAPIKey(at: url) { return key }
        }
        return nil
    }

    // MARK: - Parsing (internal for tests)

    public static func parseWindows(_ data: Data) throws -> [UsageWindow] {
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
                percentRemaining: 100 - used,
                resetsAt: (entry["resetsAt"] as? String).flatMap(LogDate.parse)
            ))
        }
        return windows
    }
}
