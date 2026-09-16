import Foundation

/// One notification rule: notify each time a provider window's remaining %
/// drops past another `step` increment (e.g. step 10 fires at 90, 80, 70…
/// remaining). One rule per provider+window — `id` excludes the step so the
/// same window can never hold duplicate rules.
public struct Milestone: Codable, Identifiable, Hashable, Sendable {
    public var provider: String
    public var windowLabel: String
    /// Increment in percentage points (e.g. 10 = notify at 90/80/70… remaining).
    public var step: Double

    public var id: String { key }
    public var key: String { "\(provider)|\(windowLabel)" }

    enum CodingKeys: String, CodingKey {
        case provider, windowLabel, step, percentRemaining
    }

    public init(provider: String, windowLabel: String, step: Double) {
        self.provider = provider
        self.windowLabel = windowLabel
        self.step = step
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        windowLabel = try c.decode(String.self, forKey: .windowLabel)
        if let s = try c.decodeIfPresent(Double.self, forKey: .step) {
            step = s
        } else if let legacy = try c.decodeIfPresent(Double.self, forKey: .percentRemaining) {
            // Legacy fixed-threshold rule: keep its level covered by reusing
            // the threshold itself as the increment (`coalesce` keeps the
            // smallest step when several legacy rules collapse to one window).
            step = min(max(legacy.rounded(), 1), 50)
        } else {
            step = 20
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(windowLabel, forKey: .windowLabel)
        try c.encode(step, forKey: .step)
    }

    /// Collapse duplicates to one rule per provider+window, keeping the
    /// smallest increment (covers the most levels).
    public static func coalesce(_ milestones: [Milestone]) -> [Milestone] {
        var best: [String: Milestone] = [:]
        for m in milestones {
            if let existing = best[m.key], existing.step <= m.step { continue }
            best[m.key] = m
        }
        return best.values.sorted { $0.key < $1.key }
    }
}

/// One burn-rate alert: notify when a provider window's remaining % drops by
/// at least `percentDrop` within a trailing `minutes` window.
public struct BurnAlert: Codable, Identifiable, Hashable, Sendable {
    public var provider: String
    public var windowLabel: String
    public var percentDrop: Double
    public var minutes: Int

    public init(provider: String, windowLabel: String, percentDrop: Double, minutes: Int) {
        self.provider = provider
        self.windowLabel = windowLabel
        self.percentDrop = percentDrop
        self.minutes = minutes
    }

    public var id: String { key }
    public var key: String { "\(provider)|\(windowLabel)|\(percentDrop)|\(minutes)" }
}

/// Alert when one provider's daily local-log spend (USD) exceeds the limit.
public struct CostAlert: Codable, Identifiable, Hashable, Sendable {
    public var provider: String
    public var dailyLimitUSD: Double

    public init(provider: String, dailyLimitUSD: Double) {
        self.provider = provider
        self.dailyLimitUSD = dailyLimitUSD
    }

    public var id: String { provider }
}

/// Pure increment logic, kept testable and UI-free.
public enum MilestoneEvaluator {
    /// Grid levels below 100 for an increment, descending (20 → 80, 60, 40, 20).
    public static func thresholds(step: Double) -> [Double] {
        guard step > 0, step < 100 else { return [] }
        var levels: [Double] = []
        var k = 1.0
        while k * step < 100 {
            levels.append((k * step).rounded())
            k += 1
        }
        return levels.sorted(by: >)
    }

    /// Highest grid level crossed downward from previous to current, else nil.
    /// A nil previous (first observation) never fires — no crossing seen yet.
    public static func crossedThreshold(
        previousRemaining: Double?,
        currentRemaining: Double,
        step: Double
    ) -> Double? {
        guard let previous = previousRemaining else { return nil }
        return thresholds(step: step).first { previous > $0 && currentRemaining <= $0 }
    }
}

/// Pure burn-rate detection over a timestamped remaining-% history.
public enum BurnRateEvaluator {
    /// Returns (drop, baseline, current) when remaining fell by at least the
    /// alert's percentDrop over its trailing minutes window, else nil.
    ///
    /// `history` must hold the window's remaining-% readings in chronological
    /// order (oldest first); the last entry is treated as the current one.
    /// A baseline is only used if it is at least `minutes` old, so a freshly
    /// started app can't fire on a partial window.
    public static func detect(
        history: [(date: Date, remaining: Double)],
        alert: BurnAlert,
        now: Date,
        pollInterval: TimeInterval
    ) -> (drop: Double, baseline: Double, current: Double)? {
        // Baseline: oldest reading within the trailing window (+ one poll of
        // slack, since polls land on 5-minute boundaries).
        let windowStart = now.addingTimeInterval(-Double(alert.minutes) * 60 - pollInterval)
        guard let baseline = history.first(where: { $0.date >= windowStart }) else { return nil }
        // Require the window to actually span `minutes` — a freshly started
        // app has too little history to judge burn rate.
        guard now.timeIntervalSince(baseline.date) >= Double(alert.minutes) * 60 - pollInterval / 2 else {
            return nil
        }
        // History is appended chronologically; last entry is the current reading.
        guard let latest = history.last, latest.date >= baseline.date else { return nil }
        let drop = baseline.remaining - latest.remaining
        guard drop >= alert.percentDrop else { return nil }
        return (drop, baseline.remaining, latest.remaining)
    }
}
