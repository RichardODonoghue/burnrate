//! Local log parsing: Claude Code, Codex CLI and OpenCode.
//!
//! Ported 1:1 from `Sources/BurnRateCore/UsageSources.swift`. No network, no
//! auth — everything comes from the CLIs' own session logs on disk.
//!
//! Three behaviours are load-bearing and easy to lose in a port:
//!   - **Claude `requestId` dedupe.** Claude Code rewrites one request across
//!     several lines and files as it streams, so counting every line over-counts
//!     totals by roughly 2×. One sample per request, keeping the final reading.
//!   - **OpenCode storage migration.** Newer builds write `session_message`
//!     (model nested, tokens at the top level), older ones `message` (flat).
//!     The migration *copied* rows into both, so the same id appears twice.
//!   - **Incremental reads.** Claude's first parse is ~20s over ~560MB, so
//!     unchanged files are skipped and grown files are read from the last byte
//!     offset, with a cache on disk that survives restarts.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::model::{TokenUsage, UsageSample};
use crate::paths::AppPaths;

/// Logs older than this cannot contribute to any tracked window (5hr/7d/30d).
pub const SAMPLE_RETENTION_SECONDS: i64 = 31 * 86_400;

/// Lossy UTF-8 read — a single bad byte must not zero out a whole file, which
/// is what Swift's `String(decoding:as:UTF8.self)` does.
pub fn read_text_file(path: &Path) -> String {
    match std::fs::read(path) {
        Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        Err(_) => String::new(),
    }
}

/// ISO8601 timestamps used by Claude Code and Codex session logs. Both forms
/// occur: with and without fractional seconds.
pub fn parse_log_date(value: &str) -> Option<i64> {
    parse_iso8601(value)
}

/// Minimal ISO8601 parser: `YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]`.
fn parse_iso8601(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let number =
        |range: std::ops::Range<usize>| -> Option<i64> { value.get(range)?.parse::<i64>().ok() };
    if bytes[4] != b'-' || bytes[7] != b'-' || (bytes[10] != b'T' && bytes[10] != b' ') {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let year = number(0..4)?;
    let month = number(5..7)?;
    let day = number(8..10)?;
    let hour = number(11..13)?;
    let minute = number(14..16)?;
    let second = number(17..19)?;

    // Optional fraction.
    let mut index = 19;
    if bytes.get(index) == Some(&b'.') {
        index += 1;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            index += 1;
        }
    }
    // Timezone: Z, or ±HH:MM. A missing zone is treated as UTC, as ISO8601
    // without a designator is conventionally UTC.
    let offset_seconds = match bytes.get(index) {
        None => 0,
        Some(b'Z') | Some(b'z') => 0,
        Some(sign @ (b'+' | b'-')) => {
            let sign = if *sign == b'-' { -1 } else { 1 };
            let hours: i64 = value.get(index + 1..index + 3)?.parse().ok()?;
            let minutes: i64 = value
                .get(index + 4..index + 6)
                .or_else(|| value.get(index + 3..index + 5))
                .and_then(|slice| slice.parse().ok())?;
            sign * (hours * 3600 + minutes * 60)
        }
        _ => 0,
    };

    let days = days_from_civil(year, month, day);
    Some(days * 86_400 + hour * 3600 + minute * 60 + second - offset_seconds)
}

/// Days since the Unix epoch, from a proleptic Gregorian date. Howard Hinnant's
/// `days_from_civil`, which is exact for the whole range and needs no lookup.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

/// Persisted incremental-parse state, keyed by file path.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedFile {
    mtime: i64,
    size: u64,
    samples: Vec<UsageSampleWire>,
}

/// The on-disk shape of a sample. `UsageSample` itself is not `Deserialize`
/// (its timestamp is a bare integer for ergonomics), so the cache carries this.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UsageSampleWire {
    timestamp: i64,
    tokens: TokenUsage,
    request_id: Option<String>,
    model: Option<String>,
    cost: Option<f64>,
    source_tag: Option<String>,
}

impl From<&UsageSample> for UsageSampleWire {
    fn from(sample: &UsageSample) -> Self {
        Self {
            timestamp: sample.timestamp,
            tokens: sample.tokens,
            request_id: sample.request_id.clone(),
            model: sample.model.clone(),
            cost: sample.cost,
            source_tag: sample.source_tag.clone(),
        }
    }
}

