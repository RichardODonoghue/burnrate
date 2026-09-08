import Foundation

/// A local data source for one plan provider. No network, no auth:
/// everything is parsed from the CLI tools' own session logs on disk.
/// Actors: parsing can take seconds and must not block the main thread;
/// the actor also serializes cache access across overlapping polls.
protocol UsageSource: Actor {
    nonisolated var name: String { get }
    /// All usage events found in local logs. Callers aggregate into windows.
    func collectSamples() async throws -> [UsageSample]
}

/// Logs older than this cannot contribute to any tracked window (5hr/7d/30d),
/// so sources skip and prune them.
let sampleRetention: TimeInterval = 31 * 86400

/// ISO8601 timestamps used by Claude Code and Codex session logs.
enum LogDate {
    static func parse(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}

// MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

/// Assistant messages carry usage + timestamp; sum across all projects.
/// Logs are append-only, so parses are incremental: unchanged files are
/// skipped and grown files are read from the last-known byte offset.
actor ClaudeUsageSource: UsageSource {
    nonisolated let name = "Claude"
    private let baseURL: URL
    /// path -> (mtime, size consumed, parsed samples)
    private var cache: [String: (mtime: Date, size: Int, samples: [UsageSample])] = [:]

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
    }

    func collectSamples() throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return [] }
        let files = FileManager.default.enumerator(at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" } ?? []

        var all: [UsageSample] = []
        let cutoff = Date().addingTimeInterval(-sampleRetention)
        var seenPaths = Set<String>()
        for file in files {
            seenPaths.insert(file.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            guard mtime > cutoff else { continue } // cannot affect any window

            let newSize = (attrs?[.size] as? Int) ?? 0
            let cached = cache[file.path]
            var samples: [UsageSample]
            if let cached, newSize >= cached.size, mtime == cached.mtime {
                // Append-only: parse only the new bytes.
                if newSize > cached.size, let appended = try Self.readTail(file, fromOffset: cached.size) {
                    samples = cached.samples + Self.parseLines(appended)
                } else {
                    samples = cached.samples
                }
            } else {
                samples = (try? Self.parseFile(at: file)) ?? []
            }
            samples = samples.filter { $0.timestamp > cutoff }
            cache[file.path] = (mtime, newSize, samples)
            all.append(contentsOf: samples)
        }
        // Drop entries for files that were deleted or rotated away.
        cache = cache.filter { seenPaths.contains($0.key) }
        return all
    }

    /// Each line: {"timestamp":"...","type":"assistant","message":{"usage":{...}}}
    static func parseFile(at url: URL) throws -> [UsageSample] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseLines(text)
    }

    static func parseLines(_ text: String) -> [UsageSample] {
        var samples: [UsageSample] = []
        for line in text.split(separator: "\n") {
            // Cheap prefilter: only JSON lines with a usage block are parsed.
            guard line.contains(#""usage""#) else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = (obj["timestamp"] as? String).flatMap(LogDate.parse)
            else { continue }

            let tokens = TokenUsage(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0
            )
            samples.append(UsageSample(timestamp: timestamp, tokens: tokens))
        }
        return samples
    }

    private static func readTail(_ url: URL, fromOffset offset: Int) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return String(data: handle.readDataToEndOfFile(), encoding: .utf8)
    }
}

// MARK: - Codex CLI (~/.codex/sessions/**/*.jsonl)

/// Sessions emit cumulative `token_count` events; the last event per session
/// file holds that session's total.
actor CodexUsageSource: UsageSource {
    nonisolated let name = "Codex"
    private let baseURL: URL
    /// path -> last cumulative sample (nil = parsed, no token events found).
    private var cache: [String: UsageSample?] = [:]

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions")
    }

    func collectSamples() throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return [] }
        let files = FileManager.default.enumerator(at: baseURL, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" } ?? []
        var seenPaths = Set<String>()
        let samples = try files.compactMap { file -> UsageSample? in
            seenPaths.insert(file.path)
            if let cached = cache[file.path] ?? nil,
               let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
               cached.timestamp >= mtime {
                return cached
            }
            let sample = try Self.parseSessionFile(at: file)
            // .some so files with no token events stay cached instead of
            // being re-read every poll.
            cache[file.path] = .some(sample)
            return sample
        }
        // Drop entries for files that were deleted or rotated away.
        cache = cache.filter { seenPaths.contains($0.key) }
        return samples
    }

    /// One sample per file: the last cumulative total_token_usage event.
    static func parseSessionFile(at url: URL) throws -> UsageSample? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var last: UsageSample?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let timestamp = (obj["timestamp"] as? String).flatMap(LogDate.parse)
            else { continue }

            let tokens = TokenUsage(
                input: totals["input_tokens"] as? Int ?? 0,
                output: totals["output_tokens"] as? Int ?? 0,
                cacheRead: totals["cached_input_tokens"] as? Int ?? 0,
                cacheWrite: 0
            )
            last = UsageSample(timestamp: timestamp, tokens: tokens)
        }
        return last
    }
}

// MARK: - OpenCode (~/.local/share/opencode/opencode.db, SQLite + WAL)

/// OpenCode stores assistant messages (with token counts and providerID) in
/// SQLite. Query it read-only with a time filter — WAL lets concurrent
/// readers run against the live DB, so no snapshot copy is needed.
actor OpenCodeUsageSource: UsageSource {
    nonisolated let name = "OpenCode Go"
    let providerIDFilter: String
    let dbURL: URL

    init(
        providerIDFilter: String = "opencode-go",
        dbURL: URL? = nil
    ) {
        self.providerIDFilter = providerIDFilter
        self.dbURL = dbURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    func collectSamples() throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        let cutoffMs = Int(Date().addingTimeInterval(-sampleRetention).timeIntervalSince1970 * 1000)
        return try Self.querySamples(from: dbURL, providerIDFilter: providerIDFilter, cutoffMs: cutoffMs)
    }

    /// Internal (not private) so tests can run it against a fixture DB.
    static func querySamples(from dbPath: URL, providerIDFilter: String, cutoffMs: Int) throws -> [UsageSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            dbPath.path,
            "-separator",
            "\t",
            """
            SELECT json_extract(data,'$.providerID'), data FROM message \
            WHERE time_created > \(cutoffMs) AND json_extract(data,'$.role')='assistant';
            """,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read the pipe to EOF BEFORE waiting: draining concurrently avoids
        // deadlock when output exceeds the pipe buffer.
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        var samples: [UsageSample] = []
        for line in output.split(separator: "\n") {
            guard let tabIndex = line.firstIndex(of: "\t") else { continue }
            let providerID = String(line[line.startIndex..<tabIndex])
            guard providerID == providerIDFilter else { continue }
            if let sample = parseMessageJSON(String(line[line.index(after: tabIndex)...])) {
                samples.append(sample)
            }
        }
        return samples
    }

    /// message.data JSON: {providerID, tokens:{input,output,reasoning,cache:{read,write}}, time:{created: ms}}
    static func parseMessageJSON(_ json: String) -> UsageSample? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let time = obj["time"] as? [String: Any],
              let createdMs = time["created"] as? Double
        else { return nil }
        let cache = tokens["cache"] as? [String: Any]
        return UsageSample(
            timestamp: Date(timeIntervalSince1970: createdMs / 1000),
            tokens: TokenUsage(
                input: tokens["input"] as? Int ?? 0,
                output: tokens["output"] as? Int ?? 0,
                cacheRead: cache?["read"] as? Int ?? 0,
                cacheWrite: cache?["write"] as? Int ?? 0
            )
        )
    }
}
