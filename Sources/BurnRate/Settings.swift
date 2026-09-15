import Foundation

/// One notification rule: notify each time a provider window's remaining %
/// drops past another `step` increment (e.g. step 10 fires at 90, 80, 70…
/// remaining). One rule per provider+window — `id` excludes the step so the
/// same window can never hold duplicate rules.
struct Milestone: Codable, Identifiable, Hashable {
    var provider: String
    var windowLabel: String
    /// Increment in percentage points (e.g. 10 = notify at 90/80/70… remaining).
    var step: Double

    var id: String { key }
    var key: String { "\(provider)|\(windowLabel)" }

    enum CodingKeys: String, CodingKey {
        case provider, windowLabel, step, percentRemaining
    }

    init(provider: String, windowLabel: String, step: Double) {
        self.provider = provider
        self.windowLabel = windowLabel
        self.step = step
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(windowLabel, forKey: .windowLabel)
        try c.encode(step, forKey: .step)
    }

    /// Collapse duplicates to one rule per provider+window, keeping the
    /// smallest increment (covers the most levels).
    static func coalesce(_ milestones: [Milestone]) -> [Milestone] {
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
struct BurnAlert: Codable, Identifiable, Hashable {
    var provider: String
    var windowLabel: String
    var percentDrop: Double
    var minutes: Int

    var id: String { key }
    var key: String { "\(provider)|\(windowLabel)|\(percentDrop)|\(minutes)" }
}

/// Pure increment logic, kept testable and UI-free.
enum MilestoneEvaluator {
    /// Grid levels below 100 for an increment, descending (20 → 80, 60, 40, 20).
    static func thresholds(step: Double) -> [Double] {
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
    static func crossedThreshold(
        previousRemaining: Double?,
        currentRemaining: Double,
        step: Double
    ) -> Double? {
        guard let previous = previousRemaining else { return nil }
        return thresholds(step: step).first { previous > $0 && currentRemaining <= $0 }
    }

}

/// Pure burn-rate detection over a timestamped remaining-% history.
enum BurnRateEvaluator {
    /// Returns (drop, baseline, current) when remaining fell by at least the
    /// alert's percentDrop over its trailing minutes window, else nil.
    ///
    /// `history` must hold the window's remaining-% readings in chronological
    /// order (oldest first); the last entry is treated as the current one.
    /// A baseline is only used if it is at least `minutes` old, so a freshly
    /// started app can't fire on a partial window.
    static func detect(
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

/// Alert when one provider's daily local-log spend (USD) exceeds the limit.
struct CostAlert: Codable, Identifiable, Hashable {
    var provider: String
    var dailyLimitUSD: Double

    var id: String { provider }
}

/// Holds user settings; persists to UserDefaults as JSON.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var milestones: [Milestone] {
        didSet { persist() }
    }
    /// Provider names with an extra menu-bar widget spawned.
    @Published var widgetProviders: [String] {
        didSet { persist() }
    }
    /// Notify on window reset (remaining jumps back up).
    @Published var notifyOnReset: Bool {
        didSet { persist() }
    }
    /// Token capacity per provider window, keyed "provider|windowLabel"
    /// (e.g. "Claude|5hr"). Calibrate until % matches the provider's own
    /// usage display. 0/missing = unknown, % shows "--".
    @Published var planCapacities: [String: Int] {
        didSet { persist() }
    }
    /// Burn-rate alerts: notify on a fast % drop within a trailing window.
    @Published var burnAlerts: [BurnAlert] {
        didSet { persist() }
    }
    /// Per-provider daily spend cap (USD), from local logs (OpenCode only
    /// reports cost today).
    @Published var costAlerts: [CostAlert] {
        didSet { persist() }
    }
    /// Seeded token capacities (weighted: cache read ×0.1, write ×1.25) for
    /// local-only providers. Codex is the only provider measured from logs;
    /// Claude and OpenCode Go report their own authoritative %.
    static let defaultCapacities: [String: Int] = [
        "Codex|Rolling": 12_000_000,
        "Codex|Weekly": 120_000_000,
        "Codex|Monthly": 400_000_000,
    ]

    private let defaults: UserDefaults
    private static let milestonesKey = "milestones"
    private static let widgetsKey = "widgetProviders"
    private static let capacitiesKey = "planCapacities"
    private static let burnAlertsKey = "burnAlerts"
    private static let costAlertsKey = "costAlerts"
    private static let notifyOnResetKey = "notifyOnReset"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        milestones = Milestone.coalesce((defaults.data(forKey: Self.milestonesKey))
            .flatMap { try? decoder.decode([Milestone].self, from: $0) } ?? Self.defaultMilestones)
        widgetProviders = (defaults.data(forKey: Self.widgetsKey))
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        planCapacities = (defaults.data(forKey: Self.capacitiesKey))
            .flatMap { try? decoder.decode([String: Int].self, from: $0) } ?? Self.defaultCapacities
        burnAlerts = (defaults.data(forKey: Self.burnAlertsKey))
            .flatMap { try? decoder.decode([BurnAlert].self, from: $0) } ?? Self.defaultBurnAlerts
        notifyOnReset = defaults.object(forKey: Self.notifyOnResetKey) as? Bool ?? true
        costAlerts = (defaults.data(forKey: Self.costAlertsKey))
            .flatMap { try? decoder.decode([CostAlert].self, from: $0) } ?? []
        // Treat a persisted empty set as "no user config" so shipped defaults apply.
        if planCapacities.isEmpty {
            planCapacities = Self.defaultCapacities
        }
        planCapacities = Self.migratedCapacities(planCapacities)
    }

    /// Older builds keyed the 5-hour window "5hr"; the window is labelled
    /// "Rolling" now, so remap persisted capacities or they stop applying.
    nonisolated static func migratedCapacities(_ capacities: [String: Int]) -> [String: Int] {
        var result = capacities
        for (key, value) in capacities where key.hasSuffix("|5hr") {
            let target = key.replacingOccurrences(of: "|5hr", with: "|Rolling")
            result.removeValue(forKey: key)
            if result[target] == nil { result[target] = value }
        }
        return result
    }

    static var defaultMilestones: [Milestone] {
        [
            Milestone(provider: "Claude", windowLabel: "Rolling", step: 20),
            Milestone(provider: "Claude", windowLabel: "Weekly", step: 20),
            Milestone(provider: "Codex", windowLabel: "Rolling", step: 20),
        ]
    }

    static var defaultBurnAlerts: [BurnAlert] {
        [
            BurnAlert(provider: "Claude", windowLabel: "Rolling", percentDrop: 15, minutes: 30),
        ]
    }

    /// Insert or replace the rule for a provider+window — duplicates impossible.
    func upsertMilestone(_ milestone: Milestone) {
        milestones.removeAll { $0.key == milestone.key }
        milestones.append(milestone)
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(milestones) {
            defaults.set(data, forKey: Self.milestonesKey)
        }
        if let data = try? encoder.encode(widgetProviders) {
            defaults.set(data, forKey: Self.widgetsKey)
        }
        if let data = try? encoder.encode(planCapacities) {
            defaults.set(data, forKey: Self.capacitiesKey)
        }
        if let data = try? encoder.encode(burnAlerts) {
            defaults.set(data, forKey: Self.burnAlertsKey)
        }
        if let data = try? encoder.encode(costAlerts) {
            defaults.set(data, forKey: Self.costAlertsKey)
        }
        defaults.set(notifyOnReset, forKey: Self.notifyOnResetKey)
    }
}
