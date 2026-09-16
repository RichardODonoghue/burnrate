import Foundation
import BurnRateCore

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
