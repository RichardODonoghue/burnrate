import BurnRateCore
import Foundation
import Testing

struct StatusMenuTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func usage(
        _ provider: String,
        plan: String? = nil,
        windows: [(String, Double?, Date?)]
    ) -> ProviderUsage {
        ProviderUsage(
            providerName: provider,
            plan: plan,
            windows: windows.map { label, percent, resets in
                UsageWindow(id: "\(provider)-\(label)", label: label, tokensUsed: 0,
                            percentRemaining: percent, resetsAt: resets)
            }
        )
    }

    @Test func mainMenuListsProvidersWindowsAndActions() {
        let model = StatusMenuBuilder.mainMenu(
            usage: [usage("Claude", plan: "Team 5x", windows: [
                ("Rolling", 82, now.addingTimeInterval(4 * 3600)),
            ])],
            updateVersion: nil,
            isBusy: false,
            now: now
        )
        #expect(model.entries == [
            .providerHeader(title: "Claude - Team 5x"),
            .windowRow(label: "Rolling", detail: "82% · resets in 4h"),
            .separator,
            .action(title: "Usage Dashboard…", action: .openDashboard, isEnabled: true),
            .action(title: "Check for Updates…", action: .checkForUpdates, isEnabled: true),
            .action(title: "Settings…", action: .openSettings, isEnabled: true),
            .action(title: "Quit", action: .quit, isEnabled: true),
        ])
    }

    @Test func chartsRowIsOptIn() {
        let withCharts = StatusMenuBuilder.mainMenu(usage: [], updateVersion: nil, isBusy: false,
                                                    includesCharts: true, now: now)
        #expect(withCharts.entries.contains { entry in
            if case .action(_, .openCharts, _) = entry { true } else { false }
        })
        let without = StatusMenuBuilder.mainMenu(usage: [], updateVersion: nil, isBusy: false, now: now)
        #expect(!without.entries.contains { entry in
            if case .action(_, .openCharts, _) = entry { true } else { false }
        })
    }

    @Test func availableUpdateReplacesCheckAndDisablesWhileBusy() {
        let model = StatusMenuBuilder.mainMenu(usage: [], updateVersion: "0.7.0", isBusy: true, now: now)
        #expect(model.entries.contains(.text("Loading usage…")))
        #expect(model.entries.contains(.action(title: "Update to 0.7.0…",
                                               action: .installUpdate(version: "0.7.0"),
                                               isEnabled: false)))
        #expect(!model.entries.contains { entry in
            if case .action(_, .checkForUpdates, _) = entry { true } else { false }
        })
    }

    @Test func missingPercentShowsDash() {
        let model = StatusMenuBuilder.mainMenu(
            usage: [usage("Codex", windows: [("Rolling", nil, nil)])],
            updateVersion: nil, isBusy: false, now: now
        )
        #expect(model.entries.contains(.windowRow(label: "Rolling", detail: "--%")))
    }

    @Test func widgetTitlePrefersMonthlyThenFirstWindow() {
        #expect(StatusMenuBuilder.widgetTitle(provider: "OpenCode", usage: usage("OpenCode", windows: [
            ("Rolling", 40, nil), ("Monthly", 75, nil),
        ])) == "OpenCode 75%")
        #expect(StatusMenuBuilder.widgetTitle(provider: "Codex", usage: usage("Codex", windows: [
            ("Rolling", 40, nil),
        ])) == "Codex 40%")
        #expect(StatusMenuBuilder.widgetTitle(provider: "Codex", usage: nil) == "Codex --")
    }

    @Test func widgetMenuEndsWithRemoveAction() {
        let widget = StatusMenuBuilder.widget(provider: "Claude", usage: usage("Claude", windows: [
            ("Rolling", 12, nil),
        ]), now: now)
        #expect(widget.provider == "Claude")
        #expect(widget.title == "Claude 12%")
        #expect(widget.menu.entries.last == .action(title: "Remove widget",
                                                    action: .removeWidget(provider: "Claude"),
                                                    isEnabled: true))
    }

    @Test func worstRollingRemainingIsMinimumAcrossProviders() {
        let usage = [
            usage("Claude", windows: [("Rolling", 60, nil)]),
            usage("OpenCode", windows: [("Rolling", 15, nil), ("Weekly", 5, nil)]),
        ]
        #expect(StatusMenuBuilder.worstRollingRemaining(usage: usage) == 15)
        #expect(StatusMenuBuilder.worstRollingRemaining(usage: []) == nil)
    }

    @Test func relativeTimeBuckets() {
        #expect(RelativeTime.format(now.addingTimeInterval(-1), now: now) == "now")
        #expect(RelativeTime.format(now.addingTimeInterval(45 * 60), now: now) == "in 45m")
        #expect(RelativeTime.format(now.addingTimeInterval(5 * 3600), now: now) == "in 5h")
        #expect(RelativeTime.format(now.addingTimeInterval(5 * 3600 + 30 * 60), now: now) == "in 5h 30m")
        #expect(RelativeTime.format(now.addingTimeInterval(3 * 86_400), now: now) == "in 3d")
    }
}
