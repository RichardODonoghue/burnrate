import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageStore = UsageStore()
    private let settingsStore = SettingsStore()
    private var statusManager: StatusItemManager?
    private var notifier: MilestoneNotifier?
    private var settingsWindow: NSWindow?
    private var modelsWindow: NSWindow?
    private var pollTimer: Timer?
    private var providers: [any UsageProvider] = []
    /// Local log sources, used for model/cost views and local alerts.
    private let localSources: [(name: String, source: any UsageSource)] = [
        ("Claude", ClaudeUsageSource()),
        ("OpenCode", OpenCodeUsageSource()),
        ("Codex", CodexUsageSource()),
    ]
    private let modelUsageViewModel = ModelUsageViewModel(sources: [
        ("Claude", ClaudeUsageSource()),
        ("OpenCode", OpenCodeUsageSource()),
        ("Codex", CodexUsageSource()),
    ])

    func applicationDidFinishLaunching(_ notification: Notification) {
        providers = [
            ClaudeUsageAPIProvider(),
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: CodexUsageSource()),
        ]

        let manager = StatusItemManager(usageStore: usageStore, settingsStore: settingsStore)
        manager.start(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenModels: { [weak self] in self?.openModelsWindow() }
        )
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
        Task { [providers, usageStore, notifier, statusManager, settingsStore, localSources, modelUsageViewModel] in
            var snapshots: [ProviderUsage] = []
            for provider in providers {
                if let usage = await provider.fetchUsage(capacities: settingsStore.planCapacities) {
                    snapshots.append(usage)
                }
            }

            // Local logs: per-model usage for the Models view, daily cost and
            // model-burn alerts. Cheap thanks to incremental caches.
            var buckets: [(provider: String, samples: [UsageSample])] = []
            var costs: [(provider: String, cost: Double)] = []
            let todayStart = Calendar.current.startOfDay(for: Date())
            for (name, source) in localSources {
                let samples = (try? await source.collectSamples()) ?? []
                buckets.append((name, samples))
                let todayCost = samples
                    .filter { $0.timestamp >= todayStart }
                    .reduce(0.0) { $0 + ($1.cost ?? 0) }
                costs.append((name, todayCost))
            }

            usageStore.update(snapshots)
            notifier?.evaluate(usage: snapshots)
            notifier?.evaluateCosts(costs)
            notifier?.evaluateModelBurn(buckets)

            // Refresh the Models view data + persist its snapshot.
            let daily = ModelUsageAggregator.daily(buckets: buckets, days: 30)
            modelUsageViewModel.ingest(daily: daily, totals: ModelUsageAggregator.totals(buckets: buckets))

            statusManager?.refreshMenu()
        }
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .resizable],
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

    private func openModelsWindow() {
        if modelsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "BurnRate — Usage by Model"
            window.isReleasedWhenClosed = false
            window.center()
            modelsWindow = window
        }
        modelsWindow?.contentView = NSHostingView(rootView: ModelsView(viewModel: modelUsageViewModel))
        modelUsageViewModel.reload()
        NSApp.activate(ignoringOtherApps: true)
        modelsWindow?.makeKeyAndOrderFront(nil)
    }
}
