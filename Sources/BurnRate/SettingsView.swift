import SwiftUI

/// Settings window: sidebar navigation (System Settings style).
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    let providerNames: [String]

    private enum Pane: Hashable {
        case notifications
        case widgets
        case about
    }

    @State private var selection: Pane = .notifications

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                Label("Notifications", systemImage: "bell.badge.fill")
                    .tag(Pane.notifications)
                Label("Menu Bar Widgets", systemImage: "menubar.dock.rectangle")
                    .tag(Pane.widgets)
                Label("About", systemImage: "info.circle")
                    .tag(Pane.about)
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch selection {
            case .notifications:
                MilestonesView(store: store, providerNames: providerNames)
            case .widgets:
                WidgetsView(store: store, providerNames: providerNames)
            case .about:
                AboutView()
            }
        }
        .frame(width: 620, height: 440)
    }

    static func color(for provider: String) -> Color {
        switch provider {
        case "Claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "OpenCode Go": Color(red: 0.25, green: 0.55, blue: 0.95)
        case "Codex": Color(red: 0.20, green: 0.68, blue: 0.44)
        default: .accentColor
        }
    }
}

// MARK: - Notifications

private struct MilestonesView: View {
    @ObservedObject var store: SettingsStore
    let providerNames: [String]
    private let windowLabels = ["5hr", "Rolling", "Weekly", "Fable", "Monthly"]

    @State private var newProvider = "Claude"
    @State private var newWindow = "5hr"
    @State private var newThreshold = 20.0

    @State private var burnProvider = "Claude"
    @State private var burnWindow = "5hr"
    @State private var burnDrop = 15.0
    @State private var burnMinutes = 30.0

    var body: some View {
        Form {
            Section("Alert when a plan window drops to threshold") {
                if store.milestones.isEmpty {
                    Label(
                        "No milestones yet. Add one below to get a desktop notification when usage runs low.",
                        systemImage: "bell.slash"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
                ForEach(store.milestones) { milestone in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(SettingsView.color(for: milestone.provider))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(milestone.provider).fontWeight(.medium)
                            Text(milestone.windowLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "≤ %.0f%% left", milestone.percentRemaining))
                            .font(.callout)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(SettingsView.color(for: milestone.provider).opacity(0.15)))
                        Button {
                            store.milestones.removeAll { $0.id == milestone.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Add milestone") {
                Picker("Provider", selection: $newProvider) {
                    ForEach(providerNames, id: \.self) { name in
                        Label(name, systemImage: "circle.fill")
                            .foregroundColor(SettingsView.color(for: name))
                    }
                }
                Picker("Window", selection: $newWindow) {
                    ForEach(windowLabels, id: \.self) { Text($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Alert threshold")
                        Spacer()
                        Text("\(Int(newThreshold))% remaining")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $newThreshold, in: 1...90, step: 1)
                }
                .padding(.vertical, 2)
                HStack {
                    Spacer()
                    Button("Add Milestone") {
                        store.milestones.append(
                            Milestone(
                                provider: newProvider,
                                windowLabel: newWindow,
                                percentRemaining: newThreshold
                            )
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(providerNames.isEmpty)
                }
            }

            Section("Burn-rate alerts — alert when usage spikes") {
                if store.burnAlerts.isEmpty {
                    Label(
                        "No burn-rate alerts. Add one to get notified when usage accelerates.",
                        systemImage: "flame"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
                ForEach(store.burnAlerts) { alert in
                    HStack(spacing: 10) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.provider).fontWeight(.medium)
                            Text(alert.windowLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "↓%.0f%% / %d min", alert.percentDrop, alert.minutes))
                            .font(.callout)
                            .monospacedDigit()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                        Button {
                            store.burnAlerts.removeAll { $0.id == alert.id }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Add burn-rate alert") {
                Picker("Provider", selection: $burnProvider) {
                    ForEach(providerNames, id: \.self) { name in
                        Label(name, systemImage: "circle.fill")
                            .foregroundColor(SettingsView.color(for: name))
                    }
                }
                Picker("Window", selection: $burnWindow) {
                    ForEach(windowLabels, id: \.self) { Text($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Drop")
                        Spacer()
                        Text("\(Int(burnDrop))% within \(Int(burnMinutes)) min")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $burnDrop, in: 5...60, step: 1)
                    HStack {
                        Text("Window")
                        Slider(value: $burnMinutes, in: 15...120, step: 15)
                            .frame(width: 160)
                    }
                }
                .padding(.vertical, 2)
                HStack {
                    Spacer()
                    Button("Add Burn-Rate Alert") {
                        store.burnAlerts.append(
                            BurnAlert(
                                provider: burnProvider,
                                windowLabel: burnWindow,
                                percentDrop: burnDrop,
                                minutes: Int(burnMinutes)
                            )
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(providerNames.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: newProvider) { _, _ in newWindow = "5hr" }
        .onChange(of: burnProvider) { _, _ in burnWindow = "5hr" }
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
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
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
                Label("Desktop notifications at usage milestones you choose", systemImage: "bell.badge")
                Label("Optional extra menu-bar widgets per provider", systemImage: "menubar.dock.rectangle")
            }

            Section("Data sources") {
                Label("Vendor quota APIs — percentages and reset times, using the credentials already stored by each CLI", systemImage: "checkmark.seal")
                Label("Local session logs — token statistics only; nothing is sent anywhere", systemImage: "internaldrive")
            }
        }
        .formStyle(.grouped)
    }
}

enum AppInfo {
    static let version = "0.1.0"
}