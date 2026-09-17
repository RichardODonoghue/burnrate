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

    func snapshot() async -> (text: String, usage: [ProviderUsage], costs: [(provider: String, cost: Double)]) {
        var usage: [ProviderUsage] = []
        for provider in providers {
            if let result = await provider.fetchUsage(capacities: PlanCapacities.byProviderWindow) {
                usage.append(result)
            }
        }

        let todayStart = Calendar.current.startOfDay(for: Date())
        var costs: [(provider: String, cost: Double)] = []
        for (name, source) in costSources {
            let samples = (try? await source.collectSamples()) ?? []
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
        return (text, usage, costs)
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
    func removeActionStore(_ tray: Int32) { lock.withLock { _trayActions.removeValue(forKey: tray) } }

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
    setTrayItems(state.mainTray, model: StatusMenuBuilder.mainMenu(usage: usage, updateVersion: nil, isBusy: false))
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
    settings.setMilestoneStep(at: Int(id) - 1000, step: value.rounded())
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
    var spins: [(label: String, id: Int32, value: Double)] = []
    for (index, milestone) in values.milestones.enumerated() {
        spins.append(("\(milestone.provider) \(milestone.windowLabel) — every %",
                      Int32(1000 + index), milestone.step))
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
                                 value: row.value, minimum: 5, maximum: 50))
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
        state.setLastUsage(result.usage)
        updateMainTray(usage: result.usage)
        syncWidgetTrays(usage: result.usage)
        notifier.evaluate(result.usage)
        notifier.evaluateCosts(result.costs)
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
