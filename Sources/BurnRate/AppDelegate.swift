import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageStore = UsageStore()
    private let settingsStore = SettingsStore()
    private var statusManager: StatusItemManager?
    private var notifier: MilestoneNotifier?
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var providers: [any UsageProvider] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        providers = [
            ClaudeUsageAPIProvider(),
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: CodexUsageSource()),
        ]

        let manager = StatusItemManager(usageStore: usageStore, settingsStore: settingsStore)
        manager.start { [weak self] in self?.openSettings() }
        statusManager = manager

        notifier = MilestoneNotifier(settingsStore: settingsStore)

        poll()
        // Poll every 5 minutes; keep running while backgrounded.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    private func poll() {
        Task { [providers, usageStore, notifier, statusManager, settingsStore] in
            var snapshots: [ProviderUsage] = []
            for provider in providers {
                if let usage = await provider.fetchUsage(capacities: settingsStore.planCapacities) {
                    snapshots.append(usage)
                }
            }
            usageStore.update(snapshots)
            notifier?.evaluate(usage: snapshots)
            statusManager?.refreshMenu()
        }
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "BurnRate Settings"
            // Keep the window alive after closing; we reuse it.
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // Rebuild content each open so the provider list reflects live state.
        settingsWindow?.contentView = NSHostingView(
            rootView: SettingsView(
                store: settingsStore,
                providerNames: usageStore.current.map(\.providerName)
            )
        )
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
