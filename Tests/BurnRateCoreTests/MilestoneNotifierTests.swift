import BurnRateCore
import Foundation
import Testing

/// Fixed settings for the notifier — mirrors the app's shipped defaults so the
/// test is portable (no Combine `SettingsStore`).
@MainActor
private final class StubAlertSettings: AlertSettings {
    var milestones: [Milestone] = [
        Milestone(provider: "Claude", windowLabel: "Rolling", step: 20),
        Milestone(provider: "Claude", windowLabel: "Weekly", step: 20),
    ]
    var burnAlerts: [BurnAlert] = []
    var costAlerts: [CostAlert] = []
    var notifyOnReset = true
}

@MainActor
struct MilestoneNotifierTests {
    /// Notifier backed by an isolated defaults suite so tests don't touch the
    /// real notification state.
    private func makeNotifier() -> (MilestoneNotifier, StubAlertSettings, UserDefaults) {
        let suite = UserDefaults(suiteName: "notifier-tests-\(UUID().uuidString)")!
        let settings = StubAlertSettings()
        return (MilestoneNotifier(settingsStore: settings, defaults: suite), settings, suite)
    }

    private func usage(_ provider: String, _ label: String, remaining: Double,
                       resetsAt: Date? = nil) -> ProviderUsage {
        ProviderUsage(
            providerName: provider,
            plan: nil,
            windows: [UsageWindow(id: "\(provider)-\(label)", label: label, tokensUsed: 0,
                                  percentRemaining: remaining, resetsAt: resetsAt)]
        )
    }

    @Test func accountSwitchSuppressesPhantomResetAndMilestones() {
        let (notifier, _, _) = makeNotifier()

        // Account A: baseline, then a genuine drop across the 20% step.
        notifier.evaluate(usage: [usage("Claude", "Rolling", remaining: 30)])
        notifier.evaluate(usage: [usage("Claude", "Rolling", remaining: 18)])
        #expect(notifier.sentTitles.contains { $0.contains("milestone") })

        notifier.accountChanged()
        #expect(notifier.sentTitles.contains("Claude account changed"))

        // Account B: fresh quota at 95%, with a later resetsAt. Without the
        // rebase this is a +77 jump and a moved resetsAt — both would fire a
        // phantom "reset" alert.
        notifier.evaluate(usage: [
            usage("Claude", "Rolling", remaining: 95, resetsAt: Date().addingTimeInterval(5 * 3600))
        ])
        #expect(!notifier.sentTitles.contains { $0.contains("reset") })

        // Baseline was adopted: a genuine drop afterwards still alerts.
        notifier.evaluate(usage: [usage("Claude", "Rolling", remaining: 15)])
        #expect(notifier.sentTitles.contains { $0.contains("milestone") && $0.contains("Rolling") })
    }

    @Test func resetWithoutAccountSwitchStillAlerts() {
        let (notifier, _, _) = makeNotifier()
        notifier.evaluate(usage: [usage("Claude", "Rolling", remaining: 10)])
        // Same account, window genuinely rolls over: resetsAt moves forward.
        notifier.evaluate(usage: [
            usage("Claude", "Rolling", remaining: 98, resetsAt: Date().addingTimeInterval(5 * 3600))
        ])
        #expect(notifier.sentTitles.contains { $0.contains("reset") })
    }
}
