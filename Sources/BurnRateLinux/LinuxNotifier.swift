import BurnRateCore
import Foundation

/// Linux desktop alerts via `notify-send`.
///
/// Deliberately separate from the macOS `MilestoneNotifier`: that type is
/// `@MainActor`, and the GTK main loop does not drive Swift's MainActor
/// executor, so calling it off the GLib thread would not run. This class is
/// thread-safe and reads the shared `LinuxSettings`.
final class LinuxNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private let settings: LinuxSettings
    private var lastRemaining: [String: Double] = [:]
    private var history: [String: [(date: Date, remaining: Double)]] = [:]
    private var lastResetsAt: [String: Date] = [:]
    private var burnCooldown: [String: Date] = [:]
    private var recent: [String: Date] = [:]
    private var costFired: Set<String> = []

    private static let historyRetention: TimeInterval = 6 * 3600
    private static let burnCooldownInterval: TimeInterval = 1800

    init(settings: LinuxSettings) {
        self.settings = settings
    }

    func evaluate(_ usage: [ProviderUsage], now: Date = Date()) {
        let values = settings.snapshot
        lock.lock()
        defer { lock.unlock() }

        for provider in usage {
            for window in provider.windows {
                guard let current = window.percentRemaining else { continue }
                let previous = lastRemaining[window.id]
                lastRemaining[window.id] = current

                // Window reset: vendor moved resetsAt forward, or a big jump.
                var isReset = false
                if let previousResets = lastResetsAt[window.id],
                   let resetsAt = window.resetsAt,
                   resetsAt > previousResets,
                   current > (previous ?? 0) {
                    isReset = true
                }
                if let previous, current - previous >= 40 { isReset = true }
                if let resetsAt = window.resetsAt { lastResetsAt[window.id] = resetsAt }
                if previous != nil, isReset, values.notifyOnReset {
                    send(title: "\(provider.providerName) \(window.label) reset",
                         body: String(format: "Window reset — %.0f%% remaining.", current))
                }

                let band: Double? = values.milestones
                    .filter { $0.provider == provider.providerName && $0.windowLabel == window.label }
                    .compactMap {
                        MilestoneEvaluator.crossedThreshold(
                            previousRemaining: previous, currentRemaining: current, step: $0.step)
                    }
                    .max()
                if let band {
                    send(title: "\(provider.providerName) \(window.label) milestone",
                         body: String(format: "Only %.0f%% of your %@ window remaining (crossed below %.0f%%).",
                                      current, window.label, band))
                }

                recordHistory(windowID: window.id, date: now, remaining: current)
                evaluateBurn(provider: provider.providerName, window: window, now: now,
                             alerts: values.burnAlerts)
            }
        }
    }

    func evaluateCosts(_ costs: [(provider: String, cost: Double)], now: Date = Date()) {
        let values = settings.snapshot
        let dayKey = String(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        lock.lock()
        defer { lock.unlock() }
        for alert in values.costAlerts {
            let key = "\(alert.provider)|\(dayKey)"
            guard !costFired.contains(key),
                  let spend = costs.first(where: { $0.provider == alert.provider })?.cost,
                  spend >= alert.dailyLimitUSD
            else { continue }
            costFired.insert(key)
            send(title: "\(alert.provider) daily spend",
                 body: String(format: "$%.2f spent today (limit $%.2f).", spend, alert.dailyLimitUSD))
        }
    }

    private func recordHistory(windowID: String, date: Date, remaining: Double) {
        var entries = history[windowID] ?? []
        entries.append((date, remaining))
        let cutoff = date.addingTimeInterval(-Self.historyRetention)
        history[windowID] = entries.filter { $0.date >= cutoff }
    }

    private func evaluateBurn(provider: String, window: UsageWindow, now: Date, alerts: [BurnAlert]) {
        if let until = burnCooldown[window.id], now < until { return }
        guard let alert = alerts.first(where: {
            $0.provider == provider && $0.windowLabel == window.label
        }) else { return }
        guard let hit = BurnRateEvaluator.detect(
            history: history[window.id] ?? [], alert: alert, now: now, pollInterval: 300
        ) else { return }
        burnCooldown[window.id] = now.addingTimeInterval(Self.burnCooldownInterval)
        send(title: "\(provider) \(window.label) burning fast",
             body: String(format: "%.0f%% drop in %d min: %.0f%% → %.0f%% remaining.",
                          hit.drop, alert.minutes, hit.baseline, hit.current))
    }

    private func send(title: String, body: String) {
        let key = title + "|" + body
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        guard recent[key] == nil else { return }
        recent[key] = now

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/notify-send")
        process.arguments = [title, body]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
