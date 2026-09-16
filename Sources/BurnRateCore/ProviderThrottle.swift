import Foundation

/// Shared throttle policy for vendor quota providers.
public enum ProviderThrottle {
    /// True when a window's reset moment passed after our last fetch — the
    /// snapshot predates the reset (the machine slept through it, or fetches
    /// were backing off), so fetch fresh instead of serving cache.
    public static func resetDue(windows: [UsageWindow]?, lastFetch: Date, now: Date) -> Bool {
        windows?.contains {
            guard let resetsAt = $0.resetsAt else { return false }
            return now >= resetsAt && lastFetch < resetsAt
        } ?? false
    }
}

/// Snapshot cache + rate-limit/backoff state shared by the vendor quota
/// providers (Claude and OpenCode Go), which otherwise duplicate it verbatim.
public struct QuotaCache {
    let minInterval: TimeInterval
    let backoff: TimeInterval

    public private(set) var windows: [UsageWindow]?
    private var lastFetch: Date = .distantPast
    private var errorBackoffUntil: Date = .distantPast

    public init(minInterval: TimeInterval, backoff: TimeInterval) {
        self.minInterval = minInterval
        self.backoff = backoff
    }

    /// False when we're inside the minimum interval or an error backoff —
    /// unless a window reset has passed since the last fetch.
    public func shouldFetch(now: Date) -> Bool {
        if ProviderThrottle.resetDue(windows: windows, lastFetch: lastFetch, now: now) {
            return true
        }
        if now < errorBackoffUntil { return false }
        return now.timeIntervalSince(lastFetch) >= minInterval
    }

    public mutating func noteFetch(now: Date) {
        lastFetch = now
    }

    public mutating func noteSuccess(_ windows: [UsageWindow]) {
        self.windows = windows
    }

    public mutating func noteFailure(now: Date) {
        errorBackoffUntil = now.addingTimeInterval(backoff)
    }

    public mutating func invalidate() {
        lastFetch = .distantPast
        errorBackoffUntil = .distantPast
    }
}
