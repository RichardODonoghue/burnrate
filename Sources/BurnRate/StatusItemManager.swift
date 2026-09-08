import AppKit

/// Owns all menu-bar status items: the always-present main item plus any
/// optional per-provider widgets spawned from settings.
@MainActor
final class StatusItemManager: NSObject {
    private let usageStore: UsageStore
    private let settingsStore: SettingsStore
    private var onOpenSettings: (() -> Void)?
    private var onOpenModels: (() -> Void)?

    private var mainItem: NSStatusItem?
    /// Extra widgets, keyed by provider name.
    private var widgetItems: [String: NSStatusItem] = [:]

    init(usageStore: UsageStore, settingsStore: SettingsStore) {
        self.usageStore = usageStore
        self.settingsStore = settingsStore
        super.init()
    }

    func start(onOpenSettings: @escaping () -> Void, onOpenModels: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onOpenModels = onOpenModels
        // Main menu-bar icon must always exist.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◉"
        item.menu = makeMenu()
        mainItem = item
        rebuildWidgets()
    }

    /// Rebuild menu contents from the latest usage snapshot.
    func refreshMenu() {
        mainItem?.menu = makeMenu()
        rebuildWidgets()
    }

    // MARK: - Widgets

    private func rebuildWidgets() {
        let wanted = Set(settingsStore.widgetProviders)
        // Remove widgets no longer enabled.
        for (name, item) in widgetItems where !wanted.contains(name) {
            NSStatusBar.system.removeStatusItem(item)
            widgetItems.removeValue(forKey: name)
        }
        // Add or update enabled widgets.
        for name in settingsStore.widgetProviders {
            guard let usage = usageStore.usage(for: name) else { continue }
            let item = widgetItems[name] ?? {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                widgetItems[name] = item
                return item
            }()
            let percent = usage.window(withLabel: "Monthly")?.percentRemaining
                ?? usage.windows.first?.percentRemaining
            item.button?.title = "\(name) \(percent.map { String(format: "%.0f%%", $0) } ?? "--")"
            item.menu = makeWidgetMenu(provider: name)
        }
    }

    /// Widget items need their own menu or the button is unresponsive.
    private func makeWidgetMenu(provider: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let usage = usageStore.usage(for: provider) {
            for window in usage.windows {
                let percent = window.percentRemaining
                    .map { String(format: "%.0f", $0) } ?? "--"
                var detail = "\(percent)%"
                if let resetsAt = window.resetsAt {
                    detail += " · resets \(Self.formatTime(resetsAt))"
                }
                menu.addItem(NSMenuItem(
                    title: "\(window.label): \(detail)",
                    action: nil,
                    keyEquivalent: ""
                ))
            }
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(
            title: "Remove widget",
            action: #selector(removeWidget(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        remove.representedObject = provider
        menu.addItem(remove)
        return menu
    }

    @objc private func removeWidget(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        settingsStore.widgetProviders.removeAll { $0 == name }
        if let item = widgetItems.removeValue(forKey: name) {
            NSStatusBar.system.removeStatusItem(item)
        }
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Items with nil actions are auto-disabled (grey) unless this is off.
        menu.autoenablesItems = false
        for usage in usageStore.current {
            let header = NSMenuItem(
                title: usage.plan.map { "\(usage.providerName) - \($0)" } ?? usage.providerName,
                action: nil,
                keyEquivalent: ""
            )
            menu.addItem(header)
            for window in usage.windows {
                let percent = window.percentRemaining
                    .map { String(format: "%.0f", $0) } ?? "--"
                var detail = "\(percent)% remaining"
                if window.tokensUsed > 0 {
                    detail += " · \(Self.formatTokens(window.tokensUsed)) tok"
                }
                if let resetsAt = window.resetsAt {
                    detail += " · resets \(Self.formatTime(resetsAt))"
                }
                menu.addItem(NSMenuItem(title: "  \(window.label): \(detail)", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())
        }
        if usageStore.current.isEmpty {
            let loading = NSMenuItem(title: "Loading usage…", action: nil, keyEquivalent: "")
            menu.addItem(loading)
            menu.addItem(.separator())
        }

        let models = NSMenuItem(
            title: "Usage by Model…",
            action: #selector(openModels),
            keyEquivalent: "m"
        )
        models.target = self
        menu.addItem(models)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openModels() {
        onOpenModels?()
    }

    /// Pure formatting helper, callable from tests and nonisolated contexts.
    nonisolated static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: "\(count)"
        case ..<1_000_000: String(format: "%.1fk", Double(count) / 1_000)
        default: String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }

    /// Menus are MainActor-only; the formatters are cached and reused.
    @MainActor
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// Multi-day windows (weekly/monthly) need a date, not just a clock time.
    @MainActor
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @MainActor
    static func formatTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            timeFormatter.string(from: date)
        } else {
            dateTimeFormatter.string(from: date)
        }
    }
}
