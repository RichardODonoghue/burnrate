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
    private let paths: any AppPaths
    private var lastRemaining: [String: Double] = [:]
    private var history: [String: [(date: Date, remaining: Double)]] = [:]
    private var lastResetsAt: [String: Date] = [:]
    private var burnCooldown: [String: Date] = [:]
    private var recent: [String: Date] = [:]
    private var costFired: Set<String> = []
    /// Set when alerts could not be delivered (e.g. `notify-send` missing), so
    /// the app can say so instead of silently showing nothing.
    public private(set) var lastError: String?

    private static let historyRetention: TimeInterval = 6 * 3600
    private static let burnCooldownInterval: TimeInterval = 1800
    private static let stateFile = "notifier-state.json"

    /// Alert bookkeeping persisted across launches. Without it every restart
    /// treats the first poll as a fresh baseline: the current milestone band
    /// re-fires, a reset we already announced fires again, and the once-per-day
    /// cost gate resets. Mirrors the macOS `MilestoneNotifier`'s `NotifierState`.
    private struct NotifierState: Codable {
        var lastRemaining: [String: Double] = [:]
        var costFired: [String] = []
        var burnCooldown: [String: Date] = [:]
        var resetsAt: [String: Date] = [:]

        // Fields were added over time; older files must still decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastRemaining = try c.decodeIfPresent([String: Double].self, forKey: .lastRemaining) ?? [:]
            costFired = try c.decodeIfPresent([String].self, forKey: .costFired) ?? []
            burnCooldown = try c.decodeIfPresent([String: Date].self, forKey: .burnCooldown) ?? [:]
            resetsAt = try c.decodeIfPresent([String: Date].self, forKey: .resetsAt) ?? [:]
        }

        // Declared explicitly: a custom `init(from:)` in the main declaration
        // suppresses the synthesised memberwise init.
        init(lastRemaining: [String: Double], costFired: [String],
             burnCooldown: [String: Date], resetsAt: [String: Date]) {
            self.lastRemaining = lastRemaining
            self.costFired = costFired
            self.burnCooldown = burnCooldown
            self.resetsAt = resetsAt
        }
    }

    init(settings: LinuxSettings, paths: any AppPaths = FileManagerPaths()) {
        self.settings = settings
        self.paths = paths
        if let state = AppStateFiles.load(NotifierState.self, from: Self.stateFile, paths: paths) {
            lastRemaining = state.lastRemaining
            burnCooldown = state.burnCooldown
            lastResetsAt = state.resetsAt
            costFired = Set(state.costFired)
        }
    }

    /// Drop spent day-keys so the file cannot grow without bound. Yesterday is
    /// kept so a clock change or a late poll cannot re-open a spent gate.
    private func pruneCostFired(now: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = today.addingTimeInterval(-86400)
        costFired = costFired.filter { key in
            guard let day = Double(key.split(separator: "|").last ?? "") else { return false }
            let start = Date(timeIntervalSince1970: day)
            return start >= yesterday && start <= today.addingTimeInterval(86400)
        }
    }

    private func saveState(now: Date) {
        pruneCostFired(now: now)
        AppStateFiles.save(
            NotifierState(
                lastRemaining: lastRemaining,
                costFired: Array(costFired),
                burnCooldown: burnCooldown,
                resetsAt: lastResetsAt
            ),
            to: Self.stateFile, paths: paths)
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
        saveState(now: now)
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
        saveState(now: now)
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

        // Resolved from PATH, not hardcoded: `notify-send` lives in different
        // places per distro and is absent on minimal installs, where every
        // alert would otherwise vanish without a trace.
        guard let tool = ExternalTool.locate(named: "notify-send") else {
            lastError = "notify-send not found — desktop alerts are disabled "
                + "(install your distro's libnotify/notify-tools package)"
            return
        }
        lastError = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [title, body]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
