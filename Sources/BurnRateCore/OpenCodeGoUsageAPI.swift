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

    /// Candidate credential locations, checked in order. v1 keeps keys in
    /// `auth.json`; v2 uses `account.json` (and the DB `credential` table).
    public nonisolated let authURLs: [URL]
    /// Candidate OpenCode databases, for the v2 `credential` table fallback.
    public nonisolated let dbURLs: [URL]
    private let sqlite: any SQLiteQuerying

    public init(authURL: URL? = nil, paths: any AppPaths = FileManagerPaths(),
                sqlite: any SQLiteQuerying = ProcessSQLiteRunner()) {
        self.sqlite = sqlite
        if let authURL {
            self.authURLs = [authURL]
            self.dbURLs = []
        } else {
            let dirs = [
                paths.dataDirectory.appendingPathComponent("opencode"),
                paths.homeDirectory.appendingPathComponent(".local/share/opencode"),
                paths.configDirectory.appendingPathComponent("opencode"),
            ]
            var files: [URL] = []
            for dir in dirs {
                files.append(dir.appendingPathComponent("auth.json"))
                files.append(dir.appendingPathComponent("account.json"))
            }
            self.authURLs = files
            self.dbURLs = dirs.map { $0.appendingPathComponent("opencode.db") }
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
        // Sets `lastStatus` to a precise reason when no key can be resolved.
        guard let key = resolveAPIKey() else {
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

    /// API key from one credential file. Supports OpenCode v1 `auth.json`
    /// (`{"opencode-go":{"key":…}}`) and v2 `account.json`
    /// (`{"version":2,"accounts":{…serviceID:"opencode-go"…credential.key}}`).
    public nonisolated static func readAPIKey(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return apiKey(inJSON: data)
    }

    /// First of several candidate locations that holds a key.
    public nonisolated static func readAPIKey(at urls: [URL]) -> String? {
        for url in urls {
            if let key = readAPIKey(at: url) { return key }
        }
        return nil
    }

    /// Extracts the `opencode-go` key from either credential-file shape.
    public nonisolated static func apiKey(inJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // v1: {"opencode-go": {"type": "api", "key": "…"}}
        if let entry = obj["opencode-go"] as? [String: Any], let key = entry["key"] as? String {
            return key
        }

        // v2 account.json: {"version":2,"accounts":{id:{serviceID,credential:{key}}}}
        if let accounts = obj["accounts"] as? [String: Any] {
            for value in accounts.values {
                guard let entry = value as? [String: Any],
                      (entry["serviceID"] as? String) == "opencode-go",
                      let credential = entry["credential"] as? [String: Any],
                      let key = credential["key"] as? String
                else { continue }
                return key
            }
        }

        return nil
    }

    /// Resolves the Go API key from a credential file (v1/v2) or the database
    /// (v2). On failure `lastStatus` explains precisely what was missing —
    /// OpenCode v2 keeps the key *only* in `opencode.db`, so without that
    /// distinction a missing `sqlite3` reads as a missing subscription.
    private func resolveAPIKey() -> String? {
        if let key = Self.readAPIKey(at: authURLs) { return key }
        switch openCodeKeyFromDatabase() {
        case .found(let key):
            return key
        case .noDatabase:
            lastStatus = "no OpenCode key: no auth.json/account.json in "
                + "\(authURLs.map(\.path).joined(separator: ", ")) and no opencode.db"
        case .noCredentialRow:
            lastStatus = "no opencode-go credential in the OpenCode database "
                + "(run /connect in OpenCode to add one)"
        case .unreadable(let why):
            lastStatus = "no OpenCode key — \(why)"
        }
        return nil
    }

    /// Outcome of the v2 database fallback, so a missing `sqlite3` is reported
    /// as such instead of masquerading as a missing subscription.
    private enum DatabaseKeyLookup {
        case found(String)
        /// No `opencode.db` at any candidate path (pre-v2 layout, or not OpenCode).
        case noDatabase
        /// The database was read but holds no `opencode-go` row.
        case noCredentialRow
        /// A database exists but the key could not be read — `reason` is for humans.
        case unreadable(String)
    }

    /// v2 also stores keys in the DB `credential` table
    /// (`integration_id = 'opencode-go'`, `value` JSON with a `key`).
    private func openCodeKeyFromDatabase() -> DatabaseKeyLookup {
        let existing = dbURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return .noDatabase }

        var failure: String?
        for url in existing {
            let output: String
            do {
                output = try sqlite.query(
                    databaseAt: url,
                    sql: "SELECT value FROM credential WHERE integration_id='opencode-go' LIMIT 1;"
                )
            } catch SQLiteError.runnerUnavailable {
                failure = "the sqlite3 CLI is not installed, so \(url.lastPathComponent) "
                    + "cannot be read (install your distro's sqlite package)"
                continue
            } catch {
                failure = "could not query \(url.path): \(error)"
                continue
            }
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let key = Self.apiKey(inJSON: Data(value.utf8)) { return .found(key) }
            // value may be {"type":"key","key":"…"} — same flat shape.
            if let obj = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
               let key = obj["key"] as? String
            {
                return .found(key)
            }
        }
        if let failure { return .unreadable(failure) }
        return .noCredentialRow
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
