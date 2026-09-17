import BurnRateCore
import CBurnRateGTK
import CBurnRateTray
import Foundation
import Glibc

/// Fetches usage from every configured provider.
private actor LinuxPoller {
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
            ? "No providers configured.\n\nLog in to a supported CLI, then press Refresh."
            : lines.joined(separator: "\n")

        var modelLines: [String] = []
        let totals = ModelUsageAggregator.totals(buckets: buckets)
        for entry in totals.prefix(10) {
            modelLines.append("    \(entry.displayName): \(TokenFormat.format(entry.totalTokens)) tokens · \(entry.requests) req")
        }
        let modelText = modelLines.isEmpty ? "" : "\nModels (30d)\n" + modelLines.joined(separator: "\n")
        return (text + modelText, usage, buckets, costs)
    }
}

/// Per-tray click handlers, guarded because D-Bus callbacks arrive on other threads.
private final class ActionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [StatusMenuAction] = []

    func replace(_ newActions: [StatusMenuAction]) {
        lock.withLock { actions = newActions }
    }

    func action(at index: Int32) -> StatusMenuAction? {
        lock.withLock { (index >= 0 && Int(index) < actions.count) ? actions[Int(index)] : nil }
    }
}

/// Shared app state, guarded for access from the GTK thread, D-Bus callbacks
/// and the background poller.
private final class AppState: @unchecked Sendable {
    private let lock = NSLock()
    private var _mainTray: Int32 = -1
    private var _trayActions: [Int32: ActionStore] = [:]
    private var _widgetTrays: [String: Int32] = [:]
    private var _settingsProviders: [String] = []
    private var _lastUsage: [ProviderUsage] = []

    var mainTray: Int32 { lock.withLock { _mainTray } }
    func setMainTray(_ value: Int32) { lock.withLock { _mainTray = value } }

    func actionStore(_ tray: Int32) -> ActionStore? { lock.withLock { _trayActions[tray] } }
    func setActionStore(_ store: ActionStore, for tray: Int32) { lock.withLock { _trayActions[tray] = store } }
    func removeActionStore(_ tray: Int32) { lock.withLock { _ = _trayActions.removeValue(forKey: tray) } }

    func widgetTrays() -> [String: Int32] { lock.withLock { _widgetTrays } }
    func widgetTray(_ provider: String) -> Int32? { lock.withLock { _widgetTrays[provider] } }
    func setWidgetTray(_ tray: Int32, for provider: String) { lock.withLock { _widgetTrays[provider] = tray } }
    func removeWidgetTray(_ provider: String) -> Int32? { lock.withLock { _widgetTrays.removeValue(forKey: provider) } }

    var settingsProviders: [String] { lock.withLock { _settingsProviders } }
    func setSettingsProviders(_ providers: [String]) { lock.withLock { _settingsProviders = providers } }

    func lastUsage() -> [ProviderUsage] { lock.withLock { _lastUsage } }
    func setLastUsage(_ usage: [ProviderUsage]) { lock.withLock { _lastUsage = usage } }
}

private let poller = LinuxPoller()
private let settings = LinuxSettings()
private let notifier = LinuxNotifier(settings: settings)
private let state = AppState()

/// In-memory remaining-% history for the trend chart (app lifetime).
private final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [RemainingSample] = []
    private static let retention: TimeInterval = 7 * 86400

    func append(usage: [ProviderUsage], date: Date) {
        lock.withLock {
            for entry in usage {
                for window in entry.windows {
                    guard let remaining = window.percentRemaining else { continue }
                    samples.append(RemainingSample(provider: entry.providerName, label: window.label,
                                                   date: date, remaining: remaining))
                }
            }
            let cutoff = date.addingTimeInterval(-Self.retention)
            samples = samples.filter { $0.date >= cutoff }
        }
    }

    func snapshot() -> [RemainingSample] { lock.withLock { samples } }
}

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

/// Pushes the trend and ranking charts from core chart data.
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
                segments.append(br_bar_segment(day: Int32(dayIndex),
                                               value: Double(entry.totalTokens),
                                               red: color.0, green: color.1, blue: color.2))
            }
        }
        segments.withUnsafeBufferPointer { buffer in
            br_chart_set_daily(buffer.baseAddress, Int32(segments.count), Int32(daily.count))
        }
    }
}

