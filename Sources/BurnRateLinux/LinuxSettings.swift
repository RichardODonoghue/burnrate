import BurnRateCore
import Foundation

/// Linux settings, persisted as JSON (no Combine/SwiftUI on Linux). Read by the
/// notifier and the tray/widgets; edited from the GTK settings window.
final class LinuxSettings: @unchecked Sendable {
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
        url = paths.appDirectory.appendingPathComponent("linux-settings.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            values = decoded
        } else {
            values = Values()
            persist(values) // materialise defaults so the file is editable
        }
    }

    var snapshot: Values {
        lock.lock()
        defer { lock.unlock() }
        return values
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

    /// Rules are keyed by provider+window, so adding one is idempotent — the
    /// pane's "Add rule" can be pressed twice without creating a duplicate.
    func addMilestone(_ milestone: Milestone) {
        mutate { values in
            values.milestones.removeAll { $0.key == milestone.key }
            values.milestones.append(milestone)
        }
    }

    func addBurnAlert(_ alert: BurnAlert) {
        mutate { values in
            values.burnAlerts.removeAll {
                $0.provider == alert.provider && $0.windowLabel == alert.windowLabel
            }
            values.burnAlerts.append(alert)
        }
    }

    func addCostAlert(provider: String, limit: Double) {
        mutate { values in
            values.costAlerts.removeAll { $0.provider == provider }
            values.costAlerts.append(CostAlert(provider: provider, dailyLimitUSD: limit))
        }
    }

    /// Removes whichever rule of any kind sits at `index` in the flattened
    /// order the pane renders (milestones, then burn alerts, then cost alerts).
    func removeRule(at index: Int) {
        mutate { values in
            if index < values.milestones.count {
                values.milestones.remove(at: index)
            } else {
                let rest = index - values.milestones.count
                if rest < values.burnAlerts.count {
                    values.burnAlerts.remove(at: rest)
                } else {
                    let tail = rest - values.burnAlerts.count
                    if tail < values.costAlerts.count { values.costAlerts.remove(at: tail) }
                }
            }
        }
    }

    /// Creates or updates the rule the pane's add form describes.
    ///
    /// One path for both, because macOS's button is Add *or* Update depending
    /// on whether a rule already exists for that provider+window, and both
    /// resolve to an upsert. `kind` mirrors `BR_RULE_*` in burnrate_gtk.h;
    /// spelled numerically so this model need not import the GTK shim.
    func upsertDraft(kind: Int32, provider: String, windowLabel: String,
                     value: Double, minutes: Int) {
        switch kind {
        case 0: // milestone — the form offers 5/10/20/25, as macOS does
            addMilestone(Milestone(provider: provider, windowLabel: windowLabel, step: value))
        case 1: // burn rate — minutes arrive pre-snapped to 15 by the form
            addBurnAlert(BurnAlert(provider: provider, windowLabel: windowLabel,
                                   percentDrop: value, minutes: minutes))
        default:
            if value > 0 { addCostAlert(provider: provider, limit: value) }
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
