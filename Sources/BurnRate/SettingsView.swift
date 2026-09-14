import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// Unified app window: dashboard (usage by model), notifications, widgets, about.
enum AppPane: Hashable {
    case usage
    case notifications
    case widgets
    case about
}

/// Settings window: sidebar navigation (System Settings style).
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let providerNames: [String]
    let viewModel: ModelUsageViewModel
    @ObservedObject var updater: Updater

    @State private var selection: AppPane

    init(
        store: SettingsStore,
        providerNames: [String],
        viewModel: ModelUsageViewModel,
        updater: Updater,
        initialPane: AppPane = .notifications
    ) {
        self.store = store
        self.providerNames = providerNames
        self.viewModel = viewModel
        self.updater = updater
        _selection = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                Label("Usage", systemImage: "chart.bar.doc.horizontal")
                    .tag(AppPane.usage)
                Label("Notifications", systemImage: "bell.badge.fill")
                    .tag(AppPane.notifications)
                Label("Menu Bar Widgets", systemImage: "menubar.dock.rectangle")
                    .tag(AppPane.widgets)
                Label("About", systemImage: "info.circle")
                    .tag(AppPane.about)
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch selection {
            case .usage:
                ModelsView(viewModel: viewModel)
            case .notifications:
                MilestonesView(store: store, providerNames: providerNames)
            case .widgets:
                WidgetsView(store: store, providerNames: providerNames)
            case .about:
                AboutView(updater: updater)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: selection) { _, pane in
            if pane == .usage { viewModel.reload() }
        }
    }

    static func color(for provider: String) -> Color {
        switch provider {
        case "Claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "OpenCode Go", "OpenCode": Color(red: 0.25, green: 0.55, blue: 0.95)
        case "Codex": Color(red: 0.20, green: 0.68, blue: 0.44)
        default: .accentColor
        }
    }
}

// MARK: - Notifications

private struct MilestonesView: View {
    @ObservedObject var store: SettingsStore
    let providerNames: [String]
    /// Window options per provider. Fable is a Claude-only model-scoped
    /// weekly quota — OpenCode and Codex only report Rolling/Weekly/Monthly.
    private func windowLabels(for provider: String) -> [String] {
        provider == "Claude"
            ? ["Rolling", "Weekly", "Fable", "Monthly"]
            : ["Rolling", "Weekly", "Monthly"]
    }

    @State private var newProvider = "Claude"
    @State private var newWindow = "Rolling"
    @State private var newStep = 20.0
    private let stepPresets = [5.0, 10.0, 20.0, 25.0]

    @State private var burnProvider = "Claude"
    @State private var burnWindow = "Rolling"
    @State private var burnDrop = 15.0
    @State private var burnMinutes = 30.0

    @State private var costProvider = "OpenCode"
    @State private var costLimit = ""
    @State private var authStatus: UNAuthorizationStatus?

    var body: some View {
        CardPane {
            systemPermissionCard
            milestoneCard
            resetCard
            burnRateCard
            costCard
        }
        .task { await refreshAuth() }
        .onChange(of: newProvider) { _, _ in newWindow = "Rolling" }
        .onChange(of: burnProvider) { _, _ in burnWindow = "Rolling" }
    }

    // MARK: System permission

