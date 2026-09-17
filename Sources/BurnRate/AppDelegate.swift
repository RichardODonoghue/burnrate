import AppKit
import BurnRateCore
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
    /// The one shared instance per local source: model/cost views, local
    /// alerts and the Codex fallback all read the same incremental caches.
    private var localSources: [(name: String, source: any UsageSource)] = []
    private var modelUsageViewModel: ModelUsageViewModel?
    private let updater = Updater()
    private let notifications: any NotificationPresenting = UserNotificationPresenter()
    private let systemEvents: any SystemEventObserving = WorkspaceSystemEvents()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy would double every notification.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        PricingService.shared.bootstrap()
        // One-time migration: settings/history lived under the old bundle ID
        // ("com.burnrate.app"); UserDefaults domains are keyed by bundle ID,
        // so pull the legacy domain into the new standard domain once.
        migrateLegacyDefaults()
        // Dock icon for dev runs without a bundle; bundled runs load the
        // shipped icns explicitly — banners render from the running
        // process's app icon, and an accessory app doesn't load it by default.
        if Bundle.main.bundleIdentifier != nil {
            let icns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                .flatMap { NSImage(contentsOf: $0) }
            NSApp.applicationIconImage = NSImage(named: "AppIcon") ?? icns ?? NSApp.applicationIconImage
        } else {
            NSApp.applicationIconImage = AppIconRenderer.appIconImage(size: 256)
        }
        // One instance per source: duplicate actors would each re-parse the
        // same logs (Claude's ~560MB → double memory + CPU on first poll).
        let sharedSources: [(name: String, source: any UsageSource)] = [
            ("Claude", ClaudeUsageSource()),
            ("OpenCode", OpenCodeUsageSource()),
            ("Codex", CodexUsageSource()),
        ]
        localSources = sharedSources
        modelUsageViewModel = ModelUsageViewModel(sources: sharedSources)
        let claudeProvider = ClaudeUsageAPIProvider()
        providers = [
            claudeProvider,
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: sharedSources[2].source),
        ]

        let manager = StatusItemManager()
        manager.onAction = { [weak self] action in self?.handleStatusAction(action) }
        statusManager = manager
        // Rebuild the menu when an update is found / its state changes.
        updater.onStateChange = { [weak self] in self?.refreshStatusMenu() }
        updater.start()
        refreshStatusMenu()

        notifier = MilestoneNotifier(settingsStore: settingsStore, presenter: notifications)

        // Claude account switch (different signed-in account) → rebase alert
        // state so the old account's percentages aren't compared with the
        // new account's.
        Task { [weak self] in
            await claudeProvider.setCredentialChangeHandler {
                self?.notifier?.accountChanged()
            }
        }

        poll()
        startPollTimer()
        // Sleep freezes snapshots and throttle state; a window may have reset
        // while the Mac was asleep, so refresh immediately on wake.
        systemEvents.onWake { [weak self] in
            self?.refreshAfterWake()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    /// (Re)starts the 5-minute poll cadence; keep running while backgrounded.
    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    /// Fresh data after sleep: drop pre-sleep throttle state, poll now, and
    /// restart the cadence so the timer doesn't fire on its stale schedule.
    private func refreshAfterWake() {
        Task { [weak self, providers] in
            for provider in providers { await provider.invalidateCache() }
            self?.poll()
        }
        startPollTimer()
    }

    /// Copies user settings/history from the legacy bundle-ID defaults
    /// domain (com.burnrate.app) into the current standard domain. Runs at
    /// most once; existing values in the new domain win.
    private func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyBundleID") else { return }
        guard let legacy = UserDefaults(suiteName: "com.burnrate.app"),
              let source = legacy.persistentDomain(forName: "com.burnrate.app"),
              !source.isEmpty
        else {
            defaults.set(true, forKey: "migratedLegacyBundleID")
            return
        }
        let existing = defaults.dictionaryRepresentation()
        for (key, value) in source where existing[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedLegacyBundleID")
    }

    private func poll() {
        Task { [self, providers, usageStore, notifier, settingsStore, localSources, modelUsageViewModel] in
            let capacities = settingsStore.planCapacities

            // Phase 1: vendor quota APIs in parallel — authoritative %, fast.
            // Update the menu immediately so a cold start doesn't sit on
            // "Loading usage…" while local logs (Claude: ~560MB) parse.
            let apiSnapshots = await withTaskGroup(of: ProviderUsage?.self) { group in
                for provider in providers where !(provider is LocalUsageProvider) {
                    group.addTask { await provider.fetchUsage(capacities: capacities) }
                }
                var out: [ProviderUsage] = []
                for await usage in group { if let usage { out.append(usage) } }
                return out
            }
            if !apiSnapshots.isEmpty {
                // Keep previous readings for providers the APIs didn't return
                // (e.g. rate-limit reuse), so the menu never goes partial.
                let carried = usageStore.current.filter { usage in
                    !apiSnapshots.contains { $0.providerName == usage.providerName }
                }
                usageStore.update(apiSnapshots + carried)
                refreshStatusMenu()
            }

            // Phase 2: local logs in parallel — model/cost views, local
            // alerts, and the local Codex % (its cache is warm by now).
            let buckets: [(provider: String, samples: [UsageSample])] = await withTaskGroup(
                of: (String, [UsageSample]).self
            ) { group in
                for (name, source) in localSources {
                    group.addTask { (name, (try? await source.collectSamples()) ?? []) }
                }
                var out: [(provider: String, samples: [UsageSample])] = []
                for await (name, samples) in group {
                    out.append((provider: name, samples: samples))
                }
                return out
            }
            let todayStart = Calendar.current.startOfDay(for: Date())
            let costs: [(provider: String, cost: Double)] = buckets.map { bucket in
                (bucket.provider, bucket.samples
                    .filter { $0.timestamp >= todayStart }
                    .reduce(0.0) { $0 + PricingService.shared.cost(of: $1) })
            }

            let localSnapshots = await withTaskGroup(of: ProviderUsage?.self) { group in
                for provider in providers where provider is LocalUsageProvider {
                    group.addTask { await provider.fetchUsage(capacities: capacities) }
                }
                var out: [ProviderUsage] = []
                for await usage in group { if let usage { out.append(usage) } }
                return out
            }

            // Local snapshots override the API ones where both cover a
            // provider; anything the local pass didn't return keeps its
            // phase-1 reading so a provider never drops off the menu.
            let snapshots = usageStore.current.filter { existing in
                !localSnapshots.contains { $0.providerName == existing.providerName }
            } + localSnapshots
            usageStore.update(snapshots)
            notifier?.evaluate(usage: snapshots)
            notifier?.evaluateCosts(costs)
            modelUsageViewModel?.appendRemaining(snapshots: snapshots)

            // Refresh the Models view data + persist its snapshot.
            let daily = ModelUsageAggregator.daily(buckets: buckets, days: 30)
            modelUsageViewModel?.ingest(daily: daily, totals: ModelUsageAggregator.totals(buckets: buckets))

            refreshStatusMenu()
        }
    }

    /// Rebuild the tray models from current state and hand them to the presenter.
    private func refreshStatusMenu() {
        let usage = usageStore.current
        statusManager?.renderMain(
            menu: StatusMenuBuilder.mainMenu(
                usage: usage,
                updateVersion: updater.state.availableVersion,
                isBusy: updater.state.isBusy
            ),
            remaining: StatusMenuBuilder.worstRollingRemaining(usage: usage)
        )
        statusManager?.renderWidgets(
            settingsStore.widgetProviders.map {
                StatusMenuBuilder.widget(provider: $0, usage: usageStore.usage(for: $0))
            }
        )
    }

    private func handleStatusAction(_ action: StatusMenuAction) {
        switch action {
        case .openDashboard, .openCharts:
            openAppWindow(pane: .usage)
        case .openSettings:
            openAppWindow(pane: .notifications)
        case .checkForUpdates:
            Task { await updater.check() }
        case .installUpdate:
            Task { await updater.installAvailable() }
        case .removeWidget(let provider):
            settingsStore.widgetProviders.removeAll { $0 == provider }
            refreshStatusMenu()
        case .quit:
            NSApp.terminate(nil)
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
                viewModel: modelUsageViewModel ?? ModelUsageViewModel(sources: []),
                updater: updater,
                notifications: notifications,
                initialPane: pane
            )
        )
        // Don't let SwiftUI's intrinsic content size drive the window/frame;
        // otherwise wide panes push the sidebar out of view.
        hostingView.sizingOptions = []
        appWindow?.contentView = hostingView
        modelUsageViewModel?.reload()       // Dock presence while the UI is open; back to accessory when closed.
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
