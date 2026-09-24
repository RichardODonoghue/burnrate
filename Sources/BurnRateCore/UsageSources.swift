import Foundation

/// A local data source for one plan provider. No network, no auth:
/// everything is parsed from the CLI tools' own session logs on disk.
/// Actors: parsing can take seconds and must not block the main thread;
/// the actor also serializes cache access across overlapping polls.
public protocol UsageSource: Actor {
    nonisolated var name: String { get }
    /// All usage events found in local logs. Callers aggregate into windows.
    func collectSamples() async throws -> [UsageSample]
}

/// Logs older than this cannot contribute to any tracked window (5hr/7d/30d),
/// so sources skip and prune them.
public let sampleRetention: TimeInterval = 31 * 86400

/// Lossy UTF-8 read — a single bad byte must not zero out a whole file.
public func readTextFile(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

/// ISO8601 timestamps used by Claude Code and Codex session logs.
public enum LogDate {
    // Formatters are expensive to build and `parse` runs per log line;
    // reused statically. ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

// MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

/// Assistant messages carry usage + timestamp; sum across all projects.
/// Logs are append-only, so parses are incremental: unchanged files are
/// skipped and grown files are read from the last-known byte offset.
public actor ClaudeUsageSource: UsageSource {
    public nonisolated let name = "Claude"
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

    public init(baseURL: URL? = nil, cacheURL: URL? = nil, paths: any AppPaths = FileManagerPaths()) {
        self.baseURL = baseURL
            ?? paths.homeDirectory.appendingPathComponent(".claude/projects")
        self.cacheURL = cacheURL
            ?? paths.appDirectory.appendingPathComponent("claude-cache.json")
    }

    public func collectSamples() throws -> [UsageSample] {
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
    public static func parseFile(at url: URL) throws -> [UsageSample] {
        let text = readTextFile(url)
        return dedupe(parseLines(text))
    }

    /// Keeps the last occurrence per requestId; samples without one pass through.
    public static func dedupe(_ samples: [UsageSample]) -> [UsageSample] {
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

    public static func parseLines(_ text: String) -> [UsageSample] {
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

            // Claude Code writes zero-usage placeholder lines for synthetic
            // (locally generated) turns; they are not a model.
            if (message["model"] as? String) == "<synthetic>" { continue }

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
public actor CodexUsageSource: UsageSource {
    public nonisolated let name = "Codex"
    private let baseURL: URL
    /// path -> last cumulative sample (nil = parsed, no token events found).
    private var cache: [String: UsageSample?] = [:]

    public init(baseURL: URL? = nil, paths: any AppPaths = FileManagerPaths()) {
        self.baseURL = baseURL
            ?? paths.homeDirectory.appendingPathComponent(".codex/sessions")
    }

    public func collectSamples() throws -> [UsageSample] {
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
    public static func parseSessionFile(at url: URL) throws -> UsageSample? {
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
                cacheWrite: 0,
                reasoning: totals["reasoning_output_tokens"] as? Int ?? 0
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
public actor OpenCodeUsageSource: UsageSource {
    public nonisolated let name = "OpenCode Go"
    public let providerIDFilter: String?
    public let dbURL: URL
    /// v2 may store the DB under a different XDG dir; checked in order.
    private let dbCandidates: [URL]
    private let sqlite: any SQLiteQuerying

    public init(
        providerIDFilter: String? = nil,
        dbURL: URL? = nil,
        paths: any AppPaths = FileManagerPaths(),
        sqlite: any SQLiteQuerying = ProcessSQLiteRunner()
    ) {
        let candidates = [
            paths.dataDirectory.appendingPathComponent("opencode/opencode.db"),
            paths.homeDirectory.appendingPathComponent(".local/share/opencode/opencode.db"),
            paths.configDirectory.appendingPathComponent("opencode/opencode.db"),
        ]
        self.dbCandidates = candidates
        self.providerIDFilter = providerIDFilter
        self.sqlite = sqlite
        self.dbURL = dbURL ?? candidates[0]
    }

    public func collectSamples() throws -> [UsageSample] {
        guard let database = dbCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) ?? (FileManager.default.fileExists(atPath: dbURL.path) ? dbURL : nil) else {
            return []
        }
        let cutoffMs = Int(Date().addingTimeInterval(-sampleRetention).timeIntervalSince1970 * 1000)
        return try Self.querySamples(
            from: database, providerIDFilter: providerIDFilter, cutoffMs: cutoffMs, sqlite: sqlite)
    }

    /// Internal (not private) so tests can run it against a fixture DB.
    /// `providerIDFilter == nil` keeps all providers (model/cost views).
    ///
    /// OpenCode migrated storage: newer builds append assistant turns to
    /// `session_message` (provider/model nested under `model`, tokens at the
    /// top level); older builds used `message` (flat `providerID`/`modelID`).
    /// Query whichever tables exist so both are covered.
    public static func querySamples(
        from dbPath: URL,
        providerIDFilter: String?,
        cutoffMs: Int,
        sqlite: any SQLiteQuerying = ProcessSQLiteRunner()
    ) throws -> [UsageSample] {
        let tables = try tableNames(in: dbPath, sqlite: sqlite)
        var samples: [UsageSample] = []

        if tables.contains("session_message") {
            let output = try sqlite.query(databaseAt: dbPath, sql: """
                SELECT id, json_extract(data,'$.model.providerID'), data FROM session_message \
                WHERE time_created > \(cutoffMs) AND type='assistant';
                """)
            samples += parseRows(output, providerIDFilter: providerIDFilter, using: parseSessionMessageJSON)
        }

        if tables.contains("message") {
            let output = try sqlite.query(databaseAt: dbPath, sql: """
                SELECT id, json_extract(data,'$.providerID'), data FROM message \
                WHERE time_created > \(cutoffMs) AND json_extract(data,'$.role')='assistant';
                """)
            samples += parseRows(output, providerIDFilter: providerIDFilter, using: parseMessageJSON)
        }

        // The storage migration copied rows into `session_message`, so the same
        // message id appears in both tables — dedupe by id.
        var seen = Set<String>()
        return samples.filter { sample in
            guard let id = sample.requestId, !id.isEmpty else { return true }
            return seen.insert(id).inserted
        }
    }

    private static func tableNames(in dbPath: URL, sqlite: any SQLiteQuerying) throws -> Set<String> {
        let output = try sqlite.query(
            databaseAt: dbPath,
            sql: "SELECT name FROM sqlite_master WHERE type='table';")
        return Set(output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func parseRows(
        _ output: String,
        providerIDFilter: String?,
        using parse: (String) -> UsageSample?
    ) -> [UsageSample] {
        var samples: [UsageSample] = []
        for line in output.split(separator: "\n") {
            // Columns: id \t providerID \t data
            guard let firstTab = line.firstIndex(of: "\t") else { continue }
            let id = String(line[line.startIndex..<firstTab])
            let rest = line[line.index(after: firstTab)...]
            guard let secondTab = rest.firstIndex(of: "\t") else { continue }
            let providerID = String(rest[rest.startIndex..<secondTab])
            if let providerIDFilter, providerID != providerIDFilter { continue }
            guard var sample = parse(String(rest[rest.index(after: secondTab)...])) else { continue }
            sample.requestId = id
            samples.append(sample)
        }
        return samples
    }

    /// New `session_message` shape:
    /// {model:{id,providerID}, cost, tokens:{input,output,reasoning,cache:{read,write}},
    ///  time:{created: ms}}
    public static func parseSessionMessageJSON(_ json: String) -> UsageSample? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let time = obj["time"] as? [String: Any],
              let createdMs = time["created"] as? Double
        else { return nil }
        let model = obj["model"] as? [String: Any]
        let cache = tokens["cache"] as? [String: Any]
        return UsageSample(
            timestamp: Date(timeIntervalSince1970: createdMs / 1000),
            tokens: TokenUsage(
                input: tokens["input"] as? Int ?? 0,
                output: tokens["output"] as? Int ?? 0,
                cacheRead: cache?["read"] as? Int ?? 0,
                cacheWrite: cache?["write"] as? Int ?? 0,
                reasoning: tokens["reasoning"] as? Int ?? 0
            ),
            model: model?["id"] as? String,
            cost: obj["cost"] as? Double,
            sourceTag: model?["providerID"] as? String
        )
    }

    /// Legacy `message.data` shape:
    /// {providerID, modelID, cost, tokens:{...}, time:{created: ms}}
    public static func parseMessageJSON(_ json: String) -> UsageSample? {
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
                cacheWrite: cache?["write"] as? Int ?? 0,
                reasoning: tokens["reasoning"] as? Int ?? 0
            ),
            model: obj["modelID"] as? String,
            cost: obj["cost"] as? Double,
            sourceTag: obj["providerID"] as? String
        )
    }
}
