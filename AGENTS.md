# AGENTS.md

## Tauri rewrite (branch `rewrite/tauri`) — read this first on that branch

The Swift app is being **rewritten in Rust + Tauri v2** because cross-platform
Swift packaging failed in practice: the Windows download was 250 MB of bundled
Swift runtime, the hand-rolled Linux GTK4 tray was ugly and fragile, and
Windows would not boot. Tauri gives one UI codebase, a real tray library and
~6 MB artifacts.

- **Integration branch is `rewrite/tauri`, not `main`.** Every PR targets
  `rewrite/tauri`; `main` keeps the working Swift app until parity is proven.
  Cutover = one PR from `rewrite/tauri` into `main`.
- Layout: `crates/burnrate-core/` (pure Rust, no Tauri/UI deps, all logic and
  tests), `src-tauri/` (tray, windows, commands, settings), `ui/app/`
  (frontend, hand-written for now — Vite comes with the dashboard and will emit
  into `ui/app/`; note the repo ignores any directory named `dist`, so the
  frontend path deliberately is not called `dist`).
- The Swift `BurnRateCore` tests (111) are the parity spec: port them 1:1 and
  tick them off in `PARITY.md`. Do not "improve" behaviour while porting.
- Linux specifics that cost us time once, recorded so they are not re-learned:
  - Tauri reaches the tray through **libayatana-appindicator**, so items live
    at `/org/ayatana/NotificationItem/<id with non-alnum → _>` and the menu at
    `<item>/Menu` (`com.canonical.dbusmenu`). There is **no**
    `/StatusNotifierItem` object, unlike the old hand-rolled tray.
  - A watcher reports items by **unique bus name** (`:1.2`), not by the
    `org.kde.StatusNotifierItem-<pid>-<n>` well-known name the old tray used.
  - A tray menu, once set, **cannot be replaced** — only edited. The real menu
    is therefore built once and its items' text is rewritten every poll.
  - `TrayIconBuilder::title` lands in the `XAyatanaLabel` property, not `Title`.
  - WebKitGTK in a container needs `WEBKIT_DISABLE_COMPOSITING_MODE=1` and
    `WEBKIT_DISABLE_DMABUF_RENDERER=1`; `scripts/tauri-smoke.sh` sets them.
  - **`scripts/tauri-smoke.sh` must build into a container-local
    `CARGO_TARGET_DIR`.** A `target/` shared between the host (macOS) and the
    container (Linux) corrupts the proc-macro artifacts and the build dies with
    `E0463: can't find crate` for every dependency of `tauri-build` and `gtk`.
  - **Do not use `PredefinedMenuItem::quit`.** On Linux it reports itself
    disabled through DBusMenu, so the row is greyed out and never dispatches —
    the app cannot be quit from its own menu. Use a plain `MenuItem`.
  - Tray ids are `"tray-icon tray app <id>"` with non-alphanumerics replaced by
    `_`, so a widget for "Claude" is at
    `/org/ayatana/NotificationItem/tray_icon_tray_app_widget_Claude`.
- Commands: `cargo build --workspace`, `cargo test --workspace`, `cargo clippy
  --workspace --all-targets -- -D warnings`, `cargo fmt --all`, and
  `scripts/tauri-smoke.sh` (Docker; the Gate 0 tray check).
- Icons are generated from one source of truth, never hand-drawn:
  `cargo run -p icon-gen` renders the G2 flame+dial geometry in
  `burnrate_core::dial` into `src-tauri/icons/` (PNG set, `.icns`, `.ico`,
  `tray.png`, and `tray.rgba`, which the runtime embeds because Tauri takes raw
  RGBA). Change the mark in `dial.rs`, re-run, and every platform follows.
- CI for this work is `.github/workflows/tauri.yml` (core/build matrix/tray
  smoke), triggered only for `rewrite/tauri` and PRs targeting it.

## Contributing — PRs only (mandatory)

All changes from now on must go through a pull request. Do not commit or push
directly to `main`.

- Branch from `main` (e.g. `fix/…`, `feat/…`), commit there, push the branch,
  and open a PR.
- CI must go green before merge.
- Prefer squash/rebase merges; keep PRs focused on one change.
- Commit messages follow conventional commits (`feat:`, `fix:`, `docs:` …) —
  release-please parses them to version and tag releases.
