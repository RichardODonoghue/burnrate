import BurnRateCore
import Foundation
import Testing
@testable import BurnRate

/// Capacities are predetermined: the store exposes fixed values and ignores any
/// previously persisted (calibration) config.
@MainActor
struct SettingsCapacitiesTests {
    @Test func capacitiesAreFixedWindowLabels() {
        #expect(SettingsStore.defaultCapacities["Codex|Rolling"] != nil)
        #expect(SettingsStore.defaultCapacities["Codex|5hr"] == nil)
    }

    @Test func storeIgnoresPersistedCapacities() throws {
        let name = "settings-capacities-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(["Codex|Rolling": 5_000_000]),
                     forKey: "planCapacities")

        let store = SettingsStore(defaults: defaults)
        #expect(store.planCapacities == SettingsStore.defaultCapacities)
    }
}
