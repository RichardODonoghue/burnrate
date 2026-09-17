import BurnRateCore
import CBurnRateGTK
import Foundation

/// Fetches usage from every configured provider and renders it as text.
private actor LinuxPoller {
    private let providers: [any UsageProvider]

    init() {
        self.providers = [
            ClaudeUsageAPIProvider(),
            OpenCodeGoUsageAPIProvider(),
            LocalUsageProvider(source: CodexUsageSource()),
        ]
    }

    func snapshot() async -> String {
        var lines: [String] = []
        for provider in providers {
            guard let usage = await provider.fetchUsage(capacities: PlanCapacities.byProviderWindow) else {
                continue
            }
            lines.append(usage.plan.map { "\(usage.providerName) - \($0)" } ?? usage.providerName)
            for window in usage.windows {
                let percent = window.percentRemaining.map { String(format: "%.0f", $0) } ?? "--"
                var detail = "\(percent)%"
                if let resetsAt = window.resetsAt {
                    detail += " · resets \(RelativeTime.format(resetsAt))"
                }
                lines.append("    \(window.label): \(detail)")
            }
            lines.append("")
        }
        if lines.isEmpty {
            return "No providers configured.\n\nLog in to a supported CLI, then press Refresh."
        }
        return lines.joined(separator: "\n")
    }
}

private let poller = LinuxPoller()

/// GTK calls this on the main thread (window shown, Refresh, 5-min timer).
/// Fetching happens off the main thread; the result is posted back safely.
private func onRefresh(_ context: UnsafeMutableRawPointer?) {
    Task.detached {
        let text = await poller.snapshot()
        text.withCString { br_ui_post($0) }
    }
}

@main
struct BurnRateLinuxMain {
    static func main() {
        br_ui_run("BurnRate", "Loading usage…", onRefresh, nil)
    }
}