- Exception: nothing. Release-please's own "chore(main): release X.Y.Z" PR is
  the only automated path to `main`.

## Project

**BurnRate** — macOS native menu-bar app that tracks AI plan usage for OpenCode Go, Anthropic Claude, and OpenAI Codex plans. Swift + SwiftUI, Swift Package Manager only (no Xcode project file). Minimum target: macOS 15 Sequoia.

## Build & test

- `swift build` from repo root.
- `scripts/test.sh` to run tests. Plain `swift test` fails on this machine: only
  Command Line Tools installed (no Xcode), so the Swift Testing framework needs
  manual `-F`/`-rpath` flags, which the script supplies. Tests use `import Testing`
  (not XCTest — also unavailable without Xcode).
- Run the app: `swift run` — menu-bar status item appears; `Cmd+C` to stop.
- **Linux app:** `swift build --product BurnRate` on Linux (GTK4 via `libgtk-4-dev`).
  `scripts/linux-smoke.sh` builds and smoke-runs it in an Ubuntu container under
  Xvfb (window + tray registration/menu/click + widget tray; requires Docker). The
  tray is a hand-rolled StatusNotifierItem + DBusMenu over GIO in `CBurnRateTray`
  (not libayatana-appindicator — that is GTK3 and cannot share a process with
  GTK4); multiple tray items are supported (main + per-provider widgets).
  Linux alerts go through `notify-send` (thread-safe `LinuxNotifier`; milestone,
  reset, burn-rate and daily-cost rules), settings persist as JSON
  (`LinuxSettings`) and are edited from a GTK settings window (widget toggles,
  reset notifications, milestone step spinning). The updater opens the releases
  page.
  Package with `scripts/make_linux_app.sh` (tarball + `.deb` + `.desktop` + install
  script); it **bundles the Swift runtime libraries** (not a distro package) and
  sets an rpath of `$ORIGIN/../lib/BurnRate`, so the binary runs on distros
  without a Swift toolchain. The install script checks `ldd` and reports missing
  system libs (GTK4) with per-distro install commands. The Linux app logs and
  shows which providers were not detected and why (missing credential paths,
  HTTP failures). The **Charts…** menu item
  opens a Cairo-rendered window
  (remaining-% trend lines + top-model ranking bars + daily stacked usage) fed
  from `TrendChartData`/`ModelUsage`, and the dashboard text lists per-model
  totals. CI compiles the target; `scripts/linux-smoke.sh` verifies runtime. The
  macOS app target and the Linux target are declared per-OS in `Package.swift`;
  `BurnRateCore` builds on both.
- Swift 6 strict concurrency is on: UI-touching classes are `@MainActor`.
- **Windows app:** `swift build --product BurnRate` on Windows (CI uses the
  Swift 6.1.2 toolchain on `windows-2022`; it also runs the core tests). The UI
  is a Win32 C shim (`CBurnRateWin32`: window + message loop, `Shell_NotifyIcon`
  tray with per-provider widgets, balloon notifications, GDI charts, settings
  dialog); `BurnRateCore` builds on Windows too. Settings persist as JSON
  (`WindowsSettings`). Package with `scripts/make_windows_app.ps1` (zip + Swift
  runtime DLLs). It is **compile-verified only** — no Windows machine was
  available to run it.
- No codegen, migrations, or lint config yet; add commands here as tooling lands.

## Bundle ID

- `com.burnrate.desktop` (was `com.burnrate.app` until Sep 2026).
- Notification Center / iconservices cache the **banner icon per bundle ID**;
  the old ID had a blank icon cached that no icns change or cache clearing
  could dislodge. Fresh ID fixed it. Don't change the ID casually —
  notification permission and all UserDefaults (settings, history, notifier
  state) are keyed on it.
- AppDelegate runs a one-time defaults migration from the legacy
  `com.burnrate.app` domain (guarded by the `migratedLegacyBundleID` flag).

## Product invariants (do not break)

- Menu bar icon always present; app runs in the background. No dock window as primary UI.
- Settings UI opens from the dropdown menu on the menu-bar icon click, not a separate flow.
- Dropdown shows % remaining for 5hr, weekly, and monthly limits (or provider-equivalent windows) for each provider.
- Desktop notifications fire at user-configurable usage milestones (configured in settings).
- App can spawn additional menu-bar widgets showing per-plan usage %. Keep status-item code modular: one manager capable of multiple `NSStatusItem` instances.

