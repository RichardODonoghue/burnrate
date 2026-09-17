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

    private func persist(_ values: Values) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: url)
        }
    }
}
