import Foundation
import UserNotifications

/// Evaluates milestones after each poll and posts desktop notifications.
@MainActor
final class MilestoneNotifier {
    private let settingsStore: SettingsStore
    /// Last observed remaining % per window id, used to detect threshold crossings.
    private var lastRemaining: [String: Double] = [:]

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        Task { await requestAuthorization() }
    }

    private func requestAuthorization() async {
        // UNUserNotificationCenter needs a real app bundle; fall back to logging
        // when run via `swift run` without one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func evaluate(usage: [ProviderUsage]) {
        for provider in usage {
            for window in provider.windows {
                guard let current = window.percentRemaining else { continue }
                let previous = lastRemaining[window.id]
                lastRemaining[window.id] = current

                // One notification per window per crossing, even if several
                // thresholds match.
                let matched = settingsStore.milestones.contains { milestone in
                    milestone.provider == provider.providerName
                        && milestone.windowLabel == window.label
                        && MilestoneEvaluator.crossed(
                            previousRemaining: previous,
                            currentRemaining: current,
                            threshold: milestone.percentRemaining
                        )
                }
                guard matched else { continue }

                send(title: "\(provider.providerName) \(window.label) milestone",
                     body: String(format: "Only %.0f%% of your %@ window remaining.",
                                  current, window.label))
            }
        }
    }

    private func send(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            // Body contains "%" — never pass it as an NSLog format string.
            NSLog("%@", "[milestone] \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
