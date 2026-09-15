import Foundation

/// A provider usage source that returns final window data. Implementations
/// may use a provider API (authoritative %) or local log parsing.
protocol UsageProvider: Actor {
    nonisolated var name: String { get }
    /// `capacities` comes from settings at call time (weighted-token units).
    func fetchUsage(capacities: [String: Int]) async -> ProviderUsage?
    /// Drop throttle state so the next fetch hits the network (sleep/wake,
    /// passed reset). Keeps the last snapshot for offline fallback.
    func invalidateCache()
}

/// Shared throttle policy for vendor quota providers.
enum ProviderThrottle {
    /// True when a window's reset moment passed after our last fetch — the
    /// snapshot predates the reset (the Mac slept through it, or fetches
    /// were backing off), so fetch fresh instead of serving cache.
    static func resetDue(windows: [UsageWindow]?, lastFetch: Date, now: Date) -> Bool {
        windows?.contains {
            guard let resetsAt = $0.resetsAt else { return false }
            return now >= resetsAt && lastFetch < resetsAt
        } ?? false
    }
}

/// Snapshot cache + rate-limit/backoff state shared by the vendor quota
/// providers (Claude and OpenCode Go), which otherwise duplicate it verbatim.
struct QuotaCache {
    let minInterval: TimeInterval
    let backoff: TimeInterval

    private(set) var windows: [UsageWindow]?
    private var lastFetch: Date = .distantPast
    private var errorBackoffUntil: Date = .distantPast

    init(minInterval: TimeInterval, backoff: TimeInterval) {
        self.minInterval = minInterval
        self.backoff = backoff
    }

    /// False when we're inside the minimum interval or an error backoff —
    /// unless a window reset has passed since the last fetch.
    func shouldFetch(now: Date) -> Bool {
        if ProviderThrottle.resetDue(windows: windows, lastFetch: lastFetch, now: now) {
            return true
        }
        if now < errorBackoffUntil { return false }
        return now.timeIntervalSince(lastFetch) >= minInterval
    }

    mutating func noteFetch(now: Date) {
        lastFetch = now
    }

    mutating func noteSuccess(_ windows: [UsageWindow]) {
        self.windows = windows
    }

    mutating func noteFailure(now: Date) {
        errorBackoffUntil = now.addingTimeInterval(backoff)
    }

    mutating func invalidate() {
        lastFetch = .distantPast
        errorBackoffUntil = .distantPast
    }
}

/// Wraps a local UsageSource (token log parsing) as a UsageProvider.
actor LocalUsageProvider: UsageProvider {
    nonisolated let name: String
    private let source: any UsageSource

    init(source: any UsageSource) {
        self.source = source
        self.name = source.name
    }

    func fetchUsage(capacities: [String: Int]) async -> ProviderUsage? {
        let samples = (try? await source.collectSamples()) ?? []
        // No local data at all → provider is not set up on this machine;
        // returning nil omits it from the UI entirely.
        guard !samples.isEmpty else { return nil }
        return ProviderUsage(
            providerName: name,
            plan: nil,
            windows: UsageComputation.windows(
                samples: samples,
                provider: name,
                capacities: capacities
            )
        )
    }

    func invalidateCache() {
        // No cache — every fetch re-reads the logs.
    }
}

