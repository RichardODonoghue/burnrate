import Foundation

/// An action a tray menu row can trigger. The host decides how to perform it.
public enum StatusMenuAction: Sendable, Equatable {
    case openDashboard
    case openCharts
    case openSettings
    case checkForUpdates
    case installUpdate(version: String)
    case removeWidget(provider: String)
    case quit
}

/// One row in a tray menu.
public enum StatusMenuEntry: Sendable, Equatable {
    /// Provider heading, e.g. "Claude - Team 5x".
    case providerHeader(title: String)
    /// Window row: label plus preformatted detail ("82% · resets in 4h").
    case windowRow(label: String, detail: String)
    /// Plain, non-interactive text row (e.g. "Loading usage…").
    case text(String)
    case separator
    case action(title: String, action: StatusMenuAction, isEnabled: Bool)
}

/// A complete tray menu, renderable by any platform.
public struct StatusMenuModel: Sendable, Equatable {
    public let entries: [StatusMenuEntry]

    public init(entries: [StatusMenuEntry]) {
        self.entries = entries
    }
}

/// An extra per-provider tray widget.
public struct StatusWidgetModel: Sendable, Equatable {
    public let provider: String
    public let title: String
    public let menu: StatusMenuModel

    public init(provider: String, title: String, menu: StatusMenuModel) {
        self.provider = provider
        self.title = title
        self.menu = menu
    }
}

/// Builds tray models from usage + updater state. Pure, so the menu contents
/// are testable without any OS UI.
public enum StatusMenuBuilder {
    public static func mainMenu(
        usage: [ProviderUsage],
        updateVersion: String?,
        isBusy: Bool,
        now: Date = Date()
    ) -> StatusMenuModel {
        var entries: [StatusMenuEntry] = []

        for provider in usage {
            let title = provider.plan.map { "\(provider.providerName) - \($0)" } ?? provider.providerName
            entries.append(.providerHeader(title: title))
            for window in provider.windows {
                entries.append(.windowRow(label: window.label, detail: detail(for: window, now: now)))
            }
            entries.append(.separator)
        }
        if usage.isEmpty {
            entries.append(.text("Loading usage…"))
            entries.append(.separator)
        }

        entries.append(.action(title: "Usage Dashboard…", action: .openDashboard, isEnabled: true))
        entries.append(.action(title: "Charts…", action: .openCharts, isEnabled: true))
        if let updateVersion {
            entries.append(.action(title: "Update to \(updateVersion)…",
                                   action: .installUpdate(version: updateVersion),
                                   isEnabled: !isBusy))
        } else {
            entries.append(.action(title: "Check for Updates…", action: .checkForUpdates, isEnabled: !isBusy))
        }
        entries.append(.action(title: "Settings…", action: .openSettings, isEnabled: true))
        entries.append(.action(title: "Quit", action: .quit, isEnabled: true))
        return StatusMenuModel(entries: entries)
    }

    /// Widget for a provider; `usage == nil` still yields a menu so the item
    /// isn't unresponsive.
    public static func widget(
        provider: String,
        usage: ProviderUsage?,
        now: Date = Date()
    ) -> StatusWidgetModel {
        var entries: [StatusMenuEntry] = []
        for window in usage?.windows ?? [] {
            entries.append(.windowRow(label: window.label, detail: detail(for: window, now: now)))
        }
        entries.append(.separator)
        entries.append(.action(title: "Remove widget", action: .removeWidget(provider: provider), isEnabled: true))
        return StatusWidgetModel(
            provider: provider,
            title: widgetTitle(provider: provider, usage: usage),
            menu: StatusMenuModel(entries: entries)
        )
    }

    /// Widget button text: Monthly % when present, else the first window's.
    public static func widgetTitle(provider: String, usage: ProviderUsage?) -> String {
        let percent = usage?.window(withLabel: "Monthly")?.percentRemaining
            ?? usage?.windows.first?.percentRemaining
        return "\(provider) \(percent.map { String(format: "%.0f%%", $0) } ?? "--")"
    }

    /// Lowest Rolling remaining across providers, for the icon severity.
    public static func worstRollingRemaining(usage: [ProviderUsage]) -> Double? {
        usage.compactMap { $0.window(withLabel: "Rolling")?.percentRemaining }.min()
    }

    private static func detail(for window: UsageWindow, now: Date) -> String {
        let percent = window.percentRemaining.map { String(format: "%.0f", $0) } ?? "--"
        var detail = "\(percent)%"
        if let resetsAt = window.resetsAt {
            detail += " · resets \(RelativeTime.format(resetsAt, now: now))"
        }
        return detail
    }
}

/// Renders tray models on a platform. macOS → `NSStatusBar`; Linux →
/// StatusNotifierItem/DBusMenu; Windows → `Shell_NotifyIcon`.
@MainActor
public protocol StatusItemPresenting {
    /// Invoked when the user picks a menu action; the host performs it.
    var onAction: ((StatusMenuAction) -> Void)? { get set }
    /// Render the always-present item. `remaining` (nil = rest pose) drives the
    /// icon severity.
    func renderMain(menu: StatusMenuModel, remaining: Double?)
    /// Create/update/remove widgets so they match `widgets` exactly.
    func renderWidgets(_ widgets: [StatusWidgetModel])
}
