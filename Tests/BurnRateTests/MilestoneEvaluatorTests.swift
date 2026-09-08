import Testing
@testable import BurnRate

struct MilestoneEvaluatorTests {
    @Test func crossesWhenDroppingToThreshold() {
        #expect(MilestoneEvaluator.crossed(previousRemaining: 25, currentRemaining: 20, threshold: 20))
    }

    @Test func crossesOnFirstObservation() {
        #expect(MilestoneEvaluator.crossed(previousRemaining: nil, currentRemaining: 19, threshold: 20))
    }

    @Test func noCrossWhenStillAbove() {
        #expect(!MilestoneEvaluator.crossed(previousRemaining: 25, currentRemaining: 21, threshold: 20))
    }

    @Test func noRepeatNotificationWhileBelowThreshold() {
        #expect(!MilestoneEvaluator.crossed(previousRemaining: 18, currentRemaining: 17, threshold: 20))
    }

    @Test func noCrossWhenRecoveringAboveThreshold() {
        #expect(!MilestoneEvaluator.crossed(previousRemaining: 15, currentRemaining: 30, threshold: 20))
    }
}
