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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        milestones = (defaults.data(forKey: Self.milestonesKey))
            .flatMap { try? decoder.decode([Milestone].self, from: $0) } ?? Self.defaultMilestones
        widgetProviders = (defaults.data(forKey: Self.widgetsKey))
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        planCapacities = (defaults.data(forKey: Self.capacitiesKey))
            .flatMap { try? decoder.decode([String: Int].self, from: $0) } ?? Self.defaultCapacities
        // Treat a persisted empty set as "no user config" so shipped defaults apply.
        if planCapacities.isEmpty {
            planCapacities = Self.defaultCapacities
        }
    }

    static var defaultMilestones: [Milestone] {
        [
            Milestone(provider: "Claude", windowLabel: "5hr", percentRemaining: 20),
            Milestone(provider: "Claude", windowLabel: "Weekly", percentRemaining: 10),
            Milestone(provider: "Codex", windowLabel: "5hr", percentRemaining: 20),
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
    }
}
