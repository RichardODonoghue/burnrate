import Foundation

/// One notification threshold: notify when a provider window's remaining %
/// drops to or below `percentRemaining`.
struct Milestone: Codable, Identifiable, Hashable {
    var provider: String
    var windowLabel: String
    var percentRemaining: Double

    var id: String { key }
    var key: String { "\(provider)|\(windowLabel)|\(percentRemaining)" }
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

/// Pure threshold logic, kept testable and UI-free.
enum MilestoneEvaluator {
    /// True when usage crossed from above the threshold to at/below it.
    static func crossed(previousRemaining: Double?, currentRemaining: Double, threshold: Double) -> Bool {
        guard let previous = previousRemaining else {
            return currentRemaining <= threshold
        }
        return previous > threshold && currentRemaining <= threshold
    }
}

/// Pure burn-rate detection over a timestamped remaining-% history.
enum BurnRateEvaluator {
    /// Returns (drop, baseline, current) when remaining fell by at least the
    /// alert's percentDrop over its trailing minutes window, else nil.
    ///
    /// `history` must be the window's remaining-% readings (oldest last).
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
    /// Per-model token burn alerts.
    @Published var modelBurnAlerts: [ModelBurnAlert] {
        didSet { persist() }
    }

    /// Placeholder capacities in weighted tokens (cache read ×0.1, write ×1.25),
    /// seeded from observed usage. Calibrate against your provider's usage page.
    static let defaultCapacities: [String: Int] = [
        "Claude|5hr": 30_000_000,
        "Claude|Weekly": 500_000_000,
        "Claude|Monthly": 3_000_000_000,
        "Codex|5hr": 12_000_000,
        "Codex|Weekly": 120_000_000,
        "OpenCode Go|5hr": 1_000_000,
        "OpenCode Go|Weekly": 5_000_000,
        "OpenCode Go|Monthly": 20_000_000,
    ]

    private let defaults: UserDefaults
    private static let milestonesKey = "milestones"
    private static let widgetsKey = "widgetProviders"
    private static let capacitiesKey = "planCapacities"
    private static let burnAlertsKey = "burnAlerts"
    private static let costAlertsKey = "costAlerts"
    private static let modelBurnAlertsKey = "modelBurnAlerts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        milestones = (defaults.data(forKey: Self.milestonesKey))
            .flatMap { try? decoder.decode([Milestone].self, from: $0) } ?? Self.defaultMilestones
        widgetProviders = (defaults.data(forKey: Self.widgetsKey))
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        planCapacities = (defaults.data(forKey: Self.capacitiesKey))
            .flatMap { try? decoder.decode([String: Int].self, from: $0) } ?? Self.defaultCapacities
        burnAlerts = (defaults.data(forKey: Self.burnAlertsKey))
            .flatMap { try? decoder.decode([BurnAlert].self, from: $0) } ?? Self.defaultBurnAlerts
        costAlerts = (defaults.data(forKey: Self.costAlertsKey))
            .flatMap { try? decoder.decode([CostAlert].self, from: $0) } ?? []
        modelBurnAlerts = (defaults.data(forKey: Self.modelBurnAlertsKey))
            .flatMap { try? decoder.decode([ModelBurnAlert].self, from: $0) } ?? []
        // Treat a persisted empty set as "no user config" so shipped defaults apply.
        if planCapacities.isEmpty {
            planCapacities = Self.defaultCapacities
        }
    }

    static var defaultMilestones: [Milestone] {
        [
            Milestone(provider: "Claude", windowLabel: "Rolling", percentRemaining: 20),
            Milestone(provider: "Claude", windowLabel: "Weekly", percentRemaining: 10),
            Milestone(provider: "Codex", windowLabel: "Rolling", percentRemaining: 20),
        ]
    }

    static var defaultBurnAlerts: [BurnAlert] {
        [
            BurnAlert(provider: "Claude", windowLabel: "Rolling", percentDrop: 15, minutes: 30),
        ]
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
        if let data = try? encoder.encode(modelBurnAlerts) {
            defaults.set(data, forKey: Self.modelBurnAlertsKey)
        }
    }
}
