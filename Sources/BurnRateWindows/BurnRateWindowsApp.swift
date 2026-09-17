import BurnRateCore
import CBurnRateWin32
import Foundation

/// Fetches usage from every configured provider.
private actor WindowsPoller {
    private let providers: [any UsageProvider]
    private let costSources: [(name: String, source: any UsageSource)]

    init() {
        self.providers = [
            ClaudeUsageAPIProvider(),
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: CodexUsageSource()),
        ]
        self.costSources = [
            ("Claude", ClaudeUsageSource()),
            ("OpenCode", OpenCodeUsageSource()),
            ("Codex", CodexUsageSource()),
        ]
    }

    func snapshot() async -> (text: String, usage: [ProviderUsage],
                              buckets: [(provider: String, samples: [UsageSample])],
                              costs: [(provider: String, cost: Double)]) {
        var usage: [ProviderUsage] = []
        for provider in providers {
            if let result = await provider.fetchUsage(capacities: PlanCapacities.byProviderWindow) {
                usage.append(result)
            }
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        var buckets: [(provider: String, samples: [UsageSample])] = []
        var costs: [(provider: String, cost: Double)] = []
        for (name, source) in costSources {
            let samples = (try? await source.collectSamples()) ?? []
            buckets.append((name, samples))
            let spend = samples
                .filter { $0.timestamp >= todayStart }
                .reduce(0.0) { $0 + PricingService.shared.cost(of: $1) }
            costs.append((name, spend))
        }

        var lines: [String] = []
        for entry in usage {
            lines.append(entry.plan.map { "\(entry.providerName) - \($0)" } ?? entry.providerName)
            for window in entry.windows {
                let percent = window.percentRemaining.map { String(format: "%.0f", $0) } ?? "--"
                var detail = "\(percent)%"
                if let resetsAt = window.resetsAt {
                    detail += " · resets \(RelativeTime.format(resetsAt))"
                }
                lines.append("    \(window.label): \(detail)")
            }
            lines.append("")
        }
        let text = lines.isEmpty
            ? "No providers configured.\r\n\r\nLog in to a supported CLI, then press Refresh."
            : lines.joined(separator: "\r\n")

        var modelLines: [String] = []
        for entry in ModelUsageAggregator.totals(buckets: buckets).prefix(10) {
            modelLines.append("    \(entry.displayName): \(TokenFormat.format(entry.totalTokens)) tokens · \(entry.requests) req")
        }
        let modelText = modelLines.isEmpty ? "" : "\r\n\r\nModels (30d)\r\n" + modelLines.joined(separator: "\r\n")
        return (text + modelText, usage, buckets, costs)
    }
}

/// Desktop alerts via tray balloons.
private final class WindowsNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRemaining: [String: Double] = [:]
    private var lastResetsAt: [String: Date] = [:]
    private var burnCooldown: [String: Date] = [:]
    private var history: [String: [(date: Date, remaining: Double)]] = [:]
    private var recent: [String: Date] = [:]
    private var costFired: Set<String> = []

    private let milestones = AlertDefaults.milestones
    private let burnAlerts = AlertDefaults.burnAlerts
    private static let burnCooldownInterval: TimeInterval = 1800

    func evaluate(_ usage: [ProviderUsage], now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        for provider in usage {
            for window in provider.windows {
                guard let current = window.percentRemaining else { continue }
                let previous = lastRemaining[window.id]
                lastRemaining[window.id] = current

                var isReset = false
                if let previousResets = lastResetsAt[window.id], let resetsAt = window.resetsAt,
                   resetsAt > previousResets, current > (previous ?? 0) { isReset = true }
                if let previous, current - previous >= 40 { isReset = true }
                if let resetsAt = window.resetsAt { lastResetsAt[window.id] = resetsAt }
                if previous != nil, isReset {
                    send("\(provider.providerName) \(window.label) reset",
                         String(format: "Window reset — %.0f%% remaining.", current))
                }

                let band: Double? = milestones
                    .filter { $0.provider == provider.providerName && $0.windowLabel == window.label }
                    .compactMap {
                        MilestoneEvaluator.crossedThreshold(previousRemaining: previous,
                                                            currentRemaining: current, step: $0.step)
                    }
                    .max()
                if let band {
                    send("\(provider.providerName) \(window.label) milestone",
                         String(format: "Only %.0f%% of your %@ window remaining (crossed below %.0f%%).",
                                current, window.label, band))
                }

                recordHistory(windowID: window.id, date: now, remaining: current)
                evaluateBurn(provider: provider.providerName, window: window, now: now)
            }
        }
    }

    func evaluateCosts(_ costs: [(provider: String, cost: Double)]) {
        lock.lock()
        defer { lock.unlock() }
        let dayKey = String(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let alerts: [CostAlert] = []
        for alert in alerts {
            let key = "\(alert.provider)|\(dayKey)"
            guard !costFired.contains(key),
                  let spend = costs.first(where: { $0.provider == alert.provider })?.cost,
                  spend >= alert.dailyLimitUSD else { continue }
            costFired.insert(key)
            send("\(alert.provider) daily spend",
                 String(format: "$%.2f spent today (limit $%.2f).", spend, alert.dailyLimitUSD))
        }
    }

    private func recordHistory(windowID: String, date: Date, remaining: Double) {
        var entries = history[windowID] ?? []
        entries.append((date, remaining))
        let cutoff = date.addingTimeInterval(-6 * 3600)
        history[windowID] = entries.filter { $0.date >= cutoff }
    }

    private func evaluateBurn(provider: String, window: UsageWindow, now: Date) {
        if let until = burnCooldown[window.id], now < until { return }
        guard let alert = burnAlerts.first(where: {
            $0.provider == provider && $0.windowLabel == window.label
        }) else { return }
        guard let hit = BurnRateEvaluator.detect(
            history: history[window.id] ?? [], alert: alert, now: now, pollInterval: 300
        ) else { return }
        burnCooldown[window.id] = now.addingTimeInterval(Self.burnCooldownInterval)
        send("\(provider) \(window.label) burning fast",
             String(format: "%.0f%% drop in %d min: %.0f%% → %.0f%% remaining.",
                    hit.drop, alert.minutes, hit.baseline, hit.current))
    }

    private func send(_ title: String, _ body: String) {
        let key = title + "|" + body
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        guard recent[key] == nil else { return }
        recent[key] = now
        title.withCString { titlePointer in
            body.withCString { bodyPointer in
                br_notify(titlePointer, bodyPointer)
            }
        }
    }
}

