import AppKit
import BurnRateCore

/// macOS tray renderer: draws `StatusMenuModel`/`StatusWidgetModel` onto the
/// menu bar and reports the chosen action. It owns no app state, so a Linux or
/// Windows presenter can implement `StatusItemPresenting` instead.
@MainActor
final class StatusItemManager: NSObject, StatusItemPresenting {
    var onAction: ((StatusMenuAction) -> Void)?

    private var mainItem: NSStatusItem?
    /// Extra widgets, keyed by provider name.
    private var widgetItems: [String: NSStatusItem] = [:]

    func renderMain(menu: StatusMenuModel, remaining: Double?) {
        let item = mainItem ?? {
            // The main menu-bar icon must always exist.
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            mainItem = item
            return item
        }()
        item.button?.image = AppIconRenderer.menuBarImage(remaining: remaining)
        item.menu = makeMenu(menu)
    }

    func renderWidgets(_ widgets: [StatusWidgetModel]) {
        let wanted = Set(widgets.map(\.provider))
        // Remove widgets no longer enabled.
        for (name, item) in widgetItems where !wanted.contains(name) {
            NSStatusBar.system.removeStatusItem(item)
            widgetItems.removeValue(forKey: name)
        }
        // Add or update enabled widgets.
        for widget in widgets {
            let item = widgetItems[widget.provider] ?? {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                widgetItems[widget.provider] = item
                return item
            }()
            item.button?.title = widget.title
            item.menu = makeMenu(widget.menu)
        }
    }

    // MARK: - Menu rendering

    private func makeMenu(_ model: StatusMenuModel) -> NSMenu {
        let menu = NSMenu()
        // Items with nil actions are auto-disabled (grey) unless this is off.
        menu.autoenablesItems = false
        for entry in model.entries {
            switch entry {
            case .providerHeader(let title):
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            case .windowRow(let label, let detail):
                menu.addItem(NSMenuItem(title: "  \(label): \(detail)", action: nil, keyEquivalent: ""))
            case .text(let text):
                menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: ""))
            case .separator:
                menu.addItem(.separator())
            case .action(let title, let action, let isEnabled):
                menu.addItem(actionItem(title: title, action: action, isEnabled: isEnabled))
            }
        }
        return menu
    }

    private func actionItem(title: String, action: StatusMenuAction, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(dispatchAction(_:)), keyEquivalent: keyEquivalent(for: action))
        item.target = self
        item.isEnabled = isEnabled
        item.representedObject = ActionBox(action)
        item.image = image(for: action)
        return item
    }

    private func keyEquivalent(for action: StatusMenuAction) -> String {
        switch action {
        case .openDashboard: "m"
        case .openSettings: ","
        case .quit: "q"
        default: ""
        }
    }

    private func image(for action: StatusMenuAction) -> NSImage? {
        let symbol: String?
        switch action {
        case .openDashboard: symbol = "chart.bar.doc.horizontal"
        case .installUpdate: symbol = "arrow.down.circle.fill"
        case .checkForUpdates: symbol = "arrow.triangle.2.circlepath"
        case .openSettings: symbol = "gearshape"
        default: symbol = nil
        }
        return symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @objc private func dispatchAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        onAction?(box.action)
    }

    /// `representedObject` must be an object; box the enum.
    private final class ActionBox: NSObject {
        let action: StatusMenuAction
        init(_ action: StatusMenuAction) {
            self.action = action
        }
    }
}
