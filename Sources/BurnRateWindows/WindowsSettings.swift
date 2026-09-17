import BurnRateCore
import Foundation

/// Windows settings, persisted as JSON (no settings GUI yet). Read by the
/// notifier and the tray/widgets; edit the file to change rules.
final class WindowsSettings: @unchecked Sendable {
    struct Values: Codable, Sendable {
        var widgetProviders: [String] = []
        var notifyOnReset = true
        var milestones: [Milestone] = AlertDefaults.milestones
        var burnAlerts: [BurnAlert] = AlertDefaults.burnAlerts
        var costAlerts: [CostAlert] = []
    }

    private let lock = NSLock()
    private var values: Values
    private let url: URL

    init(paths: any AppPaths = FileManagerPaths()) {
        url = paths.appDirectory.appendingPathComponent("windows-settings.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            values = decoded
        } else {
            values = Values()
            persist(values) // materialise defaults so the file is editable
        }
    }

    var snapshot: Values {
        lock.withLock { values }
    }

    func setWidget(_ provider: String, enabled: Bool) {
        mutate { values in
            values.widgetProviders.removeAll { $0 == provider }
            if enabled { values.widgetProviders.append(provider) }
        }
    }

    func setNotifyOnReset(_ enabled: Bool) {
        mutate { $0.notifyOnReset = enabled }
    }

    func setMilestoneStep(at index: Int, step: Double) {
        mutate { values in
            guard index >= 0, index < values.milestones.count else { return }
            values.milestones[index].step = step
        }
    }

    func setBurnAlert(at index: Int, drop: Double?, minutes: Double?) {
        mutate { values in
            guard index >= 0, index < values.burnAlerts.count else { return }
            if let drop { values.burnAlerts[index].percentDrop = drop }
            if let minutes { values.burnAlerts[index].minutes = Int(minutes.rounded()) }
        }
    }

    func setCostAlertLimit(at index: Int, limit: Double) {
        mutate { values in
            guard index >= 0, index < values.costAlerts.count else { return }
            values.costAlerts[index].dailyLimitUSD = limit
        }
    }

    private func mutate(_ body: (inout Values) -> Void) {
        lock.lock()
        body(&values)
        let saved = values
        lock.unlock()
        persist(saved)
    }

    private func persist(_ values: Values) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: url)
        }
    }
}
