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

/// Lossy UTF-8 read — a single bad byte must not zero out a whole file.
func readTextFile(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

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
    /// Persisted incremental-cache state (see `collectSamples`). Survives app
    /// restarts so the ~560MB first parse happens once, not every launch.
    private struct CachedFile: Codable {
        var mtime: Date
        var size: Int
        var samples: [UsageSample]
    }
    /// path -> (mtime, size consumed, parsed samples)
    private var cache: [String: CachedFile] = [:]
    private var cacheLoaded = false
    private let cacheURL: URL

    init(baseURL: URL? = nil, cacheURL: URL? = nil) {
        self.baseURL = baseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
        self.cacheURL = cacheURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BurnRate/claude-cache.json")
    }

    func collectSamples() throws -> [UsageSample] {
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return [] }
        if !cacheLoaded {
            cache = Self.loadCache(from: cacheURL)
            cacheLoaded = true
        }
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
                // Append-only: parse only the new bytes, then re-dedupe —
                // a request's final line can land after the cached offset.
                if newSize > cached.size, let appended = try Self.readTail(file, fromOffset: cached.size) {
                    samples = Self.dedupe(cached.samples + Self.parseLines(appended))
                } else {
                    samples = cached.samples
                }
            } else {
                samples = (try? Self.parseFile(at: file)) ?? []
            }
            samples = samples.filter { $0.timestamp > cutoff }
            cache[file.path] = CachedFile(mtime: mtime, size: newSize, samples: samples)
            all.append(contentsOf: samples)
        }
        // Drop entries for files that were deleted or rotated away.
        cache = cache.filter { seenPaths.contains($0.key) }
        Self.saveCache(cache, to: cacheURL)
        // The same requestId can appear in multiple files (resumed/copied
        // sessions): dedupe globally, keeping the latest reading.
        return Self.dedupe(all)
    }

    private static func loadCache(from url: URL) -> [String: CachedFile] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CachedFile].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveCache(_ cache: [String: CachedFile], to url: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Each line: {"timestamp":"...","type":"assistant","message":{"usage":{...}}}
    /// Lines repeat per requestId (streaming/resume rewrites), so results are
    /// deduped: one sample per request, keeping the last (final cumulative)
    /// reading.
    static func parseFile(at url: URL) throws -> [UsageSample] {
        let text = readTextFile(url)
        return dedupe(parseLines(text))
    }

    /// Keeps the last occurrence per requestId; samples without one pass through.
    static func dedupe(_ samples: [UsageSample]) -> [UsageSample] {
        var byRequest: [String: (index: Int, sample: UsageSample)] = [:]
        var result: [UsageSample] = []
        for sample in samples {
            guard let requestId = sample.requestId, !requestId.isEmpty else {
                result.append(sample)
                continue
            }
            if let existing = byRequest[requestId] {
                result[existing.index] = sample
            } else {
                byRequest[requestId] = (result.count, sample)
                result.append(sample)
            }
        }
        return result
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
            samples.append(UsageSample(
                timestamp: timestamp,
                tokens: tokens,
                requestId: obj["requestId"] as? String ?? obj["request_id"] as? String,
                model: message["model"] as? String,
                cost: obj["costUSD"] as? Double
            ))
        }
        return samples
    }

    private static func readTail(_ url: URL, fromOffset offset: Int) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
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
    /// Model comes from the session's turn_context/session_meta lines.
    static func parseSessionFile(at url: URL) throws -> UsageSample? {
        let text = readTextFile(url)
        var last: UsageSample?
        var model: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if model == nil, let payload = obj["payload"] as? [String: Any],
               let m = payload["model"] as? String {
                model = m
            }

            guard obj["type"] as? String == "event_msg",
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
            last = UsageSample(
                timestamp: timestamp,
                tokens: tokens,
                model: model,
                cost: nil
            )
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
    let providerIDFilter: String?
    let dbURL: URL

    init(providerIDFilter: String? = nil, dbURL: URL? = nil) {
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
    /// `providerIDFilter == nil` keeps all providers (model/cost views).
    static func querySamples(from dbPath: URL, providerIDFilter: String?, cutoffMs: Int) throws -> [UsageSample] {
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
            if let providerIDFilter, providerID != providerIDFilter { continue }
            if let sample = parseMessageJSON(String(line[line.index(after: tabIndex)...])) {
                samples.append(sample)
            }
        }
        return samples
    }

    /// message.data JSON: {providerID, modelID, cost, tokens:{input,output,reasoning,cache:{read,write}}, time:{created: ms}}
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
            ),
            model: obj["modelID"] as? String,
            cost: obj["cost"] as? Double
        )
    }
}
