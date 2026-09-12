import Foundation
import Testing
@testable import BurnRate

struct ProviderThrottleTests {
    private let now = Date()

    private func window(resetsAt: Date?) -> UsageWindow {
        UsageWindow(id: "Claude-Weekly", label: "Weekly", tokensUsed: 0,
                    percentRemaining: 0, resetsAt: resetsAt)
    }

    @Test func noWindowsNeverDue() {
        #expect(!ProviderThrottle.resetDue(windows: nil, lastFetch: .distantPast, now: now))
        #expect(!ProviderThrottle.resetDue(windows: [], lastFetch: .distantPast, now: now))
    }

    @Test func futureResetNotDue() {
        let windows = [window(resetsAt: now.addingTimeInterval(3600))]
        #expect(!ProviderThrottle.resetDue(windows: windows, lastFetch: now.addingTimeInterval(-300), now: now))
    }

    @Test func resetPassedAfterLastFetchIsDue() {
        // Slept through the reset: snapshot predates the rollover.
        let windows = [window(resetsAt: now.addingTimeInterval(-3600))]
        #expect(ProviderThrottle.resetDue(
            windows: windows,
            lastFetch: now.addingTimeInterval(-7200),
            now: now
        ))
    }

    @Test func fetchedSinceResetNotDue() {
        // Already refetched after the rollover — normal throttle applies.
        let windows = [window(resetsAt: now.addingTimeInterval(-3600))]
        #expect(!ProviderThrottle.resetDue(
            windows: windows,
            lastFetch: now.addingTimeInterval(-60),
            now: now
        ))
    }

    @Test func missingResetsAtNeverDue() {
        let windows = [window(resetsAt: nil)]
        #expect(!ProviderThrottle.resetDue(windows: windows, lastFetch: .distantPast, now: now))
    }

    @Test func anyDueWindowForcesRefresh() {
        let windows = [
            window(resetsAt: now.addingTimeInterval(3600)),
            UsageWindow(id: "Claude-Rolling", label: "Rolling", tokensUsed: 0,
                        percentRemaining: 50, resetsAt: now.addingTimeInterval(-100)),
        ]
        #expect(ProviderThrottle.resetDue(
            windows: windows,
            lastFetch: now.addingTimeInterval(-1000),
            now: now
        ))
    }
}