private final class ActionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [StatusMenuAction] = []
    func replace(_ newActions: [StatusMenuAction]) { lock.withLock { actions = newActions } }
    func action(at index: Int32) -> StatusMenuAction? {
        lock.withLock { (index >= 0 && Int(index) < actions.count) ? actions[Int(index)] : nil }
    }
}

private final class AppState: @unchecked Sendable {
    private let lock = NSLock()
    private var _mainTray: Int32 = -1
    private var _trayActions: [Int32: ActionStore] = [:]
    private var _lastUsage: [ProviderUsage] = []

    var mainTray: Int32 { lock.withLock { _mainTray } }
    func setMainTray(_ value: Int32) { lock.withLock { _mainTray = value } }
    func actionStore(_ tray: Int32) -> ActionStore? { lock.withLock { _trayActions[tray] } }
    func setActionStore(_ store: ActionStore, for tray: Int32) { lock.withLock { _trayActions[tray] = store } }
    func lastUsage() -> [ProviderUsage] { lock.withLock { _lastUsage } }
    func setLastUsage(_ usage: [ProviderUsage]) { lock.withLock { _lastUsage = usage } }
}

private final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [RemainingSample] = []
    func append(usage: [ProviderUsage], date: Date) {
        lock.withLock {
            for entry in usage {
                for window in entry.windows {
                    guard let remaining = window.percentRemaining else { continue }
                    samples.append(RemainingSample(provider: entry.providerName, label: window.label,
                                                   date: date, remaining: remaining))
                }
            }
            let cutoff = date.addingTimeInterval(-7 * 86400)
            samples = samples.filter { $0.date >= cutoff }
        }
    }
    func snapshot() -> [RemainingSample] { lock.withLock { samples } }
}

private let poller = WindowsPoller()
private let notifier = WindowsNotifier()
private let state = AppState()
private let history = HistoryStore()

private let modelPalette: [(Double, Double, Double)] = [
    (0.85, 0.47, 0.34), (0.25, 0.55, 0.95), (0.20, 0.68, 0.44), (0.72, 0.45, 0.85),
    (0.95, 0.62, 0.24), (0.30, 0.72, 0.78), (0.83, 0.36, 0.55), (0.55, 0.60, 0.35),
]

private func providerRGB(_ provider: String) -> (Double, Double, Double) {
    switch provider {
    case "Claude": (0.85, 0.47, 0.34)
    case "OpenCode Go", "OpenCode": (0.25, 0.55, 0.95)
    case "Codex": (0.20, 0.68, 0.44)
    default: (0.6, 0.6, 0.6)
    }
}

private func handleAction(_ action: StatusMenuAction) {
    switch action {
    case .openCharts, .openDashboard, .openSettings, .removeWidget:
        break
    case .checkForUpdates, .installUpdate:
        br_open_url("https://github.com/RichardODonoghue/burnrate/releases")
    case .quit:
        br_win_quit()
    }
}

private func onTrayAction(_ tray: Int32, _ actionID: Int32, _ context: UnsafeMutableRawPointer?) {
    if let action = state.actionStore(tray)?.action(at: actionID) {
        handleAction(action)
    }
}

