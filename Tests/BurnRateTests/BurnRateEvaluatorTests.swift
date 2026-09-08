import Foundation
import Testing
@testable import BurnRate

struct BurnRateEvaluatorTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let poll: TimeInterval = 300

    private func sample(_ minutesAgo: Double, _ remaining: Double) -> (date: Date, remaining: Double) {
        (now.addingTimeInterval(-minutesAgo * 60), remaining)
    }

    private let alert = BurnAlert(provider: "Claude", windowLabel: "Rolling", percentDrop: 15, minutes: 30)

    @Test func firesOnFastDrop() {
        let history = [sample(35, 80), sample(30, 78), sample(5, 60)]
        let hit = BurnRateEvaluator.detect(history: history, alert: alert, now: now, pollInterval: poll)
        #expect(hit != nil)
        #expect(hit?.drop == 20)
        #expect(hit?.baseline == 80)
        #expect(hit?.current == 60)
    }

    @Test func noFireOnSlowBurn() {
        let history = [sample(35, 80), sample(30, 78), sample(5, 70)]
        #expect(BurnRateEvaluator.detect(history: history, alert: alert, now: now, pollInterval: poll) == nil)
    }

    @Test func ignoresHistoryOlderThanWindow() {
        // Big drop, but it happened before the 30-min window: baseline is the
        // oldest in-window sample (35 min ago + slack), not 2 hours ago.
        let history = [sample(120, 90), sample(35, 80), sample(30, 78), sample(5, 60)]
        let hit = BurnRateEvaluator.detect(history: history, alert: alert, now: now, pollInterval: poll)
        #expect(hit?.baseline == 80)
    }

    @Test func noFireWithTooLittleHistory() {
        // App just started: only readings from the last few minutes.
        let history = [sample(10, 80), sample(5, 60)]
        #expect(BurnRateEvaluator.detect(history: history, alert: alert, now: now, pollInterval: poll) == nil)
    }

    @Test func noFireWhenRemainingIncreases() {
        let history = [sample(35, 60), sample(30, 65), sample(5, 80)]
        #expect(BurnRateEvaluator.detect(history: history, alert: alert, now: now, pollInterval: poll) == nil)
    }

    @Test func emptyHistoryNeverFires() {
        #expect(BurnRateEvaluator.detect(history: [], alert: alert, now: now, pollInterval: poll) == nil)
    }
}