## Architecture notes

- **Targets:** `BurnRateCore` is platform-independent: models/aggregation,
  `Pricing`, `Alerts`/evaluators, `ProviderThrottle`/`QuotaCache`, `ChartData`,
  `StatusMenu`, `IconSpec`, and the runtime (providers `ClaudeUsageAPI` /
  `OpenCodeGoUsageAPI`, log sources `UsageSources`, `MilestoneNotifier`).
  `BurnRate` is the macOS app (AppKit/SwiftUI/Combine/UserNotifications). Keep
  new shared logic in `BurnRateCore` with `public` API; do not import Apple-only
  frameworks there. `BurnRateCore` is the first step toward a Linux/Windows port
  (plan kept outside the repo).
- **Platform seams** live in `BurnRateCore/Platform.swift` (`AppPaths`,
  `CredentialReading`, `SQLiteQuerying`) and `BurnRateCore/Presentation.swift`
  (`NotificationPresenting`, `SystemEventObserving`, `AppUpdating`); macOS
  implementations are in `PlatformMacOS.swift`/`PresentationMacOS.swift`. The tray
  is modelled in `BurnRateCore/StatusMenu.swift` (`StatusMenuBuilder` +
  `StatusItemPresenting`); `StatusItemManager` is the macOS renderer and owns no
  app state. Add new OS integrations as a protocol in core plus one implementation
  per platform, rather than calling AppKit/`Process` paths inline.
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
     - OpenCode Go: `GET opencode.ai/zen/go/v1/usage`, Bearer key from either
       OpenCode version — v1 `auth.json` (`{"opencode-go":{"key":…}}`) or v2
       `account.json` (`{"version":2,"accounts":{…serviceID:"opencode-go"…
       credential.key}}`), searched under `$XDG_DATA_HOME`, `~/.local/share`
       and `$XDG_CONFIG_HOME`; v2's DB `credential` table
       (`integration_id='opencode-go'`) is a fallback. Returns
       rolling/weekly/monthly `percent` (used) + `resetsAt`. Plan shown as "Go".
     - Zen credit balance: NO public endpoint yet (feature request
       anomalyco/opencode#10448, assigned). Deliberately not implemented —
       do not scrape the web console. Check the issue, then add a
       `zen/v1/balance` call to `OpenCodeGoUsageAPIProvider` when it ships.
     - Codex: same pattern, `~/.codex/auth.json` — not implemented yet.
  2. **Local log parsing (tokens/cost, fallback)** — see below.
- Local parsing (no network): Claude `~/.claude/projects/**/*.jsonl` (append-only,
  incremental byte-offset cache, skip files untouched for 31 days, lossy UTF-8
  reads, **requestId dedupe** — Claude Code rewrites the same request across
  lines/files, so each requestId counts once with its final cumulative usage;
  without this, totals over-count ~2x); Codex
  `~/.codex/sessions/**/*.jsonl` (last cumulative `token_count` event per file);
  OpenCode `~/.local/share/opencode/opencode.db` (SQLite+WAL, query read-only
  via `/usr/bin/sqlite3` with `time_created` filter — never copy the DB; drain
  the output pipe before `waitUntilExit()` or it deadlocks). OpenCode migrated
  storage: newer turns live in `session_message` (`model:{id,providerID}`,
  `cost`, `tokens`, `type='assistant'`) while older ones are in `message`
  (flat `providerID`/`modelID`); the parser detects which tables exist, reads
  both, and dedupes by row id (the migration copied ids into both tables).
- Sources/providers are actors (`protocol UsageSource: Actor`,
  `protocol UsageProvider: Actor`); parsing runs off the main thread. First
  Claude parse is ~20s (~560MB), later polls ~ms.
- Local parsing needs capacities (`SettingsStore.planCapacities`, weighted
  tokens: cache read ×0.1, write ×1.25) to show %; without one it shows tokens
  only. Capacities are **predetermined** (`SettingsStore.defaultCapacities`,
  keyed `provider|windowLabel` with labels Rolling/Weekly/Monthly) — there is no
  UI to edit them and persisted calibration values are ignored. Claude data
  counts cache reads, so raw token capacity guessing never matches the vendor %
  — prefer the quota API.
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
  in the notifier with once-per-day logic. Model-burn alerts were removed as
  noise — the dashboard's per-model charts cover that ground.
