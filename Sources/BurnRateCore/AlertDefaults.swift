import Foundation

/// Shipped default alert rules, shared by the macOS settings store and any
/// platform without an editor (Linux).
public enum AlertDefaults {
    public static let milestones: [Milestone] = [
        Milestone(provider: "Claude", windowLabel: "Rolling", step: 20),
        Milestone(provider: "Claude", windowLabel: "Weekly", step: 20),
        Milestone(provider: "Codex", windowLabel: "Rolling", step: 20),
    ]

    public static let burnAlerts: [BurnAlert] = [
        BurnAlert(provider: "Claude", windowLabel: "Rolling", percentDrop: 15, minutes: 30),
    ]
}