impl From<UsageSampleWire> for UsageSample {
    fn from(wire: UsageSampleWire) -> Self {
        Self {
            timestamp: wire.timestamp,
            tokens: wire.tokens,
            request_id: wire.request_id,
            model: wire.model,
            cost: wire.cost,
            source_tag: wire.source_tag,
        }
    }
}

/// Parses `~/.claude/projects/**/*.jsonl`.
pub struct ClaudeUsageSource {
    base: PathBuf,
    cache_url: PathBuf,
}

impl Default for ClaudeUsageSource {
    fn default() -> Self {
        Self::new(None, None)
    }
}

impl ClaudeUsageSource {
    pub fn new(base: Option<PathBuf>, cache_url: Option<PathBuf>) -> Self {
        let paths = AppPaths::detect();
        Self {
            base: base.unwrap_or_else(|| paths.home_directory().join(".claude/projects")),
            cache_url: cache_url.unwrap_or_else(|| paths.app_directory().join("claude-cache.json")),
        }
    }

    /// All usage events in local logs.
    pub fn collect_samples(&self) -> Vec<UsageSample> {
        if !self.base.exists() {
            return Vec::new();
        }
        let mut cache: HashMap<String, CachedFile> = load_cache(&self.cache_url);
        let files = jsonl_files_under(&self.base);
        let cutoff = now_unix() - SAMPLE_RETENTION_SECONDS;
        let mut seen: HashSet<String> = HashSet::new();
        let mut all: Vec<UsageSample> = Vec::new();

        for file in files {
            let key = file.to_string_lossy().into_owned();
            seen.insert(key.clone());
            let (mtime, size) = match file_metadata(&file) {
                Some(meta) => meta,
                None => continue,
            };
            if mtime <= cutoff {
                continue; // cannot affect any window
            }

            let mut samples: Vec<UsageSample> = match cache.get(&key) {
                // Append-only: parse only the new bytes, then re-dedupe — a
                // request's final line can land after the cached offset.
                Some(cached) if size >= cached.size && mtime == cached.mtime => {
                    if size > cached.size {
                        match read_tail(&file, cached.size) {
                            Some(appended) => {
                                let mut combined: Vec<UsageSample> = cached
                                    .samples
                                    .iter()
                                    .map(|wire| wire.clone().into())
                                    .collect();
                                combined.extend(parse_claude_lines(&appended));
                                Self::dedupe(combined)
                            }
                            None => cached.samples.iter().cloned().map(Into::into).collect(),
                        }
                    } else {
                        cached.samples.iter().cloned().map(Into::into).collect()
                    }
                }
                _ => parse_claude_file(&file),
            };

            samples.retain(|sample| sample.timestamp > cutoff);
            cache.insert(
                key,
                CachedFile {
                    mtime,
                    size,
                    samples: samples.iter().map(UsageSampleWire::from).collect(),
                },
            );
            all.extend(samples);
        }

        // Drop entries for files that were deleted or rotated away.
        cache.retain(|key, _| seen.contains(key));
        save_cache(&cache, &self.cache_url);
        // The same requestId can appear in multiple files (resumed/copied
        // sessions): dedupe globally, keeping the latest reading.
        Self::dedupe(all)
    }

    /// Where the logs live, for the diagnostic message.
    pub fn base_directory(&self) -> &Path {
        &self.base
    }

    /// Parses one file, deduped.
    pub fn parse_file(path: &Path) -> Vec<UsageSample> {
        Self::dedupe(parse_claude_lines(&read_text_file(path)))
    }

    /// Keeps the last occurrence per requestId; samples without one pass
    /// through. Claude Code rewrites a request across lines as it streams, so
    /// without this totals are roughly double.
    pub fn dedupe(samples: Vec<UsageSample>) -> Vec<UsageSample> {
        let mut by_request: HashMap<String, usize> = HashMap::new();
        let mut result: Vec<UsageSample> = Vec::new();
        for sample in samples {
            match sample.request_id.as_deref().filter(|id| !id.is_empty()) {
                Some(id) => match by_request.get(id) {
                    Some(index) => result[*index] = sample,
                    None => {
                        by_request.insert(id.to_string(), result.len());
                        result.push(sample);
                    }
                },
                None => result.push(sample),
            }
        }
        result
    }
}