    /// macOS prompts for notification permission at most once per install.
    /// If the user missed or denied it, no prompt ever reappears — this row
    /// surfaces the real status and offers the fix in place.
    private var systemPermissionCard: some View {
        Card("System permission",
             footnote: "If permission is off, BurnRate still polls and updates the menu — only banners and sounds stop.") {
            HStack {
                Text(authLabel)
                Spacer()
                switch authStatus {
                case .authorized, .provisional, .ephemeral:
                    Label("On", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .notDetermined:
                    Button("Request permission") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound])
                            await refreshAuth()
                        }
                    }
                default:
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private var authLabel: String {
        switch authStatus {
        case .authorized, .provisional, .ephemeral: "Notifications allowed"
        case .denied: "Notifications blocked"
        case .notDetermined: "Permission not requested yet"
        default: "Checking permission…"
        }
    }

    private func refreshAuth() async {
        authStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    // MARK: Shared pieces

    private var deleteIcon: some View {
        Image(systemName: "trash")
            .foregroundStyle(.secondary)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }

    private func emptyHint(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    // MARK: Plan milestones

    private var milestoneCard: some View {
        Card("Plan milestones",
             footnote: "Fires each time remaining drops past another increment (every 20%: 80, 60, 40, 20). One rule per plan window.") {
            if store.milestones.isEmpty {
                emptyHint("No milestones yet — get notified as usage runs low.", icon: "bell.slash")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.milestones) { milestone in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(SettingsView.color(for: milestone.provider))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(milestone.provider).fontWeight(.medium)
                                Text(milestone.windowLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            chip("Every \(Int(milestone.step))%",
                                 tint: SettingsView.color(for: milestone.provider))
                            Button { store.milestones.removeAll { $0.id == milestone.id } } label: { deleteIcon }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
            }
            Picker("Provider", selection: $newProvider) {
                ForEach(providerNames, id: \.self) { name in
                    Label(name, systemImage: "circle.fill")
                        .foregroundColor(SettingsView.color(for: name))
                }
            }
            Picker("Window", selection: $newWindow) {
                ForEach(windowLabels(for: newProvider), id: \.self) { Text($0) }
            }
            Picker("Notify every", selection: $newStep) {
                ForEach(stepPresets, id: \.self) { step in
                    Text("Every \(Int(step))%").tag(step)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                if let existing = store.milestones.first(where: {
                    $0.provider == newProvider && $0.windowLabel == newWindow
                }) {
                    if existing.step == newStep {
                        Text("Already added")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Update to every \(Int(newStep))%") {
                            store.upsertMilestone(
                                Milestone(provider: newProvider,
                                          windowLabel: newWindow,
                                          step: newStep)
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button("Add Milestone") {
                        store.upsertMilestone(
                            Milestone(provider: newProvider,
                                      windowLabel: newWindow,
                                      step: newStep)
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(providerNames.isEmpty)
                }
            }
        }
    }

    // MARK: Window resets

    private var resetCard: some View {
        Card("Window resets",
             footnote: "Fires when a plan window rolls over and refills to 100% remaining.") {
            Toggle("Notify when a window resets", isOn: $store.notifyOnReset)
        }
    }

    // MARK: Burn rate

    private var burnRateCard: some View {
        Card("Burn-rate alerts",
             footnote: "Detect usage spikes: a fast % drop within a trailing window.") {
            if store.burnAlerts.isEmpty {
                emptyHint("No burn-rate alerts — get notified when usage accelerates.", icon: "flame")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.burnAlerts) { alert in
                        HStack(spacing: 12) {
                            Image(systemName: "flame.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.provider).fontWeight(.medium)
                                Text(alert.windowLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            chip(String(format: "↓%.0f%% / %d min", alert.percentDrop, alert.minutes), tint: .orange)
                            Button { store.burnAlerts.removeAll { $0.id == alert.id } } label: { deleteIcon }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
            }
            Picker("Provider", selection: $burnProvider) {
                ForEach(providerNames, id: \.self) { name in
                    Label(name, systemImage: "circle.fill")
                        .foregroundColor(SettingsView.color(for: name))
                }
            }
            Picker("Window", selection: $burnWindow) {
                ForEach(windowLabels(for: burnProvider), id: \.self) { Text($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Drop")
                    Spacer()
                    Text("\(Int(burnDrop.rounded()))% within \(Int((burnMinutes / 15).rounded() * 15)) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $burnDrop, in: 5...95)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Trailing window")
                    Spacer()
                    Text("\(Int((burnMinutes / 15).rounded() * 15)) min")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $burnMinutes, in: 15...120)
            }
            HStack {
                Spacer()
                Button("Add Burn-Rate Alert") {
                    store.burnAlerts.append(
                        BurnAlert(provider: burnProvider,
                                  windowLabel: burnWindow,
                                  percentDrop: burnDrop.rounded(),
                                  minutes: Int((burnMinutes / 15).rounded() * 15))
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(providerNames.isEmpty)
            }
        }
    }

    // MARK: Cost

    private var costCard: some View {
        Card("Daily cost alerts",
             footnote: "Spend is estimated from local logs at list prices. Only OpenCode reports vendor cost today.") {
            if store.costAlerts.isEmpty {
                emptyHint("No cost alerts — get notified when daily spend crosses a limit.", icon: "dollarsign.circle")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.costAlerts) { alert in
                        HStack(spacing: 12) {
                            Image(systemName: "dollarsign.circle.fill").foregroundStyle(.green)
                            Text(alert.provider).fontWeight(.medium)
                            Spacer()
                            chip(String(format: "≥ $%.2f/day", alert.dailyLimitUSD), tint: .green)
                            Button { store.costAlerts.removeAll { $0.id == alert.id } } label: { deleteIcon }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
            }
            Picker("Provider", selection: $costProvider) {
                ForEach(providerNames, id: \.self) { Text($0) }
            }
            HStack {
                Text("Daily limit ($)")
                Spacer()
                TextField("5.00", text: $costLimit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Add Cost Alert") {
                    if let limit = Double(costLimit), limit > 0 {
                        store.costAlerts.removeAll { $0.provider == costProvider }
                        store.costAlerts.append(CostAlert(provider: costProvider, dailyLimitUSD: limit))
                        costLimit = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled((Double(costLimit) ?? 0) <= 0)
            }
        }
    }

}

// MARK: - Widgets

private struct WidgetsView: View {
    @ObservedObject var store: SettingsStore
    let providerNames: [String]

    var body: some View {
        CardPane {
            Card("Extra menu-bar widgets",
                 footnote: "Each widget is an additional menu-bar item showing live usage % for that provider.") {
                VStack(alignment: .leading, spacing: 10) {
                ForEach(providerNames, id: \.self) { name in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(SettingsView.color(for: name))
                            .frame(width: 8, height: 8)
                        Text(name)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { store.widgetProviders.contains(name) },
                            set: { enabled in
                                if enabled {
                                    store.widgetProviders.append(name)
                                } else {
                                    store.widgetProviders.removeAll { $0 == name }
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                if providerNames.isEmpty {
                    Label(
                        "No providers are active. Log in to a supported CLI to see it here.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
                }
            }
        }
    }
}

// MARK: - About

private struct AboutView: View {
    @ObservedObject var updater: Updater

    /// The shipped bundle icon — identical to Dock and notification banners.
    /// (The live renderer tints by severity; About must not.)
    private static func bundleIcon() -> NSImage {
        if let named = NSImage(named: "AppIcon") { return named }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icns = NSImage(contentsOf: url) { return icns }
        return AppIconRenderer.appIconImage(size: 256)
    }

    var body: some View {
        CardPane {
            Card {
                VStack(spacing: 10) {
                    Image(nsImage: Self.bundleIcon())
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text("BurnRate")
                        .font(.title2).fontWeight(.semibold)
                    Text("Version \(AppInfo.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Card("Updates") {
                updateRow
            }

            Card("What it does") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Menu bar: per-provider % remaining, reset countdown and plan tier — no Dock icon", systemImage: "gauge.medium")
                    Label("Usage dashboard: remaining-% trends, daily usage by model, model ranking and token/cost breakdowns", systemImage: "chart.bar.doc.horizontal")
                    Label("Notifications: plan-% milestones, burn-rate spikes, daily cost caps and window resets", systemImage: "bell.badge")
                    Label("Optional extra menu-bar widgets, one per provider", systemImage: "menubar.dock.rectangle")
                    Label("Built-in updates from GitHub Releases", systemImage: "arrow.down.circle")
                }
            }

            Card("Data sources") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Vendor quota APIs — Claude and OpenCode Go percentages, reset times and plan tier, using the credentials their CLIs already stored", systemImage: "checkmark.seal")
                    Label("Local session logs — Codex usage, plus per-model token statistics and cost estimates (LiteLLM list pricing). Nothing is sent anywhere", systemImage: "internaldrive")
                }
            }

            Card("Links") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        GitHubMark()
                            .frame(width: 16, height: 16)
                        Link("github.com/\(Updater.owner)/\(Updater.repo)",
                             destination: Self.repositoryURL)
                    }
                    Label {
                        Link("Report an issue or request a feature",
                             destination: Self.issuesURL)
                    } icon: {
                        Image(systemName: "exclamationmark.bubble")
                    }
                }
            }
        }
    }

    private static let repositoryURL = URL(string: "https://github.com/\(Updater.owner)/\(Updater.repo)")!
    private static let issuesURL = URL(string: "https://github.com/\(Updater.owner)/\(Updater.repo)/issues")!

    // MARK: Updates

    @ViewBuilder
    private var updateRow: some View {
        if let update = updater.available {
            VStack(alignment: .leading, spacing: 8) {
                Label("Version \(update.version) is available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button("Install Update") {
                        Task { await updater.install(update) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.status.isBusy)
                    Button("Release Notes") {
                        NSWorkspace.shared.open(update.releaseURL)
                    }
                    Spacer()
                    updateStatusText
                }
            }
        } else {
            HStack {
                Text("Version \(AppInfo.version)")
                    .foregroundStyle(.secondary)
                Spacer()
                updateStatusText
                Button("Check for Updates") {
                    Task { await updater.check() }
                }
                .disabled(updater.status.isBusy)
            }
        }
    }

    @ViewBuilder
    private var updateStatusText: some View {
        switch updater.status {
        case .checking: Text("Checking…").foregroundStyle(.secondary)
        case .downloading: Text("Downloading…").foregroundStyle(.secondary)
        case .installing: Text("Installing — BurnRate will relaunch").foregroundStyle(.secondary)
        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
        case .failed(let message): Text(message).foregroundStyle(.red)
        default: EmptyView()
        }
    }
}

enum AppInfo {
    /// Marketing version from the bundle ("0.0.0" for `swift run`, which has
    /// no Info.plist) — update checks compare against this.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
