import BurnRateCore
import Foundation
import Testing
@testable import BurnRate

struct SettingsMigrationTests {
    @Test func remapsLegacyFiveHourKeys() {
        let migrated = SettingsStore.migratedCapacities(["Codex|5hr": 12, "Codex|Weekly": 120])
        #expect(migrated["Codex|Rolling"] == 12)
        #expect(migrated["Codex|5hr"] == nil)
        #expect(migrated["Codex|Weekly"] == 120)
    }

    @Test func keepsExistingRollingValueOverLegacy() {
        let migrated = SettingsStore.migratedCapacities(["Codex|5hr": 12, "Codex|Rolling": 99])
        #expect(migrated["Codex|Rolling"] == 99)
        #expect(migrated["Codex|5hr"] == nil)
    }

    @Test func leavesCurrentKeysUntouched() {
        let migrated = SettingsStore.migratedCapacities(["Codex|Rolling": 1_000_000])
        #expect(migrated == ["Codex|Rolling": 1_000_000])
    }

    @MainActor
    @Test func defaultCapacitiesUseWindowLabels() {
        #expect(SettingsStore.defaultCapacities["Codex|Rolling"] != nil)
        #expect(SettingsStore.defaultCapacities["Codex|5hr"] == nil)
    }

    @MainActor
    @Test func storeMigratesPersistedCapacities() throws {
        let name = "settings-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(["Codex|5hr": 5_000_000]),
                     forKey: "planCapacities")

        let store = SettingsStore(defaults: defaults)
        #expect(store.planCapacities["Codex|Rolling"] == 5_000_000)
        #expect(store.planCapacities["Codex|5hr"] == nil)
    }
}