fn load_cache(path: &Path) -> HashMap<String, CachedFile> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(_) => return HashMap::new(),
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn save_cache(cache: &HashMap<String, CachedFile>, path: &Path) {
    if cache.is_empty() {
        return;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(text) = serde_json::to_string(cache) {
        let _ = std::fs::write(path, text);
    }
}

fn file_metadata(path: &Path) -> Option<(i64, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    let mtime = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    Some((mtime, metadata.len()))
}

fn read_tail(path: &Path, offset: u64) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(offset)).ok()?;
    let mut buffer = Vec::new();
    file.read_to_end(&mut buffer).ok()?;
    Some(String::from_utf8_lossy(&buffer).into_owned())
}

/// Recursive `*.jsonl` walk.
pub fn jsonl_files_under(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|ext| ext == "jsonl") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

/// Parses assistant lines out of a Claude Code log.
///
/// Each line: `{"timestamp":"…","type":"assistant","message":{"usage":{…}}}`.
pub fn parse_claude_lines(text: &str) -> Vec<UsageSample> {
    let mut samples = Vec::new();
    for line in text.split('\n') {
        // Cheap prefilter: only JSON lines with a usage block are parsed.
        if !line.contains("\"usage\"") {
            continue;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if value.get("type").and_then(|v| v.as_str()) != Some("assistant") {
            continue;
        }
        let Some(message) = value.get("message") else {
            continue;
        };
        let Some(usage) = message.get("usage") else {
            continue;
        };
        let Some(timestamp) = value
            .get("timestamp")
            .and_then(|v| v.as_str())
            .and_then(parse_log_date)
        else {
            continue;
        };
        // Claude Code writes zero-usage placeholder lines for synthetic
        // (locally generated) turns; they are not a model.
        if message.get("model").and_then(|v| v.as_str()) == Some("<synthetic>") {
            continue;
        }

        let field = |name: &str| usage.get(name).and_then(|v| v.as_i64()).unwrap_or(0);
        samples.push(
            UsageSample::new(
                timestamp,
                TokenUsage::new(
                    field("input_tokens"),
                    field("output_tokens"),
                    field("cache_read_input_tokens"),
                    field("cache_creation_input_tokens"),
                ),
            )
            .maybe_request_id(
                value
                    .get("requestId")
                    .or_else(|| value.get("request_id"))
                    .and_then(|v| v.as_str()),
            )
            .maybe_model(message.get("model").and_then(|v| v.as_str()))
            .maybe_cost(value.get("costUSD").and_then(|v| v.as_f64())),
        );
    }
    samples
}

fn parse_claude_file(path: &Path) -> Vec<UsageSample> {
    ClaudeUsageSource::parse_file(path)
}

// MARK: - Codex CLI (~/.codex/sessions/**/*.jsonl)

/// Sessions emit cumulative `token_count` events; the last event per session
/// file holds that session's total.
pub struct CodexUsageSource {
    base: PathBuf,
}

impl Default for CodexUsageSource {
    fn default() -> Self {
        Self::new(None)
    }
}

impl CodexUsageSource {
    pub fn new(base: Option<PathBuf>) -> Self {
        let paths = AppPaths::detect();
        Self {
            base: base.unwrap_or_else(|| paths.home_directory().join(".codex/sessions")),
        }
    }

    /// Where the logs live, for the diagnostic message.
    pub fn base_directory(&self) -> &Path {
        &self.base
    }

    pub fn collect_samples(&self) -> Vec<UsageSample> {
        if !self.base.exists() {
            return Vec::new();
        }
        jsonl_files_under(&self.base)
            .iter()
            .filter_map(|file| Self::parse_session_file(file))
            .collect()
    }

    /// One sample per file: the last cumulative `total_token_usage` event. The
    /// model comes from the session's `turn_context`/`session_meta` lines.
    pub fn parse_session_file(path: &Path) -> Option<UsageSample> {
        Self::parse_session_text(&read_text_file(path))
    }

    /// The parse itself, separated from I/O so it can be tested directly.
    pub fn parse_session_text(text: &str) -> Option<UsageSample> {
        let mut last: Option<UsageSample> = None;
        let mut model: Option<String> = None;
        for line in text.split('\n') {
            if line.is_empty() {
                continue;
            }
            let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            let payload = value.get("payload");
            if model.is_none() {
                if let Some(model_name) = payload
                    .and_then(|p| p.get("model"))
                    .and_then(|v| v.as_str())
                {
                    model = Some(model_name.to_string());
                }
            }
            if value.get("type").and_then(|v| v.as_str()) != Some("event_msg") {
                continue;
            }
            let Some(payload) = payload else { continue };
            if payload.get("type").and_then(|v| v.as_str()) != Some("token_count") {
                continue;
            }
            let Some(totals) = payload.get("info").and_then(|i| i.get("total_token_usage")) else {
                continue;
            };
            let Some(timestamp) = value
                .get("timestamp")
                .and_then(|v| v.as_str())
                .and_then(parse_log_date)
            else {
                continue;
            };
            let field = |name: &str| totals.get(name).and_then(|v| v.as_i64()).unwrap_or(0);
            last = Some(
                UsageSample::new(
                    timestamp,
                    TokenUsage::with_reasoning(
                        field("input_tokens"),
                        field("output_tokens"),
                        field("cached_input_tokens"),
                        0,
                        field("reasoning_output_tokens"),
                    ),
                )
                .maybe_model(model.as_deref()),
            );
        }
        last
    }
}

// MARK: - OpenCode (~/.local/share/opencode/opencode.db, SQLite + WAL)

/// Queries OpenCode's SQLite database read-only, covering both the current
/// `session_message` table and the legacy `message` one.
pub struct OpenCodeUsageSource {
    provider_id_filter: Option<String>,
    db_candidates: Vec<PathBuf>,
}

impl Default for OpenCodeUsageSource {
    fn default() -> Self {
        Self::new(None, None)
    }
}

impl OpenCodeUsageSource {
    pub fn new(provider_id_filter: Option<String>, db: Option<PathBuf>) -> Self {
        let paths = AppPaths::detect();
        let candidates = vec![
            paths.data_directory().join("opencode").join("opencode.db"),
            paths
                .home_directory()
                .join(".local/share/opencode/opencode.db"),
            paths
                .config_directory()
                .join("opencode")
                .join("opencode.db"),
        ];
        let mut db_candidates = candidates;
        if let Some(explicit) = db {
            db_candidates.push(explicit);
        }
        Self {
            provider_id_filter,
            db_candidates,
        }
    }

    /// Explicit candidate list, for tests and for a caller that knows the
    /// location (a `--data-dir` flag, say) rather than probing.
    pub fn with_candidates(
        provider_id_filter: Option<String>,
        db_candidates: Vec<PathBuf>,
    ) -> Self {
        Self {
            provider_id_filter,
            db_candidates,
        }
    }

    /// Every location the database was looked for, for the diagnostic message.
    pub fn database_candidates(&self) -> &[PathBuf] {
        &self.db_candidates
    }

    /// The database that actually exists, in candidate order.
    pub fn resolve_database(&self) -> Option<PathBuf> {
        self.db_candidates
            .iter()
            .find(|candidate| candidate.exists())
            .cloned()
    }

    pub fn collect_samples(&self) -> Vec<UsageSample> {
        let Some(database) = self.resolve_database() else {
            return Vec::new();
        };
        let cutoff_ms = (now_unix() - SAMPLE_RETENTION_SECONDS) * 1000;
        self.query_samples(&database, cutoff_ms)
    }

    /// `provider_id_filter == None` keeps all providers (model/cost views).
    pub fn query_samples(&self, database: &Path, cutoff_ms: i64) -> Vec<UsageSample> {
        let reader = crate::paths::SqliteReader::new();
        let Ok(tables) = table_names(&reader, database) else {
            return Vec::new();
        };
        let mut samples: Vec<UsageSample> = Vec::new();

        if tables.contains("session_message") {
            let sql = format!(
                "SELECT id, json_extract(data,'$.model.providerID'), data FROM session_message \
                 WHERE time_created > {cutoff_ms} AND type='assistant';"
            );
            if let Ok(output) = reader.query(database, &sql) {
                samples.extend(parse_opencode_rows(
                    &output,
                    self.provider_id_filter.as_deref(),
                    parse_session_message_json,
                ));
            }
        }

        if tables.contains("message") {
            let sql = format!(
                "SELECT id, json_extract(data,'$.providerID'), data FROM message \
                 WHERE time_created > {cutoff_ms} AND json_extract(data,'$.role')='assistant';"
            );
            if let Ok(output) = reader.query(database, &sql) {
                samples.extend(parse_opencode_rows(
                    &output,
                    self.provider_id_filter.as_deref(),
                    parse_message_json,
                ));
            }
        }

        // The storage migration copied rows into `session_message`, so the same
        // message id appears in both tables — dedupe by id.
        let mut seen: HashSet<String> = HashSet::new();
        samples
            .into_iter()
            .filter(
                |sample| match sample.request_id.as_deref().filter(|id| !id.is_empty()) {
                    Some(id) => seen.insert(id.to_string()),
                    None => true,
                },
            )
            .collect()
    }
}

fn table_names(
    reader: &crate::paths::SqliteReader,
    database: &Path,
) -> Result<HashSet<String>, ()> {
    let output = reader
        .query(
            database,
            "SELECT name FROM sqlite_master WHERE type='table';",
        )
        .map_err(|_| ())?;
    Ok(output
        .split('\n')
        .map(|line| line.trim().to_string())
        .filter(|line| !line.is_empty())
        .collect())
}

/// Splits `id \t providerID \t data` rows.
fn parse_opencode_rows(
    output: &str,
    provider_id_filter: Option<&str>,
    parse: fn(&str) -> Option<UsageSample>,
) -> Vec<UsageSample> {
    let mut samples = Vec::new();
    for line in output.split('\n') {
        if line.is_empty() {
            continue;
        }
        let mut columns = line.splitn(3, '\t');
        let (Some(id), Some(provider_id), Some(data)) =
            (columns.next(), columns.next(), columns.next())
        else {
            continue;
        };
        if let Some(filter) = provider_id_filter {
            if provider_id != filter {
                continue;
            }
        }
        let Some(mut sample) = parse(data) else {
            continue;
        };
        sample.request_id = Some(id.to_string());
        samples.push(sample);
    }
    samples
}

/// New `session_message` shape:
/// `{model:{id,providerID}, cost, tokens:{input,output,reasoning,cache:{read,write}}, time:{created: ms}}`
pub fn parse_session_message_json(json: &str) -> Option<UsageSample> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let tokens = value.get("tokens")?;
    let created_ms = value.get("time")?.get("created")?.as_f64()?;
    let cache = tokens.get("cache");
    let model = value.get("model");
    let field = |parent: &serde_json::Value, name: &str| {
        parent.get(name).and_then(|v| v.as_i64()).unwrap_or(0)
    };
    Some(
        UsageSample::new(
            (created_ms / 1000.0) as i64,
            TokenUsage::with_reasoning(
                field(tokens, "input"),
                field(tokens, "output"),
                cache.map(|c| field(c, "read")).unwrap_or(0),
                cache.map(|c| field(c, "write")).unwrap_or(0),
                field(tokens, "reasoning"),
            ),
        )
        .maybe_model(model.and_then(|m| m.get("id")).and_then(|v| v.as_str()))
        .maybe_cost(value.get("cost").and_then(|v| v.as_f64()))
        .maybe_source_tag(
            model
                .and_then(|m| m.get("providerID"))
                .and_then(|v| v.as_str()),
        ),
    )
}

