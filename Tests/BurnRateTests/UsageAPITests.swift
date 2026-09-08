import Foundation
import Testing
@testable import BurnRate

struct UsageAPITests {
    @Test func parsesClaudeLimitsArrayIncludingModelScoped() throws {
        // Real response shape: limits array with session, weekly_all and a
        // model-scoped weekly limit (Fable).
        let body = #"""
        {"five_hour":{"utilization":99.0,"resets_at":"2026-09-08T06:59:59Z"},
         "seven_day":{"utilization":42.0,"resets_at":"2026-09-12T17:59:59Z"},
         "limits":[
           {"kind":"session","percent":99,"severity":"critical","resets_at":"2026-09-08T06:59:59Z","is_active":true},
           {"kind":"weekly_all","percent":42,"resets_at":"2026-09-12T17:59:59Z","is_active":false},
           {"kind":"weekly_scoped","percent":39,"resets_at":"2026-09-12T17:59:59Z",
            "scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":false}
         ]}
        """#
        let windows = try ClaudeUsageAPIProvider.parseWindows(Data(body.utf8))
        #expect(windows.count == 3)
        #expect(windows[0].label == "5hr")
        #expect(windows[0].percentRemaining == 1)
        #expect(windows[1].label == "Weekly")
        #expect(windows[1].percentRemaining == 58)
        #expect(windows[2].label == "Fable")
        #expect(windows[2].percentRemaining == 61)
        #expect(windows.allSatisfy { $0.resetsAt != nil })
    }

    @Test func claudeFallbackParsesFlatKeysWithoutLimits() throws {
        let body = #"""
        {"five_hour":{"utilization":99.0,"resets_at":"2026-09-08T06:59:59.841728+00:00"},
         "seven_day":{"utilization":42.0,"resets_at":"2026-09-12T17:59:59.841745+00:00"}}
        """#
        let windows = try ClaudeUsageAPIProvider.parseWindows(Data(body.utf8))
        #expect(windows.count == 2)
        #expect(windows[0].label == "5hr")
        #expect(windows[0].percentRemaining == 1)
        #expect(windows[1].label == "Weekly")
        #expect(windows[1].percentRemaining == 58)
        #expect(windows[0].resetsAt != nil)
    }

    @Test func claudeClampsUtilizationOver100() throws {
        let body = #"{"five_hour":{"utilization":120.0}}"#
        let windows = try ClaudeUsageAPIProvider.parseWindows(Data(body.utf8))
        #expect(windows[0].percentRemaining == 0)
    }

    @Test func parsesOpenCodeGoWindows() throws {
        let body = #"""
        {"usage":{"rolling":{"status":"ok","percent":2,"resetsAt":"2026-09-08T07:35:35.967Z"},
                  "weekly":{"status":"ok","percent":26,"resetsAt":"2026-09-14T00:00:00.967Z"},
                  "monthly":{"status":"ok","percent":18,"resetsAt":"2026-09-17T04:14:35.967Z"}}}
        """#
        let windows = try OpenCodeGoUsageAPIProvider.parseWindows(Data(body.utf8))
        #expect(windows.count == 3)
        #expect(windows.map(\.label) == ["Rolling", "Weekly", "Monthly"])
        #expect(windows[0].percentRemaining == 98)
        #expect(windows[1].percentRemaining == 74)
        #expect(windows[2].percentRemaining == 82)
        #expect(windows.allSatisfy { $0.resetsAt != nil })
    }

    @Test func localProviderReturnsNilWithoutSamples() async {
        actor EmptySource: UsageSource {
            nonisolated let name = "Empty"
            func collectSamples() throws -> [UsageSample] { [] }
        }
        let provider = LocalUsageProvider(source: EmptySource())
        let usage = await provider.fetchUsage(capacities: ["Empty|5hr": 1000])
        #expect(usage == nil)
    }

    @Test func localProviderReturnsUsageWithSamples() async {
        actor StubSource: UsageSource {
            nonisolated let name = "Stub"
            func collectSamples() throws -> [UsageSample] {
                [UsageSample(timestamp: Date(), tokens: .init(input: 100, output: 0, cacheRead: 0, cacheWrite: 0))]
            }
        }
        let provider = LocalUsageProvider(source: StubSource())
        let usage = await provider.fetchUsage(capacities: ["Stub|5hr": 1000])
        #expect(usage != nil)
        #expect(usage?.windows.first { $0.label == "5hr" }?.percentRemaining == 90)
    }

    @Test func parsesOpenCodeGoAPIKeyFromAuthJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-test-\(UUID().uuidString).json")
        try #"{"opencode-go":{"type":"api","key":"sk-test-123"}}"#.write(to: dir, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = OpenCodeGoUsageAPIProvider.readAPIKey(at: dir)
        #expect(key == "sk-test-123")
    }
}
