import Foundation
import Testing
@testable import BurnRate

struct MilestoneEvaluatorTests {
    @Test func gridForStep20() {
        #expect(MilestoneEvaluator.thresholds(step: 20) == [80, 60, 40, 20])
    }

    @Test func gridForStep10() {
        #expect(MilestoneEvaluator.thresholds(step: 10) == [90, 80, 70, 60, 50, 40, 30, 20, 10])
    }

    @Test func crossesDownPastLevel() {
        #expect(MilestoneEvaluator.crossed(previousRemaining: 85, currentRemaining: 79, step: 20))
        #expect(MilestoneEvaluator.crossedThreshold(previousRemaining: 85, currentRemaining: 79, step: 20) == 80)
    }

    @Test func crossesOnExactLanding() {
        #expect(MilestoneEvaluator.crossed(previousRemaining: 85, currentRemaining: 80, step: 20))
    }

    @Test func noCrossWhenStillAbove() {
        #expect(!MilestoneEvaluator.crossed(previousRemaining: 85, currentRemaining: 81, step: 20))
    }

    @Test func noRepeatNotificationWhileBelowLevel() {
        // 75 → 70 stays inside the 80/60 band: nothing new crossed.
        #expect(!MilestoneEvaluator.crossed(previousRemaining: 75, currentRemaining: 70, step: 20))
    }

    @Test func bigDropReportsHighestLevel() {
        #expect(MilestoneEvaluator.crossedThreshold(previousRemaining: 95, currentRemaining: 55, step: 20) == 80)
    }

    @Test func noFireOnFirstObservation() {
        #expect(!MilestoneEvaluator.crossed(previousRemaining: nil, currentRemaining: 5, step: 10))
        #expect(MilestoneEvaluator.crossedThreshold(previousRemaining: nil, currentRemaining: 5, step: 10) == nil)
    }

    @Test func noCrossWhenRecoveringAboveLevel() {
        #expect(!MilestoneEvaluator.crossed(previousRemaining: 60, currentRemaining: 85, step: 20))
    }

    @Test func legacyThresholdDecodesToStep() throws {
        let legacy = """
        [{"provider":"Claude","windowLabel":"Rolling","percentRemaining":20}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([Milestone].self, from: legacy)
        #expect(decoded.count == 1)
        #expect(decoded[0].step == 20)
        #expect(decoded[0].id == "Claude|Rolling")
    }

    @Test func duplicatesCollapseToOneRuleKeepingSmallestStep() {
        let rules = Milestone.coalesce([
            Milestone(provider: "Claude", windowLabel: "Rolling", step: 20),
            Milestone(provider: "Claude", windowLabel: "Rolling", step: 10),
            Milestone(provider: "Codex", windowLabel: "Rolling", step: 20),
        ])
        #expect(rules.count == 2)
        #expect(rules.first { $0.key == "Claude|Rolling" }?.step == 10)
    }
}