/// Legacy `message.data` shape:
/// `{providerID, modelID, cost, tokens:{...}, time:{created: ms}}`
pub fn parse_message_json(json: &str) -> Option<UsageSample> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let tokens = value.get("tokens")?;
    let created_ms = value.get("time")?.get("created")?.as_f64()?;
    let cache = tokens.get("cache");
    let field = |parent: &serde_json::Value, name: &str| {
        parent.get(name).and_then(|v| v.as_i64()).unwrap_or(0)
    };
    Some(
        UsageSample::new(
            (created_ms / 1000.0) as i64,
            TokenUsage::with_reasoning(
                field(tokens, "input"),
                field(tokens, "output"),
                cache.map(|c| field(c, "read")).unwrap_or(0),
                cache.map(|c| field(c, "write")).unwrap_or(0),
                field(tokens, "reasoning"),
            ),
        )
        .maybe_model(value.get("modelID").and_then(|v| v.as_str()))
        .maybe_cost(value.get("cost").and_then(|v| v.as_f64()))
        .maybe_source_tag(value.get("providerID").and_then(|v| v.as_str())),
    )
}

// MARK: - Aggregation

/// The result of polling every source.
#[derive(Debug, Default, Clone)]
pub struct UsageSnapshot {
    pub batches: Vec<(String, Vec<UsageSample>)>,
    /// One line per source that produced nothing, saying why.
    pub missing: Vec<String>,
}

