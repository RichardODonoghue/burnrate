import BurnRateCore
import CBurnRateGTK
import CBurnRateTray
import Foundation
import Glibc

/// Fetches usage from every configured provider.
private actor LinuxPoller {
    private let providers: [any UsageProvider]

    init() {
        self.providers = [
            ClaudeUsageAPIProvider(),
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: CodexUsageSource()),
        ]
    }

    func snapshot() async -> (text: String, usage: [ProviderUsage]) {
        var usage: [ProviderUsage] = []
        for provider in providers {
            if let result = await provider.fetchUsage(capacities: PlanCapacities.byProviderWindow) {
                usage.append(result)
            }
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
        return (text, usage)
    }
}

private let poller = LinuxPoller()

/// Tray click → action, guarded because D-Bus callbacks arrive on another thread.
private final class ActionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [StatusMenuAction] = []

    func replace(_ newActions: [StatusMenuAction]) {
        lock.lock()
        actions = newActions
        lock.unlock()
    }

    func action(at index: Int32) -> StatusMenuAction? {
        lock.lock()
        defer { lock.unlock() }
        return (index >= 0 && Int(index) < actions.count) ? actions[Int(index)] : nil
    }
}

private let actionStore = ActionStore()

private func handleAction(_ action: StatusMenuAction) {
    switch action {
    case .openDashboard, .openSettings:
        break // the window is already presented on Linux
    case .quit:
        br_ui_quit()
    default:
        break // updates / widgets are not wired on Linux yet
    }
}

private func onTrayAction(_ actionID: Int32, _ context: UnsafeMutableRawPointer?) {
    if let action = actionStore.action(at: actionID) {
        handleAction(action)
    }
}

/// Mirrors the macOS tray menu using the shared `StatusMenuBuilder`.
private func updateTray(usage: [ProviderUsage]) {
    let model = StatusMenuBuilder.mainMenu(usage: usage, updateVersion: nil, isBusy: false)
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

    actionStore.replace(actions)

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
        br_tray_set_items(buffer.baseAddress, Int32(buffer.count))
    }
    for pointer in pointers { free(pointer) }
}

/// GTK calls this on the main thread (window shown, Refresh, 5-min timer).
private func onRefresh(_ context: UnsafeMutableRawPointer?) {
    Task.detached {
        let result = await poller.snapshot()
        result.text.withCString { br_ui_post($0) }
        updateTray(usage: result.usage)
    }
}

@main
struct BurnRateLinuxMain {
    static func main() {
        // Tray is best-effort: without a session bus / watcher the app still runs.
        _ = br_tray_start("utilities-system-monitor", "BurnRate", onTrayAction, nil)
        br_ui_run("BurnRate", "Loading usage…", onRefresh, nil)
        br_tray_stop()
    }
}
