import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let usageStore = UsageStore()
    private let settingsStore = SettingsStore()
    private var statusManager: StatusItemManager?
    private var notifier: MilestoneNotifier?
    private var appWindow: NSWindow?
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
        // Single instance: a second copy would double every notification.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        PricingService.shared.bootstrap()
        // Dock icon for dev runs without a bundle; bundled runs use the icns.
        NSApp.applicationIconImage = AppIconRenderer.appIconImage(size: 256)
        providers = [
            ClaudeUsageAPIProvider(),
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: CodexUsageSource()),
        ]

        let manager = StatusItemManager(usageStore: usageStore, settingsStore: settingsStore)
        manager.start(
            onOpenDashboard: { [weak self] in self?.openAppWindow(pane: .usage) },
            onOpenSettings: { [weak self] in self?.openAppWindow(pane: .notifications) }
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
                    .reduce(0.0) { $0 + PricingService.shared.cost(of: $1) }
                costs.append((name, todayCost))
            }

            usageStore.update(snapshots)
            notifier?.evaluate(usage: snapshots)
            notifier?.evaluateCosts(costs)
            notifier?.evaluateModelBurn(buckets)
            modelUsageViewModel.appendRemaining(snapshots: snapshots)

            // Refresh the Models view data + persist its snapshot.
            let daily = ModelUsageAggregator.daily(buckets: buckets, days: 30)
            modelUsageViewModel.ingest(daily: daily, totals: ModelUsageAggregator.totals(buckets: buckets))

            statusManager?.refreshMenu()
        }
    }

    private func openAppWindow(pane: AppPane) {
        if appWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "BurnRate"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            appWindow = window
        }
        let hostingView = NSHostingView(
            rootView: SettingsView(
                store: settingsStore,
                providerNames: usageStore.current.map(\.providerName),
                modelNames: Array(Set(modelUsageViewModel.totals.map(\.model))).sorted(),
                viewModel: modelUsageViewModel,
                initialPane: pane
            )
        )
        // Don't let SwiftUI's intrinsic content size drive the window/frame;
        // otherwise wide panes push the sidebar out of view.
        hostingView.sizingOptions = []
        appWindow?.contentView = hostingView
        modelUsageViewModel.reload()
        // Dock presence while the UI is open; back to accessory when closed.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
