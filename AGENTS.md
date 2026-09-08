# AGENTS.md

## Project

**BurnRate** — macOS native menu-bar app that tracks AI plan usage for OpenCode Go, Anthropic Claude, and OpenAI Codex plans. Swift + SwiftUI, Swift Package Manager only (no Xcode project file). Minimum target: macOS 15 Sequoia.

## Build & test

- `swift build` from repo root.
- `scripts/test.sh` to run tests. Plain `swift test` fails on this machine: only
  Command Line Tools installed (no Xcode), so the Swift Testing framework needs
  manual `-F`/`-rpath` flags, which the script supplies. Tests use `import Testing`
  (not XCTest — also unavailable without Xcode).
- Run the app: `swift run` — menu-bar status item appears; `Cmd+C` to stop.
- Swift 6 strict concurrency is on: UI-touching classes are `@MainActor`.
- No codegen, migrations, or lint config yet; add commands here as tooling lands.

## Product invariants (do not break)

- Menu bar icon always present; app runs in the background. No dock window as primary UI.
- Settings UI opens from the dropdown menu on the menu-bar icon click, not a separate flow.
- Dropdown shows % remaining for 5hr, weekly, and monthly limits (or provider-equivalent windows) for each provider.
- Desktop notifications fire at user-configurable usage milestones (configured in settings).
- App can spawn additional menu-bar widgets showing per-plan usage %. Keep status-item code modular: one manager capable of multiple `NSStatusItem` instances.

## Architecture notes

- Two data layers per provider, in priority order:
  1. **Vendor quota APIs (authoritative %, resets, no calibration)** — reuse the
     credentials the CLIs already stored at login; no auth flow of our own.
     - Claude: `GET api.anthropic.com/api/oauth/usage`, Bearer token from
       `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) or, when
       absent, macOS Keychain `security find-generic-password -s
       "Claude Code-credentials" -w` (same JSON shape). Parse the `limits`
       array (session / weekly_all / weekly_scoped — scoped entries carry
       `scope.model.display_name`, e.g. Fable) and fall back to the flat
       `five_hour`/`seven_day` keys on older shapes. Values are percent USED.
       Rate-limits aggressively: min 60s between calls, 300s backoff on error,
       reuse last snapshot.
     - OpenCode Go: `GET opencode.ai/zen/go/v1/usage`, Bearer key from
       `~/.local/share/opencode/auth.json` (`opencode-go.key`). Returns
       rolling/weekly/monthly `percent` (used) + `resetsAt`. Plan shown as "Go".
     - Zen credit balance: NO public endpoint yet (feature request
       anomalyco/opencode#10448, assigned). Deliberately not implemented —
       do not scrape the web console. Check the issue, then add a
       `zen/v1/balance` call to `OpenCodeGoUsageAPIProvider` when it ships.
     - Codex: same pattern, `~/.codex/auth.json` — not implemented yet.
  2. **Local log parsing (tokens/cost, fallback)** — see below.
- Local parsing (no network): Claude `~/.claude/projects/**/*.jsonl` (append-only,
  incremental byte-offset cache, skip files older than 31 days); Codex
  `~/.codex/sessions/**/*.jsonl` (last cumulative `token_count` event per file);
  OpenCode legacy `~/.local/share/opencode/opencode.db` (SQLite+WAL, query
  read-only via `/usr/bin/sqlite3` with `time_created` filter — never copy the
  DB; drain the output pipe before `waitUntilExit()` or it deadlocks).
- Sources/providers are actors (`protocol UsageSource: Actor`,
  `protocol UsageProvider: Actor`); parsing runs off the main thread. First
  Claude parse is ~20s (~560MB), later polls ~ms.
- Local parsing needs user-configured capacities (`SettingsStore.planCapacities`,
  weighted tokens: cache read ×0.1, write ×1.25) to show %; without one it shows
  tokens only. Claude data counts cache reads, so raw token capacity guessing
  never matches the vendor % — prefer the quota API.
- Usage polling continues while the app is backgrounded; milestone thresholds
  and burn-rate alerts are evaluated on each poll.
- Burn-rate alerts (`BurnAlert`): notify when a window's remaining % drops
  ≥ N within a trailing M-minute window. History kept per window id (6h
  retention), baseline = oldest in-window reading, 30-min cooldown per window
  after firing. Detection is pure (`BurnRateEvaluator`, tested).
- Per-model usage: `UsageSample` carries `model` + `cost` (cost only from
  OpenCode; Claude logs have costUSD null). `ModelUsageAggregator` buckets
  into per-day per-model totals; the Models window (Charts) reads a snapshot
  persisted to UserDefaults (`modelUsageHistory`) and refreshed each poll.
  OpenCode local source accepts `providerIDFilter: nil` (all providers).
- Extra alerts: `CostAlert` (daily USD spend from local logs, OpenCode only)
  and `ModelBurnAlert` (model tokens over trailing minutes, wildcard `*`
  model allowed) — both in the notifier with once-per-day / cooldown logic.