/// Claude usage from Anthropic's undocumented OAuth endpoint — the same
/// data Claude Code's own HUD shows. Authoritative %, no capacity guessing.
///
/// GET https://api.anthropic.com/api/oauth/usage
/// Auth: Bearer token from ~/.claude/.credentials.json (claudeAiOauth.accessToken)
/// Header: anthropic-beta: oauth-2025-04-20
///
/// Response: {"five_hour": {"utilization": 99.0, "resets_at": "..."},
///            "seven_day": {...}} — utilization is percent USED (0–100).
///
/// The endpoint rate-limits aggressively (429), so: min 60s between calls,
/// exponential backoff on errors, and the last good snapshot is reused.
actor ClaudeUsageAPIProvider: UsageProvider {
    nonisolated let name = "Claude"

    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated static let minInterval: TimeInterval = 60
    nonisolated static let backoff: TimeInterval = 300

    private var cache = QuotaCache(minInterval: minInterval, backoff: backoff)
    /// Plan tier from the OAuth credential, e.g. "Team 5x". Read once.
    private var plan: String?

    private let credentialsURL: URL
    private let claudeJSONURL: URL

    /// Notified (on the main actor) when the signed-in Claude account
    /// changes, so alert state can be rebased onto the new account.
    private var credentialChangeHandler: (@MainActor @Sendable () -> Void)?
    /// accountUuid|organizationUuid from ~/.claude.json's oauthAccount —
    /// stable across OAuth token refreshes (a token hash is not).
    private var credentialFingerprint: String?
    /// Persisted so a switch detected after a relaunch still suppresses the
    /// one-off false reset/milestone alerts.
    private static let fingerprintKey = "claudeCredentialFingerprint"

    init(credentialsURL: URL? = nil, claudeJSONURL: URL? = nil) {
        self.credentialsURL = credentialsURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
        self.claudeJSONURL = claudeJSONURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json")
        self.credentialFingerprint = UserDefaults.standard.string(forKey: Self.fingerprintKey)
    }

    func setCredentialChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        credentialChangeHandler = handler
    }

    func fetchUsage(capacities: [String: Int]) async -> ProviderUsage? {
        let now = Date()
        guard cache.shouldFetch(now: now) else {
            return cache.windows.map { ProviderUsage(providerName: name, plan: plan, windows: $0) }
        }
        cache.noteFetch(now: now)
        do {
            let windows = try await performFetch()
            if plan == nil { plan = credentialPlan() }
            cache.noteSuccess(windows)
            return ProviderUsage(providerName: name, plan: plan, windows: windows)
        } catch {
            cache.noteFailure(now: now)
            return cache.windows.map { ProviderUsage(providerName: name, plan: plan, windows: $0) }
        }
    }

    func invalidateCache() {
        cache.invalidate()
    }

    // MARK: - Account identity (internal for tests)

    /// Signed-in account identity from Claude Code's `~/.claude.json`:
    /// `{"oauthAccount": {"accountUuid": "...", "organizationUuid": "..."}}`.
    /// Returns nil when the file is missing or has no account block.
    nonisolated static func accountFingerprint(fromClaudeJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any],
              let uuid = account["accountUuid"] as? String, !uuid.isEmpty
        else { return nil }
        let org = account["organizationUuid"] as? String ?? ""
        return "\(uuid)|\(org)"
    }

    /// Falls back to the token itself when no account block exists; that can
    /// false-positive on an OAuth refresh, hence the preference for the uuid.
    nonisolated static func fallbackFingerprint(token: String) -> String {
        "token|" + token.hashValue.description
    }

    private func noteCredentialIfChanged(token: String) async {
        let fingerprint = currentFingerprint(token: token)
        defer {
            credentialFingerprint = fingerprint
            UserDefaults.standard.set(fingerprint, forKey: Self.fingerprintKey)
        }
        guard let previous = credentialFingerprint, previous != fingerprint else { return }
        // New account: drop the cached plan tier so it refreshes immediately.
        plan = nil
        if let handler = credentialChangeHandler {
            await handler()
        }
    }

    private func currentFingerprint(token: String) -> String {
        if let data = try? Data(contentsOf: claudeJSONURL),
           let identity = Self.accountFingerprint(fromClaudeJSON: data) {
            return identity
        }
        return Self.fallbackFingerprint(token: token)
    }

    private func performFetch() async throws -> [UsageWindow] {
        guard let token = try accessToken() else { throw URLError(.userAuthenticationRequired) }
        await noteCredentialIfChanged(token: token)
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.parseWindows(data)
    }

    /// OAuth token: ~/.claude/.credentials.json first, else macOS Keychain
    /// ("Claude Code-credentials" generic password, same JSON shape).
    private func accessToken() throws -> String? {
        guard let oauth = readCredentialOAuth() else { return nil }
        return oauth["accessToken"] as? String
    }

    /// Plan tier from the credential, e.g. "Team 5x" (subscriptionType +
    /// multiplier parsed out of rateLimitTier "default_claude_max_5x").
    private func credentialPlan() -> String? {
        guard let oauth = readCredentialOAuth(),
              let subscriptionType = oauth["subscriptionType"] as? String
        else { return nil }
        return Self.formatPlan(subscriptionType: subscriptionType, rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    private func readCredentialOAuth() -> [String: Any]? {
        if let data = try? Data(contentsOf: credentialsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any]
        {
            return oauth
        }
        return keychainCredentialOAuth()
    }

    private func keychainCredentialOAuth() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil // no Keychain entry
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["claudeAiOauth"] as? [String: Any]
    }

    // MARK: - Plan formatting (internal for tests)

    nonisolated static func formatPlan(subscriptionType: String, rateLimitTier: String?) -> String {
        let name: String
        switch subscriptionType.lowercased() {
        case "max": name = "Max"
        case "team": name = "Team"
        case "pro": name = "Pro"
        case "enterprise": name = "Enterprise"
        default: name = subscriptionType
        }
        // Multiplier lives at the end of the tier: "default_claude_max_5x" → "5x".
        let multiplier = rateLimitTier.flatMap { tier -> String? in
            guard let match = tier.range(of: #"[0-9]+x$"#, options: .regularExpression) else { return nil }
            return String(tier[match])
        }
        return multiplier.map { "\(name) \($0)" } ?? name
    }

    // MARK: - Parsing (internal for tests)

    static func parseWindows(_ data: Data, now: Date = Date()) throws -> [UsageWindow] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        // Preferred: the "limits" array — includes model-scoped weekly quotas
        // (e.g. Fable) that the flat five_hour/seven_day keys don't cover.
        let limits = obj["limits"] as? [[String: Any]] ?? []
        if !limits.isEmpty {
            var windows: [UsageWindow] = []
            for limit in limits {
                let kind = limit["kind"] as? String ?? ""
                let label: String
                switch kind {
                case "session": label = "Rolling"
                case "weekly_all": label = "Weekly"
                case "weekly_scoped":
                    label = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                        ?? "Weekly (scoped)"
                default: continue
                }
                let used = (limit["percent"] as? Double).map { min(100, max(0, $0)) } ?? 0
                windows.append(UsageWindow(
                    id: "Claude-\(label)",
                    label: label,
                    tokensUsed: 0,
                    percentRemaining: 100 - used,
                    resetsAt: (limit["resets_at"] as? String).flatMap(LogDate.parse)
                ))
            }
            return windows
        }

        // Fallback: flat keys (older response shape).
        var windows: [UsageWindow] = []
        for (label, key) in [("Rolling", "five_hour"), ("Weekly", "seven_day")] {
            guard let entry = obj[key] as? [String: Any],
                  let utilization = entry["utilization"] as? Double
            else { continue }
            let resetsAt = (entry["resets_at"] as? String).flatMap(LogDate.parse)
            windows.append(UsageWindow(
                id: "Claude-\(label)",
                label: label,
                tokensUsed: 0,
                percentRemaining: max(0, 100 - utilization),
                resetsAt: resetsAt
            ))
        }
        return windows
    }
}
