import SwiftUI

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
    let modelNames: [String]
    let viewModel: ModelUsageViewModel

    @State private var selection: AppPane

    init(
        store: SettingsStore,
        providerNames: [String],
        modelNames: [String],
        viewModel: ModelUsageViewModel,
        initialPane: AppPane = .notifications
    ) {
        self.store = store
        self.providerNames = providerNames
        self.modelNames = modelNames
        self.viewModel = viewModel
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
                MilestonesView(store: store, providerNames: providerNames, modelNames: modelNames)
            case .widgets:
                WidgetsView(store: store, providerNames: providerNames)
            case .about:
                AboutView()
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
    let modelNames: [String]
    private let windowLabels = ["Rolling", "Weekly", "Fable", "Monthly"]

    @State private var newProvider = "Claude"
    @State private var newWindow = "Rolling"
    @State private var newThreshold = 20.0

    @State private var burnProvider = "Claude"
    @State private var burnWindow = "Rolling"
    @State private var burnDrop = 15.0
    @State private var burnMinutes = 30.0

    @State private var costProvider = "OpenCode"
    @State private var costLimit = ""
    @State private var modelBurnProvider = "Claude"
    @State private var modelBurnModel = "*"
    @State private var modelBurnTokens = ""
    @State private var modelBurnMinutes = 30

    var body: some View {
        Form {
            milestoneSection
            resetSection
            burnRateSection
            modelBurnSection
            costSection
        }
        .formStyle(.grouped)
        .onChange(of: newProvider) { _, _ in newWindow = "Rolling" }
        .onChange(of: burnProvider) { _, _ in burnWindow = "Rolling" }
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

    private var milestoneSection: some View {
        Section {
            if store.milestones.isEmpty {
                emptyHint("No milestones yet — get notified when usage runs low.", icon: "bell.slash")
            }
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
                    chip(String(format: "≤ %.0f%% left", milestone.percentRemaining),
                         tint: SettingsView.color(for: milestone.provider))
                    Button { store.milestones.removeAll { $0.id == milestone.id } } label: { deleteIcon }
                        .buttonStyle(.plain)
                }
            }
            Picker("Provider", selection: $newProvider) {
                ForEach(providerNames, id: \.self) { name in
                    Label(name, systemImage: "circle.fill")
                        .foregroundColor(SettingsView.color(for: name))
                }
            }
            Picker("Window", selection: $newWindow) {
                ForEach(windowLabels, id: \.self) { Text($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Alert threshold")
                    Spacer()
                    Text("\(Int(newThreshold.rounded()))% remaining")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $newThreshold, in: 1...99)
            }
            HStack {
                Spacer()
                Button("Add Milestone") {
                    store.milestones.append(
                        Milestone(provider: newProvider,
                                  windowLabel: newWindow,
                                  percentRemaining: newThreshold.rounded())
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(providerNames.isEmpty)
            }
        } header: {
            Text("Plan milestones")
        } footer: {
            Text("Percentages come from vendor quota APIs.")
        }
    }

    // MARK: Window resets

    private var resetSection: some View {
        Section {
            Toggle("Notify when a window resets", isOn: $store.notifyOnReset)
        } header: {
            Text("Window resets")
        } footer: {
            Text("Fires when a plan window rolls over and refills to 100% remaining.")
        }
    }

    // MARK: Burn rate

    private var burnRateSection: some View {
        Section {
            if store.burnAlerts.isEmpty {
                emptyHint("No burn-rate alerts — get notified when usage accelerates.", icon: "flame")
            }
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
            Picker("Provider", selection: $burnProvider) {
                ForEach(providerNames, id: \.self) { name in
                    Label(name, systemImage: "circle.fill")
                        .foregroundColor(SettingsView.color(for: name))
                }
            }
            Picker("Window", selection: $burnWindow) {
                ForEach(windowLabels, id: \.self) { Text($0) }
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
        } header: {
            Text("Burn-rate alerts")
        } footer: {
            Text("Detect usage spikes: a fast % drop within a trailing window.")
        }
    }

    // MARK: Cost

    private var costSection: some View {
        Section {
            if store.costAlerts.isEmpty {
                emptyHint("No cost alerts — get notified when daily spend crosses a limit.", icon: "dollarsign.circle")
            }
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
        } header: {
            Text("Daily cost alerts")
        } footer: {
            Text("Spend is estimated from local logs at list prices. Only OpenCode reports vendor cost today.")
        }
    }

    // MARK: Model burn

    private var modelBurnSection: some View {
        Section {
            if store.modelBurnAlerts.isEmpty {
                emptyHint("No model burn alerts — get notified when a single model burns tokens fast.", icon: "flame")
            }
            ForEach(store.modelBurnAlerts) { alert in
                HStack(spacing: 12) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(alert.provider) · \(alert.model)").fontWeight(.medium)
                        Text("window \(alert.minutes) min").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    chip("\(StatusItemManager.formatTokens(alert.tokens)) tok", tint: .orange)
                    Button { store.modelBurnAlerts.removeAll { $0.id == alert.id } } label: { deleteIcon }
                        .buttonStyle(.plain)
                }
            }
            Picker("Provider", selection: $modelBurnProvider) {
                ForEach(providerNames, id: \.self) { Text($0) }
            }
            Picker("Model", selection: $modelBurnModel) {
                Text("Any model").tag("*")
                ForEach(modelNames, id: \.self) { Text($0).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Tokens")
                TextField("2,000,000", text: $modelBurnTokens)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .monospacedDigit()
            }
            Picker("Window", selection: $modelBurnMinutes) {
                ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) min").tag($0) }
            }
            HStack {
                Spacer()
                Button("Add Model Burn Alert") {
                    let parsed = Int(modelBurnTokens.replacingOccurrences(of: ",", with: ""))
                    if let tokens = parsed, tokens > 0 {
                        store.modelBurnAlerts.append(
                            ModelBurnAlert(provider: modelBurnProvider, model: modelBurnModel,
                                           tokens: tokens, minutes: modelBurnMinutes)
                        )
                        modelBurnTokens = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled((Int(modelBurnTokens.replacingOccurrences(of: ",", with: "")) ?? 0) <= 0)
            }
        } header: {
            Text("Model burn alerts")
        } footer: {
            Text("Fires when one model consumes the token threshold within the window. Models come from the Usage dashboard.")
        }
    }
}

// MARK: - Widgets

private struct WidgetsView: View {
    @ObservedObject var store: SettingsStore
    let providerNames: [String]

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Extra menu-bar widgets")
            } footer: {
                Text(
                    "Each widget is an additional menu-bar item showing live usage % for that provider."
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: AppIconRenderer.appIconImage(size: 256))
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

            Section("What it does") {
                Label("Live menu-bar usage for your AI plan subscriptions", systemImage: "gauge.medium")
                Label("Per-model usage dashboard with trends and breakdowns", systemImage: "chart.bar.doc.horizontal")
                Label("Desktop notifications: milestones, burn-rate spikes, cost caps, window resets", systemImage: "bell.badge")
                Label("Optional extra menu-bar widgets per provider", systemImage: "menubar.dock.rectangle")
            }

            Section("Data sources") {
                Label("Vendor quota APIs — percentages, reset times and plan tier, using the credentials already stored by each CLI", systemImage: "checkmark.seal")
                Label("Local session logs — per-model token statistics and cost estimates (LiteLLM pricing); nothing is sent anywhere", systemImage: "internaldrive")
            }
        }
        .formStyle(.grouped)
    }
}

enum AppInfo {
    static let version = "0.1.0"
}
