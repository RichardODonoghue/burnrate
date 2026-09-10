import Foundation
import UserNotifications

/// Shows banners with sound even when the dashboard window is frontmost.
/// Without a delegate, UNUserNotificationCenter delivers quietly to
/// Notification Center while our app is active.
private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Evaluates milestones and burn-rate alerts after each poll, posting
/// desktop notifications.
@MainActor
final class MilestoneNotifier {
    private let foregroundDelegate = ForegroundNotificationDelegate()
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
    /// Last-seen window reset time per window id (reset detection).
    private var lastResetsAt: [String: Date] = [:]
    /// Recently sent notifications (title|body → time), to suppress duplicates.
    private var recentSends: [String: Date] = [:]
    private let defaults: UserDefaults

    nonisolated static let pollInterval: TimeInterval = 300
    /// History older than this can't affect any alert (largest window + slack).
    nonisolated static let historyRetention: TimeInterval = 6 * 3600
    nonisolated static let burnCooldownInterval: TimeInterval = 1800
    private static let stateKey = "notifierState"

    /// Alert bookkeeping persisted across launches — otherwise every restart
    /// re-fires all breached milestones (previousRemaining empty → "crossing")
    /// and resets cost/burn cooldowns.
    private struct NotifierState: Codable {
        var lastRemaining: [String: Double] = [:]
        var costFired: [String] = []
        var burnCooldown: [String: Date] = [:]
        var modelBurnCooldown: [String: Date] = [:]
        /// Last-seen window reset time per window id — a vendor API moving a
        /// window's resetsAt forward means a fresh window began.
        var resetsAt: [String: Date] = [:]

        // Custom decoding: resetsAt was added later; older persisted states
        // must still decode.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastRemaining = try c.decodeIfPresent([String: Double].self, forKey: .lastRemaining) ?? [:]
            costFired = try c.decodeIfPresent([String].self, forKey: .costFired) ?? []
            burnCooldown = try c.decodeIfPresent([String: Date].self, forKey: .burnCooldown) ?? [:]
            modelBurnCooldown = try c.decodeIfPresent([String: Date].self, forKey: .modelBurnCooldown) ?? [:]
            resetsAt = try c.decodeIfPresent([String: Date].self, forKey: .resetsAt) ?? [:]
        }

        init(lastRemaining: [String: Double], costFired: [String],
             burnCooldown: [String: Date], modelBurnCooldown: [String: Date],
             resetsAt: [String: Date]) {
            self.lastRemaining = lastRemaining
            self.costFired = costFired
            self.burnCooldown = burnCooldown
            self.modelBurnCooldown = modelBurnCooldown
            self.resetsAt = resetsAt
        }
    }

    init(settingsStore: SettingsStore, defaults: UserDefaults = .standard) {
        self.settingsStore = settingsStore
        self.defaults = defaults
        // Retained strongly (UNUserNotificationCenter holds its delegate
        // weakly); set before any notification can be posted.
        UNUserNotificationCenter.current().delegate = foregroundDelegate
        if let data = defaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(NotifierState.self, from: data) {
            lastRemaining = state.lastRemaining
            costFired = Set(state.costFired)
            burnCooldown = state.burnCooldown
            modelBurnCooldown = state.modelBurnCooldown
            lastResetsAt = state.resetsAt
        }
        Task { await requestAuthorization() }
    }

    private func saveState() {
        let state = NotifierState(
            lastRemaining: lastRemaining,
            costFired: Array(costFired),
            burnCooldown: burnCooldown,
            modelBurnCooldown: modelBurnCooldown,
            resetsAt: lastResetsAt
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey)
        }
    }

    private func requestAuthorization() async {
        // UNUserNotificationCenter needs a real app bundle; fall back to logging
        // when run via `swift run` without one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        // Only .notDetermined prompts; otherwise this is a no-op status read.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            NSLog("%@", "[milestone] notification authorization granted=\(granted)")
        } catch {
            NSLog("%@", "[milestone] notification authorization failed: \(error)")
        }
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

                // Window reset. Primary signal: the vendor API moved the
                // window's resetsAt forward — a fresh window began, no
                // matter how much remaining jumped (the old window may end
                // at >60% remaining, e.g. after hours of idle). Fallback
                // for sources without resetsAt: remaining jumped up ≥40.
                var isReset = false
                if let previousResets = lastResetsAt[window.id],
                   let resetsAt = window.resetsAt,
                   resetsAt > previousResets,
                   current > (previous ?? 0) {
                    isReset = true
                }
                if let previous, current - previous >= 40 {
                    isReset = true
                }
                if let resetsAt = window.resetsAt {
                    lastResetsAt[window.id] = resetsAt
                }
                if settingsStore.notifyOnReset, let previous, isReset {
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
        saveState()
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
        saveState()
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
        saveState()
    }

    private func recordHistory(windowID: String, date: Date, remaining: Double) {
        var entries = history[windowID] ?? []
        entries.append((date, remaining))
        let cutoff = date.addingTimeInterval(-Self.historyRetention)
        history[windowID] = entries.filter { $0.date >= cutoff }
    }

    private func evaluateBurnAlerts(provider: String, window: UsageWindow, now: Date) {
        guard window.percentRemaining != nil else { return }
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

    private func send(title: String, body: String, dedupe: Bool = true) {
        // Suppress duplicates (double polls, stray second instances, etc.).
        let key = title + "|" + body
        let now = Date()
        recentSends = recentSends.filter { now.timeIntervalSince($0.value) < 60 }
        if dedupe {
            guard recentSends[key] == nil else { return }
        }
        recentSends[key] = now

        guard Bundle.main.bundleIdentifier != nil else {
            // Body contains "%" — never pass it as an NSLog format string.
            NSLog("%@", "[milestone] \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