/// Opens the GitHub releases page (Linux has no in-app updater yet).
private func openReleases() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
    process.arguments = ["https://github.com/RichardODonoghue/burnrate/releases"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

private func handleAction(_ action: StatusMenuAction) {
    switch action {
    case .openDashboard:
        break // the window is already presented on Linux
    case .openCharts:
        br_chart_show("BurnRate Charts")
    case .openSettings:
        showSettings()
    case .checkForUpdates, .installUpdate:
        openReleases()
    case .quit:
        br_ui_quit()
    case .removeWidget(let provider):
        settings.setWidget(provider, enabled: false)
        syncWidgetTrays()
    }
}

private func onTrayAction(_ tray: Int32, _ actionID: Int32, _ context: UnsafeMutableRawPointer?) {
    if let action = state.actionStore(tray)?.action(at: actionID) {
        handleAction(action)
    }
}

/// Builds `br_tray_item`s for a model and records the actions for `tray`.
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

private func updateMainTray(usage: [ProviderUsage]) {
    guard state.mainTray >= 0 else { return }
    setTrayItems(state.mainTray, model: StatusMenuBuilder.mainMenu(
        usage: usage, updateVersion: nil, isBusy: false, includesCharts: true))
}

/// Creates/removes per-provider widget trays to match settings.
private func syncWidgetTrays(usage: [ProviderUsage]? = nil) {
    let enabled = settings.snapshot.widgetProviders
    let currentUsage = usage ?? state.lastUsage()

    // Remove disabled widgets.
    for (provider, tray) in state.widgetTrays() where !enabled.contains(provider) {
        br_tray_remove(tray)
        _ = state.removeWidgetTray(provider)
        state.removeActionStore(tray)
    }

    // Add/update enabled widgets (each is its own tray item).
    for provider in enabled {
        var tray = state.widgetTray(provider)
        if tray == nil {
            let created = br_tray_add("utilities-system-monitor", provider, onTrayAction, nil)
            if created >= 0 {
                tray = created
                state.setWidgetTray(created, for: provider)
                state.setActionStore(ActionStore(), for: created)
            }
        }
        guard let tray else { continue }
        let widget = StatusMenuBuilder.widget(
            provider: provider, usage: currentUsage.first { $0.providerName == provider })
        br_tray_set_title(tray, widget.title)
        setTrayItems(tray, model: widget.menu)
    }
}

/// GTK calls this on the main thread when a settings checkbox is toggled.
private func onSettingsToggle(_ id: Int32, _ checked: Int32, _ context: UnsafeMutableRawPointer?) {
    let enabled = checked != 0
    if id == 0 {
        settings.setNotifyOnReset(enabled)
        return
    }
    let providers = state.settingsProviders
    let index = Int(id) - 1
    guard index >= 0, index < providers.count else { return }
    settings.setWidget(providers[index], enabled: enabled)
    syncWidgetTrays()
}

/// GTK calls this on the main thread when a milestone step changes.
private func onSettingsSpin(_ id: Int32, _ value: Double, _ context: UnsafeMutableRawPointer?) {
    switch id {
    case 1000..<2000:
        settings.setMilestoneStep(at: Int(id) - 1000, step: value.rounded())
    case 2000..<3000:
        settings.setBurnAlert(at: Int(id) - 2000, drop: value.rounded(), minutes: nil)
    case 3000..<4000:
        settings.setBurnAlert(at: Int(id) - 3000, drop: nil, minutes: value.rounded())
    case 4000..<5000:
        settings.setCostAlertLimit(at: Int(id) - 4000, limit: value)
    default:
        break
    }
}

private func showSettings() {
    let providers = state.lastUsage().map(\.providerName).sorted()
    state.setSettingsProviders(providers)
    let values = settings.snapshot

    var checks: [(label: String, id: Int32, checked: Bool)] = [
        ("Notify when a window resets", 0, values.notifyOnReset),
    ]
    for (index, provider) in providers.enumerated() {
        checks.append(("Menu-bar widget for \(provider)", Int32(index + 1),
                       values.widgetProviders.contains(provider)))
    }

    var spins: [(label: String, id: Int32, value: Double, minimum: Double, maximum: Double)] = []
    for (index, milestone) in values.milestones.enumerated() {
        spins.append(("\(milestone.provider) \(milestone.windowLabel) — every %",
                      Int32(1000 + index), milestone.step, 5, 50))
    }
    for (index, alert) in values.burnAlerts.enumerated() {
        spins.append(("\(alert.provider) \(alert.windowLabel) burn drop %",
                      Int32(2000 + index), alert.percentDrop, 5, 95))
        spins.append(("\(alert.provider) \(alert.windowLabel) burn window (min)",
                      Int32(3000 + index), Double(alert.minutes), 15, 120))
    }
    for (index, alert) in values.costAlerts.enumerated() {
        spins.append(("\(alert.provider) daily limit $",
                      Int32(4000 + index), alert.dailyLimitUSD, 1, 1000))
    }

    var pointers: [UnsafeMutablePointer<CChar>?] = []
    var checkItems: [br_checkbox] = []
    for row in checks {
        let pointer = strdup(row.label)
        pointers.append(pointer)
        checkItems.append(br_checkbox(label: pointer.map { UnsafePointer($0) }, id: row.id,
                                      checked: row.checked ? 1 : 0))
    }
    var spinItems: [br_spin] = []
    for row in spins {
        let pointer = strdup(row.label)
        pointers.append(pointer)
        spinItems.append(br_spin(label: pointer.map { UnsafePointer($0) }, id: row.id,
                                 value: row.value, minimum: row.minimum, maximum: row.maximum))
    }

    checkItems.withUnsafeBufferPointer { checkBuffer in
        spinItems.withUnsafeBufferPointer { spinBuffer in
            br_settings_show("BurnRate Settings",
                             checkBuffer.baseAddress, Int32(checkBuffer.count),
                             spinBuffer.baseAddress, Int32(spinBuffer.count),
                             onSettingsToggle, onSettingsSpin, nil)
        }
    }
    for pointer in pointers { free(pointer) }
}

/// GTK calls this on the main thread (window shown, Refresh, 5-min timer).
private func onRefresh(_ context: UnsafeMutableRawPointer?) {
    Task.detached {
        let result = await poller.snapshot()
        result.text.withCString { br_ui_post($0) }
        history.append(usage: result.usage, date: Date())
        state.setLastUsage(result.usage)
        updateMainTray(usage: result.usage)
        syncWidgetTrays(usage: result.usage)
        notifier.evaluate(result.usage)
        notifier.evaluateCosts(result.costs)
        updateCharts(buckets: result.buckets)
    }
}

@main
struct BurnRateLinuxMain {
    static func main() {
        // Tray is best-effort: without a session bus / watcher the app still runs.
        let tray = br_tray_add("utilities-system-monitor", "BurnRate", onTrayAction, nil)
        state.setMainTray(tray)
        if tray >= 0 {
            state.setActionStore(ActionStore(), for: tray)
        }
        syncWidgetTrays()
        br_ui_run("BurnRate", "Loading usage…", onRefresh, nil)
        br_tray_stop_all()
    }
}
