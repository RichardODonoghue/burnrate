import BurnRateCore
import Testing
@testable import BurnRate

struct ModelsViewAxisLabelTests {
    @Test func axisLabelsShortenUnits() {
        #expect(ModelsView.axisLabel(850, metric: .tokens) == "850")
        #expect(ModelsView.axisLabel(2_500_000, metric: .tokens) == "2.5m")
        #expect(ModelsView.axisLabel(3_600_000_000, metric: .tokens) == "3.6b")
        #expect(ModelsView.axisLabel(0.5, metric: .cost) == "$0.5")
        #expect(ModelsView.axisLabel(2500, metric: .cost) == "$2.5k")
    }
}