private func setTrayItems(_ tray: Int32, model: StatusMenuModel) {
    var rows: [(label: String, action: Int32, enabled: Bool)] = []
    var actions: [StatusMenuAction] = []
    for entry in model.entries {
        switch entry {
        case .providerHeader(let title):
            rows.append((title, -1, false))
        case .windowRow(let label, let detail):
            rows.append(("  \(label): \(detail)", -1, false))
        case .text(let text):
            rows.append((text, -1, false))
        case .separator:
            rows.append(("", -2, false))
        case .action(let title, let action, let isEnabled):
            rows.append((title, Int32(actions.count), isEnabled))
            actions.append(action)
        }
    }

    var pointers: [UnsafeMutablePointer<CChar>?] = []
    var items: [br_tray_item] = []
    for row in rows {
        let pointer = strdup(row.label)
        pointers.append(pointer)
        items.append(br_tray_item(label: pointer.map { UnsafePointer($0) },
                                  action_id: row.action,
                                  enabled: row.enabled ? 1 : 0))
    }
    items.withUnsafeBufferPointer { buffer in
        br_tray_set_items(tray, buffer.baseAddress, Int32(buffer.count))
    }
    for pointer in pointers { free(pointer) }
    state.actionStore(tray)?.replace(actions)
}

private func updateCharts(buckets: [(provider: String, samples: [UsageSample])]) {
    let samples = history.snapshot()
    let cutoff = TrendChartData.trendCutoff(for: .week, now: Date())
    let series = TrendChartData.buildTrendSeries(
        samples: samples, label: "Rolling", providerFilter: nil, cutoff: cutoff)

    if !series.isEmpty {
        let dates = series.flatMap { $0.samples.map(\.date) }
        if let minDate = dates.min(), let maxDate = dates.max() {
            let span = max(maxDate.timeIntervalSince(minDate), 1)
            var points: [br_trend_point] = []
            var rgb: [Double] = []
            for (index, item) in series.enumerated() {
                let color = providerRGB(item.provider)
                rgb.append(contentsOf: [color.0, color.1, color.2])
                for point in item.samples {
                    let x = max(0, min(1, point.date.timeIntervalSince(minDate) / span))
                    points.append(br_trend_point(series: Int32(index), x: x, y: point.remaining))
                }
            }
            points.withUnsafeBufferPointer { pointBuffer in
                rgb.withUnsafeBufferPointer { rgbBuffer in
                    br_chart_set_trend(pointBuffer.baseAddress, Int32(pointBuffer.count),
                                       rgbBuffer.baseAddress, Int32(series.count))
                }
            }
        }
    }

    let totals = Array(ModelUsageAggregator.totals(buckets: buckets).prefix(8))
    if !totals.isEmpty {
        let maxTokens = Double(totals.map(\.totalTokens).max() ?? 1)
        var values: [Double] = []
        var colors: [Double] = []
        var labels: [String] = []
        for entry in totals {
            let color = modelPalette[abs(entry.displayName.hashValue) % modelPalette.count]
            values.append(maxTokens > 0 ? Double(entry.totalTokens) / maxTokens : 0)
            colors.append(contentsOf: [color.0, color.1, color.2])
            labels.append(entry.displayName)
        }
        values.withUnsafeBufferPointer { valueBuffer in
            colors.withUnsafeBufferPointer { colorBuffer in
                labels.joined(separator: "\n").withCString { labelPointer in
                    br_chart_set_bars(valueBuffer.baseAddress, colorBuffer.baseAddress,
                                      Int32(values.count), labelPointer)
                }
            }
        }
    }

    let daily = ModelUsageAggregator.daily(buckets: buckets, days: 14)
    if !daily.isEmpty {
        var segments: [br_bar_segment] = []
        for (dayIndex, day) in daily.enumerated() {
            for entry in day.entries {
                let color = modelPalette[abs(entry.displayName.hashValue) % modelPalette.count]
                segments.append(br_bar_segment(day: Int32(dayIndex), value: Double(entry.totalTokens),
                                               red: color.0, green: color.1, blue: color.2))
            }
        }
        segments.withUnsafeBufferPointer { buffer in
            br_chart_set_daily(buffer.baseAddress, Int32(segments.count), Int32(daily.count))
        }
    }
}

private func onRefresh(_ context: UnsafeMutableRawPointer?) {
    Task.detached {
        let result = await poller.snapshot()
        result.text.withCString { br_win_post($0) }
        history.append(usage: result.usage, date: Date())
        state.setLastUsage(result.usage)
        if state.mainTray >= 0 {
            setTrayItems(state.mainTray,
                         model: StatusMenuBuilder.mainMenu(usage: result.usage, updateVersion: nil, isBusy: false))
        }
        notifier.evaluate(result.usage)
        notifier.evaluateCosts(result.costs)
        updateCharts(buckets: result.buckets)
    }
}

@main
struct BurnRateWindowsMain {
    static func main() {
        let tray = br_tray_add("BurnRate", onTrayAction, nil)
        state.setMainTray(tray)
        if tray >= 0 {
            state.setActionStore(ActionStore(), for: tray)
        }
        br_win_run("BurnRate", "Loading usage…", onRefresh, nil)
        br_tray_stop_all()
    }
}
