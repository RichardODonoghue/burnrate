import Foundation
import Testing
@testable import BurnRate

struct UsageSourceTests {
    @Test func parsesClaudeAssistantLine() throws {
        let line = #"{"timestamp":"2026-09-08T10:00:00.000Z","type":"assistant","message":{"model":"claude-sonnet-4","usage":{"input_tokens":6,"cache_creation_input_tokens":41797,"cache_read_input_tokens":0,"output_tokens":458}}}"#
        let url = try writeTemp(line + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try ClaudeUsageSource.parseFile(at: url)
        #expect(samples.count == 1)
        #expect(samples[0].tokens == TokenUsage(input: 6, output: 458, cacheRead: 0, cacheWrite: 41797))
        #expect(samples[0].tokens.total == 42261)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(samples[0].timestamp == formatter.date(from: "2026-09-08T10:00:00.000Z"))
    }

    @Test func ignoresUserLines() throws {
        let line = #"{"timestamp":"2026-09-08T10:00:00.000Z","type":"user","message":{}}"#
        let url = try writeTemp(line + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ClaudeUsageSource.parseFile(at: url).isEmpty)
    }

    @Test func dedupesRepeatedRequestIdsKeepingLast() throws {
        // Same request logged three times (streaming/resume); last is final.
        let lines = #"""
        {"timestamp":"2026-09-08T10:00:00.000Z","type":"assistant","requestId":"req_1","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"timestamp":"2026-09-08T10:00:05.000Z","type":"assistant","requestId":"req_1","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":3000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"timestamp":"2026-09-08T10:01:00.000Z","type":"assistant","requestId":"req_2","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """#
        let url = try writeTemp(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try ClaudeUsageSource.parseFile(at: url)
        #expect(samples.count == 2)
        let req1 = samples.first { $0.requestId == "req_1" }
        #expect(req1?.tokens.output == 3000)
    }

    @Test func codexTakesLastCumulativeEvent() throws {
        let lines = #"""
        {"timestamp":"2026-09-08T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":50,"reasoning_output_tokens":5}}}}
        {"timestamp":"2026-09-08T10:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":20,"output_tokens":90,"reasoning_output_tokens":15}}}}
        """#
        let url = try writeTemp(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let sample = try CodexUsageSource.parseSessionFile(at: url)
        #expect(sample?.tokens == TokenUsage(input: 300, output: 90, cacheRead: 20, cacheWrite: 0))
    }

    @Test func parsesOpenCodeMessageJSON() throws {
        let json = #"{"role":"assistant","cost":0.11,"tokens":{"total":56022,"input":55815,"output":53,"reasoning":154,"cache":{"write":0,"read":0}},"providerID":"opencode-go","time":{"created":1788830155613}}"#
        let sample = OpenCodeUsageSource.parseMessageJSON(json)
        #expect(sample?.tokens == TokenUsage(input: 55815, output: 53, cacheRead: 0, cacheWrite: 0))
        #expect(sample?.timestamp.timeIntervalSince1970 == 1788830155.613)
    }

    @Test func parsesOpenCodeSQLiteSnapshot() throws {
        // Build a real DB with the system sqlite3 and parse it back.
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-opencode-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: db) }
        let msg = #"{"role":"assistant","tokens":{"input":1000,"output":100,"reasoning":0,"cache":{"read":50,"write":0}},"providerID":"opencode-go","time":{"created":1788830155613}}"#
        try runSQLite(db, sql: "CREATE TABLE message (id text PRIMARY KEY, time_created integer, data text);")
        try runSQLite(db, sql: "INSERT INTO message VALUES ('m1',1788830155613,'\(msg)');")
        try runSQLite(db, sql: #"INSERT INTO message VALUES ('m2',1788830155613,'{"role":"assistant","providerID":"other"}');"#)

        let cutoffMs = 1788830155613 - 60_000
        let samples = try OpenCodeUsageSource.querySamples(from: db, providerIDFilter: "opencode-go", cutoffMs: cutoffMs)
        #expect(samples.count == 1)
        #expect(samples[0].tokens.total == 1150)
    }

    private func writeTemp(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-test-\(UUID().uuidString).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runSQLite(_ db: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