impl UsageSnapshot {
    /// Polls every source and tags each batch with its provider, recording why
    /// any of them produced nothing. The diagnostics matter: a silent empty
    /// result is indistinguishable from "not logged in".
    pub fn collect_all(
        claude: Option<&ClaudeUsageSource>,
        codex: Option<&CodexUsageSource>,
        opencode: Option<&OpenCodeUsageSource>,
    ) -> Self {
        let mut batches = Vec::new();
        let mut missing = Vec::new();

        if let Some(source) = claude {
            let samples = source.collect_samples();
            if samples.is_empty() {
                missing.push(format!(
                    "Claude: no session logs under {}",
                    source.base_directory().display()
                ));
            }
            batches.push(("Claude".to_string(), samples));
        }
        if let Some(source) = codex {
            let samples = source.collect_samples();
            if samples.is_empty() {
                missing.push(format!(
                    "Codex: no session logs under {}",
                    source.base_directory().display()
                ));
            }
            batches.push(("Codex".to_string(), samples));
        }
        if let Some(source) = opencode {
            let samples = source.collect_samples();
            if samples.is_empty() {
                missing.push(match source.resolve_database() {
                    Some(path) => format!(
                        "OpenCode: {} has no assistant turns in the last 31 days",
                        path.display()
                    ),
                    None => format!(
                        "OpenCode: no database found (looked in {})",
                        source
                            .database_candidates()
                            .iter()
                            .map(|path| path.display().to_string())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                });
            }
            batches.push(("OpenCode Go".to_string(), samples));
        }
        Self { batches, missing }
    }

    /// Every sample, tagged with the provider it came from.
    pub fn labelled(&self) -> Vec<(&str, &UsageSample)> {
        self.batches
            .iter()
            .flat_map(|(provider, samples)| {
                samples
                    .iter()
                    .map(move |sample| (provider.as_str(), sample))
            })
            .collect()
    }

    /// Provider names that actually produced data.
    pub fn providers(&self) -> Vec<String> {
        self.batches
            .iter()
            .filter(|(_, samples)| !samples.is_empty())
            .map(|(provider, _)| provider.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ---- date parsing ----

    #[test]
    fn parses_iso8601_with_and_without_fraction() {
        assert_eq!(parse_log_date("2026-09-29T01:02:03Z"), Some(1_790_643_723));
        assert_eq!(
            parse_log_date("2026-09-29T01:02:03.123Z"),
            Some(1_790_643_723)
        );
        // Offsets are honoured.
        assert_eq!(
            parse_log_date("2026-09-29T03:02:03+02:00"),
            parse_log_date("2026-09-29T01:02:03Z")
        );
        assert_eq!(parse_log_date("not a date"), None);
    }

    // ---- Claude ----

    fn claude_line(request: &str, input: i64, output: i64) -> String {
        format!(
            r#"{{"timestamp":"2026-09-29T01:00:00Z","type":"assistant","requestId":"{request}","message":{{"model":"claude-opus-5","usage":{{"input_tokens":{input},"output_tokens":{output},"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}}}}"#
        )
    }

    /// `parsesClaudeAssistantLine` — the fields the app depends on.
    #[test]
    fn parses_claude_assistant_line() {
        let samples = parse_claude_lines(&claude_line("req-1", 100, 20));
        assert_eq!(samples.len(), 1);
        let sample = &samples[0];
        assert_eq!(sample.tokens.input, 100);
        assert_eq!(sample.tokens.output, 20);
        assert_eq!(sample.model.as_deref(), Some("claude-opus-5"));
        assert_eq!(sample.request_id.as_deref(), Some("req-1"));
        assert_eq!(sample.timestamp, 1_790_643_600);
    }

    /// `skipsSyntheticClaudeTurns` — zero-usage placeholders are not a model.
    #[test]
    fn skips_synthetic_claude_turns() {
        let line = r#"{"timestamp":"2026-09-29T01:00:00Z","type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}"#;
        assert!(parse_claude_lines(line).is_empty());
    }

    /// `ignoresUserLines` — only assistant turns carry usage we count.
    #[test]
    fn ignores_user_lines() {
        let line = r#"{"timestamp":"2026-09-29T01:00:00Z","type":"user","message":{"usage":{"input_tokens":5}}}"#;
        assert!(parse_claude_lines(line).is_empty());
    }

    /// `dedupesRepeatedRequestIdsKeepingLast` — the ~2× over-count fix.
    #[test]
    fn dedupes_repeated_request_ids_keeping_last() {
        let text = [
            claude_line("req-1", 100, 10),
            claude_line("req-1", 100, 90),
            claude_line("req-2", 50, 5),
        ]
        .join("\n");
        let deduped = ClaudeUsageSource::dedupe(parse_claude_lines(&text));
        assert_eq!(deduped.len(), 2, "one sample per request");
        assert_eq!(deduped[0].tokens.output, 90, "the final cumulative reading");
        assert_eq!(deduped[1].tokens.output, 5);
    }

    /// Samples without a request id are never merged away.
    #[test]
    fn dedupe_passes_through_samples_without_a_request_id() {
        let line = r#"{"timestamp":"2026-09-29T01:00:00Z","type":"assistant","message":{"model":"m","usage":{"input_tokens":1}}}"#;
        let parsed = parse_claude_lines(line);
        let deduped = ClaudeUsageSource::dedupe(parsed);
        assert_eq!(deduped.len(), 1);
    }

    /// The incremental cache: a second pass must not double-count, and a
    /// rewritten file must replace rather than append.
    #[test]
    fn incremental_cache_does_not_double_count() {
        let dir = std::env::temp_dir().join(format!("burnrate-claude-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("session.jsonl");
        let cache = dir.join("cache.json");

        std::fs::write(&log, format!("{}\n", claude_line("req-1", 100, 10))).unwrap();
        let source = ClaudeUsageSource::new(Some(dir.clone()), Some(cache.clone()));
        let first = source.collect_samples();
        assert_eq!(first.len(), 1);
        // The same call again — cache hit, still one sample.
        let second = source.collect_samples();
        assert_eq!(second.len(), 1, "cache must not duplicate the request");
        assert!(cache.exists(), "cache file is written for the next launch");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Grown files are read from the last offset, and the dedupe then keeps the
    /// newer final reading for a request already seen.
    #[test]
    fn grown_file_replaces_the_previous_reading() {
        let dir = std::env::temp_dir().join(format!("burnrate-claude-tail-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("session.jsonl");
        let cache = dir.join("cache.json");

        std::fs::write(&log, format!("{}\n", claude_line("req-1", 100, 10))).unwrap();
        let source = ClaudeUsageSource::new(Some(dir.clone()), Some(cache.clone()));
        assert_eq!(source.collect_samples()[0].tokens.output, 10);

        // Append the final cumulative line for the same request.
        let mut text = std::fs::read_to_string(&log).unwrap();
        text.push_str(&format!("{}\n", claude_line("req-1", 100, 77)));
        std::fs::write(&log, &text).unwrap();

        let samples = source.collect_samples();
        assert_eq!(samples.len(), 1, "still one request");
        assert_eq!(samples[0].tokens.output, 77, "the appended final line wins");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- Codex ----

    /// `codexTakesLastCumulativeEvent` — totals are cumulative, so the last
    /// event is the session total, and summing events would multiply it.
    #[test]
    fn codex_takes_last_cumulative_event() {
        let text = concat!(
            r#"{"type":"session_meta","payload":{"model":"gpt-5-codex"}}"#,
            "\n",
            r#"{"type":"event_msg","timestamp":"2026-09-29T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10,"cached_input_tokens":5,"reasoning_output_tokens":2}}}}"#,
            "\n",
            r#"{"type":"event_msg","timestamp":"2026-09-29T02:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"output_tokens":40,"cached_input_tokens":9,"reasoning_output_tokens":4}}}}"#,
            "\n",
        );
        let sample = CodexUsageSource::parse_session_text(text).unwrap();
        assert_eq!(sample.tokens.input, 300, "last cumulative total, not a sum");
        assert_eq!(sample.tokens.output, 40);
        assert_eq!(sample.tokens.cache_read, 9);
        assert_eq!(sample.tokens.reasoning, 4);
        assert_eq!(sample.model.as_deref(), Some("gpt-5-codex"));
        assert_eq!(sample.timestamp, 1_790_647_200);
    }

    #[test]
    fn codex_ignores_files_without_token_events() {
        let text = r#"{"type":"session_meta","payload":{"model":"m"}}"#;
        assert!(CodexUsageSource::parse_session_text(text).is_none());
    }

    // ---- OpenCode ----

    /// `parsesNewOpenCodeSessionMessage` — v2 shape.
    #[test]
    fn parses_new_opencode_session_message() {
        let json = r#"{"model":{"id":"claude-opus-5","providerID":"opencode-go"},"cost":0.42,"tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":10,"write":2}},"time":{"created":1790643600000}}"#;
        let sample = parse_session_message_json(json).unwrap();
        assert_eq!(sample.tokens.input, 100);
        assert_eq!(sample.tokens.cache_read, 10);
        assert_eq!(sample.tokens.cache_write, 2);
        assert_eq!(sample.tokens.reasoning, 5);
        assert_eq!(sample.model.as_deref(), Some("claude-opus-5"));
        assert_eq!(sample.source_tag.as_deref(), Some("opencode-go"));
        assert_eq!(sample.cost, Some(0.42));
        assert_eq!(sample.timestamp, 1_790_643_600);
    }

    /// `parsesOpenCodeMessageJSON` — v1 shape.
    #[test]
    fn parses_legacy_opencode_message() {
        let json = r#"{"providerID":"opencode-go","modelID":"gpt-5","cost":1.5,"tokens":{"input":10,"output":5,"cache":{"read":1,"write":0}},"time":{"created":1790643600000}}"#;
        let sample = parse_message_json(json).unwrap();
        assert_eq!(sample.model.as_deref(), Some("gpt-5"));
        assert_eq!(sample.source_tag.as_deref(), Some("opencode-go"));
        assert_eq!(sample.cost, Some(1.5));
    }

    #[test]
    fn opencode_json_without_tokens_is_skipped() {
        assert!(parse_session_message_json(r#"{"model":{"id":"x"}}"#).is_none());
        assert!(parse_message_json(r#"{"providerID":"x"}"#).is_none());
    }

    /// `parsesNewOpenCodeSQLiteSchema` and `parsesOpenCodeSQLiteSnapshot` —
    /// both tables queried, shared ids deduped.
    #[test]
    fn opencode_reads_both_tables_and_dedupes_shared_ids() {
        let dir = std::env::temp_dir().join(format!("burncode-sqlite-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("opencode.db");
        {
            use rusqlite::Connection;
            let connection = Connection::open(&db).unwrap();
            connection
                .execute_batch(
                    "CREATE TABLE session_message (id TEXT PRIMARY KEY, data TEXT, time_created INTEGER, type TEXT);
                     CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT, time_created INTEGER);",
                )
                .unwrap();
            let v2 = r#"{"model":{"id":"m2","providerID":"opencode-go"},"cost":0.1,"tokens":{"input":10,"output":2,"cache":{"read":0,"write":0}},"time":{"created":1790643600000}}"#;
            let v1 = r#"{"providerID":"opencode-go","modelID":"m1","cost":0.2,"tokens":{"input":20,"output":4,"cache":{"read":0,"write":0}},"time":{"created":1790643600000}}"#;
            // "dup" is the row the migration copied into both tables.
            connection
                .execute(
                    "INSERT INTO session_message VALUES ('a1', ?1, 1790643600000, 'assistant')",
                    [v2],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO message VALUES ('dup', ?1, 1790643600000)",
                    [v1],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO session_message VALUES ('dup', ?1, 1790643600000, 'assistant')",
                    [v2],
                )
                .unwrap();
        }

        let source = OpenCodeUsageSource::new(None, Some(db.clone()));
        let samples = source.query_samples(&db, 0);
        let ids: Vec<&str> = samples
            .iter()
            .filter_map(|s| s.request_id.as_deref())
            .collect();
        assert_eq!(samples.len(), 2, "three rows, one id duplicated");
        assert_eq!(ids.iter().filter(|id| **id == "dup").count(), 1);
        // The v2 row wins because it is read first.
        let dup = samples
            .iter()
            .find(|s| s.request_id.as_deref() == Some("dup"))
            .unwrap();
        assert_eq!(dup.model.as_deref(), Some("m2"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `providerFilterAppliesWithinRange` — filtering by provider id.
    #[test]
    fn opencode_provider_filter_applies() {
        let rows = "a1\topencode-go\t{\"tokens\":{\"input\":1},\"time\":{\"created\":1}}\n\
                    a2\tollama\t{\"tokens\":{\"input\":2},\"time\":{\"created\":1}}\n";
        let all = parse_opencode_rows(rows, None, parse_session_message_json);
        assert_eq!(all.len(), 2);
        let filtered = parse_opencode_rows(rows, Some("ollama"), parse_session_message_json);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].request_id.as_deref(), Some("a2"));
    }

    #[test]
    fn opencode_missing_database_yields_nothing() {
        let source =
            OpenCodeUsageSource::with_candidates(None, vec!["/nonexistent/opencode.db".into()]);
        assert!(source.collect_samples().is_empty());
        assert!(source.resolve_database().is_none());
    }
}
