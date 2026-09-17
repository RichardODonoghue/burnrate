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
    /// Predetermined token capacity per provider window (weighted: cache read
    /// ×0.1, write ×1.25), for local-log providers only. Codex is the only
    /// provider measured from logs; Claude and OpenCode Go report their own %.
    let planCapacities: [String: Int] = SettingsStore.defaultCapacities
    /// Burn-rate alerts: notify on a fast % drop within a trailing window.
    @Published var burnAlerts: [BurnAlert] {
        didSet { persist() }
    }
    /// Per-provider daily spend cap (USD), from local logs (OpenCode only
    /// reports cost today).
    @Published var costAlerts: [CostAlert] {
        didSet { persist() }
    }
    /// Fixed capacities for local-only providers, keyed "provider|windowLabel".
    static let defaultCapacities: [String: Int] = [
        "Codex|Rolling": 12_000_000,
        "Codex|Weekly": 120_000_000,
        "Codex|Monthly": 400_000_000,
    ]

    private let defaults: UserDefaults
    private static let milestonesKey = "milestones"
    private static let widgetsKey = "widgetProviders"
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
        burnAlerts = (defaults.data(forKey: Self.burnAlertsKey))
            .flatMap { try? decoder.decode([BurnAlert].self, from: $0) } ?? Self.defaultBurnAlerts
        notifyOnReset = defaults.object(forKey: Self.notifyOnResetKey) as? Bool ?? true
        costAlerts = (defaults.data(forKey: Self.costAlertsKey))
            .flatMap { try? decoder.decode([CostAlert].self, from: $0) } ?? []
    }

    static var defaultMilestones: [Milestone] {
        AlertDefaults.milestones
    }

    static var defaultBurnAlerts: [BurnAlert] {
        AlertDefaults.burnAlerts
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
        if let data = try? encoder.encode(burnAlerts) {
            defaults.set(data, forKey: Self.burnAlertsKey)
        }
        if let data = try? encoder.encode(costAlerts) {
            defaults.set(data, forKey: Self.costAlertsKey)
        }
        defaults.set(notifyOnReset, forKey: Self.notifyOnResetKey)
    }
}

extension SettingsStore: AlertSettings {}
