import AppKit

/// Owns all menu-bar status items: the always-present main item plus any
/// optional per-provider widgets spawned from settings.
@MainActor
final class StatusItemManager: NSObject {
    private let usageStore: UsageStore
    private let settingsStore: SettingsStore
    private var onOpenDashboard: (() -> Void)?
    private var onOpenSettings: (() -> Void)?
    private var onTestNotification: (() -> Void)?

    private var mainItem: NSStatusItem?
    /// Extra widgets, keyed by provider name.
    private var widgetItems: [String: NSStatusItem] = [:]

    init(usageStore: UsageStore, settingsStore: SettingsStore) {
        self.usageStore = usageStore
        self.settingsStore = settingsStore
        super.init()
    }

    func start(
        onOpenDashboard: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onTestNotification: @escaping () -> Void = {}
    ) {
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.onTestNotification = onTestNotification
        // Main menu-bar icon must always exist.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = AppIconRenderer.menuBarImage()
        item.menu = makeMenu()
        mainItem = item
        rebuildWidgets()
    }

    /// Rebuild menu contents from the latest usage snapshot.
    func refreshMenu() {
        mainItem?.menu = makeMenu()
        // Menu-bar icon is stateful: needle + tint track the worst window.
        if let item = mainItem {
            item.button?.image = AppIconRenderer.menuBarImage(remaining: worstRollingRemaining())
        }
        rebuildWidgets()
    }

    private func worstRollingRemaining() -> Double? {
        usageStore.current
            .compactMap { $0.window(withLabel: "Rolling")?.percentRemaining }
            .min()
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
                var detail = "\(percent)%"
                if let resetsAt = window.resetsAt {
                    detail += " · resets \(Self.formatTime(resetsAt))"
                }
                let item = NSMenuItem(title: "  \(window.label): \(detail)", action: nil, keyEquivalent: "")
                menu.addItem(item)
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
        models.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: nil)
        models.target = self
        menu.addItem(models)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.target = self
        menu.addItem(settings)

        let test = NSMenuItem(title: "Send Test Notification", action: #selector(testNotification), keyEquivalent: "")
        test.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
        test.target = self
        menu.addItem(test)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openModels() {
        onOpenDashboard?()
    }

    @objc private func testNotification() {
        onTestNotification?()
    }

    /// Compact token counts: 850, 42.3k, 1.2m, 3.6b, 1.1t.
    nonisolated static func formatTokens(_ count: Int) -> String {
        let v = Double(count)
        switch v {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return compact(v / 1_000) + "k"
        case ..<1_000_000_000: return compact(v / 1_000_000) + "m"
        case ..<1_000_000_000_000: return compact(v / 1_000_000_000) + "b"
        default: return compact(v / 1_000_000_000_000) + "t"
        }
    }

    /// Trims trailing zeros: 10.0 → "10", 1.5 → "1.5", 1.25 → "1.25".
    nonisolated private static func compact(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        return s
            .replacingOccurrences(of: #"(\.\d*?)0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    /// Menus are MainActor-only.
    /// Compact relative reset text: "in 45m", "in 5h", "in 3d" — a fixed
    /// medium date ("Sep 12, 2026 at 6:00 PM") was the widest menu line and
    /// stretched the whole dropdown.
    @MainActor
    static func formatTime(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(Int((seconds / 60).rounded(.up)))m" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        return "in \(Int((seconds / 86_400).rounded(.up)))d"
    }
}
