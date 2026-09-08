import Foundation
import Testing
@testable import BurnRate

struct PricingServiceTests {
    private let table: [String: ModelPricing] = [
        "claude-opus-5": ModelPricing(input: 5e-6, output: 2.5e-5, cacheRead: 5e-7, cacheWrite: 6.25e-6),
        "claude-sonnet-5": ModelPricing(input: 2e-6, output: 1e-5, cacheRead: 2e-7, cacheWrite: 2.5e-6),
    ]

    @Test func parsesBareKeysOnly() throws {
        let body = #"""
        {"claude-opus-5": {"input_cost_per_token": 5e-6, "output_cost_per_token": 2.5e-5,
                           "cache_read_input_token_cost": 5e-7, "cache_creation_input_token_cost": 6.25e-6},
         "anthropic.claude-opus-5": {"input_cost_per_token": 1, "output_cost_per_token": 1},
         "vertex_ai/claude-sonnet-5": {"input_cost_per_token": 1, "output_cost_per_token": 1},
         "gpt-x": {"output_cost_per_token": 1}}
        """#
        let table = try PricingService.parse(Data(body.utf8))
        #expect(table.count == 1)
        #expect(table["claude-opus-5"] != nil)
    }

    @Test func exactLookup() {
        #expect(PricingService.lookup("claude-opus-5", in: table)?.output == 2.5e-5)
    }

    @Test func prefixLookupForDatedSnapshots() {
        #expect(PricingService.lookup("claude-opus-5-20260101", in: table)?.input == 5e-6)
    }

    @Test func unknownModelReturnsNil() {
        #expect(PricingService.lookup("mystery-model", in: table) == nil)
    }

    @Test func costCalculationWeightsCaches() {
        let pricing = PricingService.lookup("claude-opus-5", in: table)!
        let tokens = TokenUsage(input: 1_000_000, output: 100_000, cacheRead: 10_000_000, cacheWrite: 1_000_000)
        let expected = 1_000_000 * 5e-6 + 100_000 * 2.5e-5 + 10_000_000 * 5e-7 + 1_000_000 * 6.25e-6
        var cost = Double(tokens.input) * pricing.input + Double(tokens.output) * pricing.output
        cost += Double(tokens.cacheRead) * (pricing.cacheRead ?? 0)
        cost += Double(tokens.cacheWrite) * (pricing.cacheWrite ?? 0)
        #expect(abs(cost - expected) < 0.0001)
        #expect(cost > 4)
    }
}
