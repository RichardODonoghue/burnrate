import Foundation
import UserNotifications

/// Evaluates milestones and burn-rate alerts after each poll, posting
/// desktop notifications.
@MainActor
final class MilestoneNotifier {
    private let settingsStore: SettingsStore
    /// Last observed remaining % per window id, used to detect threshold crossings.
    private var lastRemaining: [String: Double] = [:]
    /// Remaining-% history per window id (oldest last), for burn-rate alerts.
    private var history: [String: [(date: Date, remaining: Double)]] = [:]
    /// Cooldown per window id after a burn-rate alert fires.
    private var burnCooldown: [String: Date] = [:]
    /// Daily-spend alert already fired, keyed "provider|dayStart".
    private var costFired: Set<String> = []
    /// Cooldown per model-burn alert key.
    private var modelBurnCooldown: [String: Date] = [:]

    nonisolated static let pollInterval: TimeInterval = 300
    /// History older than this can't affect any alert (largest window + slack).
    nonisolated static let historyRetention: TimeInterval = 6 * 3600
    nonisolated static let burnCooldownInterval: TimeInterval = 1800

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
        let now = Date()
        for provider in usage {
            for window in provider.windows {
                guard let current = window.percentRemaining else { continue }

                // Milestone crossing (one notification per window per crossing,
                // even if several thresholds match).
                let previous = lastRemaining[window.id]
                lastRemaining[window.id] = current

                // Window reset: remaining jumped up sharply (e.g. rolling over).
                if settingsStore.notifyOnReset, let previous, current - previous >= 40 {
                    send(title: "\(provider.providerName) \(window.label) reset",
                         body: String(format: "Window reset — %.0f%% remaining.", current))
                }

                let milestoneMatched = settingsStore.milestones.contains { milestone in
                    milestone.provider == provider.providerName
                        && milestone.windowLabel == window.label
                        && MilestoneEvaluator.crossed(
                            previousRemaining: previous,
                            currentRemaining: current,
                            threshold: milestone.percentRemaining
                        )
                }
                if milestoneMatched {
                    send(title: "\(provider.providerName) \(window.label) milestone",
                         body: String(format: "Only %.0f%% of your %@ window remaining.",
                                      current, window.label))
                }

                // Burn-rate detection over trailing history.
                recordHistory(windowID: window.id, date: now, remaining: current)
                evaluateBurnAlerts(provider: provider.providerName, window: window, now: now)
            }
        }
    }

    /// Daily local-log spend per provider vs configured cost alerts.
    /// Fires at most once per provider per day.
    func evaluateCosts(_ costs: [(provider: String, cost: Double)], date: Date = Date()) {
        let dayKey = String(Calendar.current.startOfDay(for: date).timeIntervalSince1970)
        for alert in settingsStore.costAlerts {
            let firedKey = "\(alert.provider)|\(dayKey)"
            guard !costFired.contains(firedKey),
                  let spend = costs.first(where: { $0.provider == alert.provider })?.cost,
                  spend >= alert.dailyLimitUSD
            else { continue }
            costFired.insert(firedKey)
            send(title: "\(alert.provider) daily spend",
                 body: String(format: "$%.2f spent today (limit $%.2f).", spend, alert.dailyLimitUSD))
        }
    }

    /// Per-model token burn detection from local logs.
    func evaluateModelBurn(_ buckets: [(provider: String, samples: [UsageSample])], date: Date = Date()) {
        for alert in settingsStore.modelBurnAlerts {
            if let until = modelBurnCooldown[alert.key], date < until { continue }
            guard let bucket = buckets.first(where: { $0.provider == alert.provider }) else { continue }
            guard let hit = ModelBurnEvaluator.detect(
                samples: bucket.samples,
                alert: alert,
                now: date,
                pollInterval: Self.pollInterval
            ) else { continue }
            modelBurnCooldown[alert.key] = date.addingTimeInterval(Self.burnCooldownInterval)
            send(title: "\(alert.provider) \(hit.model) burning fast",
                 body: String(format: "%@ tokens in %d min.",
                              StatusItemManager.formatTokens(hit.tokens), alert.minutes))
        }
    }

    private func recordHistory(windowID: String, date: Date, remaining: Double) {
        var entries = history[windowID] ?? []
        entries.append((date, remaining))
        let cutoff = date.addingTimeInterval(-Self.historyRetention)
        history[windowID] = entries.filter { $0.date >= cutoff }
    }

    private func evaluateBurnAlerts(provider: String, window: UsageWindow, now: Date) {
        guard let current = window.percentRemaining else { return }
        let windowID = window.id
        if let cooledUntil = burnCooldown[windowID], now < cooledUntil { return }

        let matching = settingsStore.burnAlerts.filter {
            $0.provider == provider && $0.windowLabel == window.label
        }
        guard let alert = matching.first else { return }
        let entries = history[windowID] ?? []
        guard let hit = BurnRateEvaluator.detect(
            history: entries,
            alert: alert,
            now: now,
            pollInterval: Self.pollInterval
        ) else { return }

        burnCooldown[windowID] = now.addingTimeInterval(Self.burnCooldownInterval)
        send(title: "\(provider) \(window.label) burning fast",
             body: String(format: "%.0f%% drop in %d min: %.0f%% → %.0f%% remaining.",
                          hit.drop, alert.minutes, hit.baseline, hit.current))
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
