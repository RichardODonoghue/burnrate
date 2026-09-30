# AGENTS.md

## Project

**BurnRate** — menu-bar app that tracks AI plan usage for OpenCode Go, Anthropic
Claude and OpenAI Codex. **Rust + Tauri v2**, one UI codebase for macOS, Linux
and Windows.

It was a Swift app until Sep 2026. It was rewritten because the Swift
cross-platform packaging failed in practice — the Windows download was 250 MB of
bundled Swift runtime, the hand-rolled Linux GTK4 tray was ugly and fragile, and
Windows would not boot. The Swift app and its three workflows were deleted at the
cutover; `crates/burnrate-core`'s module comments still name the Swift file each
module was ported from, which is provenance, not a live reference.

## Layout

- `crates/burnrate-core/` — pure Rust, no Tauri or UI dependencies. All logic and
  the tests that matter. Modules: `model`, `usage`, `providers` (vendor quota
  APIs), `sources` (local log parsing), `alerts`, `notifier`, `charts`, `menu`,
  `settings`, `paths`, `pricing` (in `model`), `formatting`, `icon`, `dial`,
  `migration`, `poller`.
- `src-tauri/` — the Tauri layer: tray, windows, commands, settings plumbing
  (`lib.rs`), macOS notifications (`notifications.rs`), the Swift-history import
  (`swift_import.rs`).
- `ui/` — the frontend.
- `crates/icon-gen/` — renders the icons from `burnrate_core::dial`.

Keep new shared logic in `burnrate-core` with a `pub` API and tests; do not reach
for `tauri` there.

### The frontend is TypeScript emitted as native ES modules — no bundler

The webview resolves the imports itself, which is why `tsconfig` uses
`module`/`moduleResolution: NodeNext`: it *enforces* the `.js` extension in
relative imports at compile time, and `bundler` would let `./dom` through and the
browser would 404 on it. `ui/package.json`'s only devDependency is `typescript`;
the point of this shape is that npm's dependency tree is one package rather than
the several hundred a bundler plus a framework pulls in.

- `ui/app/src/*.ts` → `ui/app/js/*.js` (gitignored). `ui/app/index.html` loads
  `./js/main.js` as a module; `frontendDist` is `../ui/app`.
- `ui/tests/harness.mjs` loads the **emitted** modules against a stubbed DOM and
  IPC and asserts the markup. Run `npm run build` first. It replaced a DOM stub
  that loaded the old JavaScript with `eval`, which could not see a script that
  failed to load at all.
- `main.ts` is the only module with load-time side effects, so the harness can
  import everything else without booting the app.
- Panes are leaves: they import `store`/`dom`/`ui`/`charts` and never the shell.
  The shell passes them a `PaneContext` (`reload`, `selectWindow`) rather than the
  modules importing each other in a cycle.
- **The wire is camelCase.** `ProviderUsage` is
  `#[serde(rename_all = "camelCase")]`, so it is `providerName`, not
  `provider_name`. Reading the snake_case name finds nothing, and inside a lookup
  with a fallback that failure is *silent* — it has been wrong three times, once
  in `src` and twice in test fixtures. Tests pin the wire keys
  (`model.rs::provider_usage_wire_keys_are_camel_case`); use real wire keys in
  fixtures.

### `tsc` must run before `cargo build`/`cargo test`

`tauri::generate_context!` embeds `frontendDist` at compile time, so a build
without the emitted frontend succeeds and ships a window that renders nothing.
`tauri.conf.json` sets `beforeBuildCommand`/`beforeDevCommand`; CI builds the
frontend before every job that compiles the app; and `src-tauri/src/lib.rs` has a
test that `include_str!`s the emitted entry point, so a missing build is a
compile error rather than a blank window. A fresh clone therefore needs
`npm ci && npm run build` in `ui/` before `cargo test`.

## Build, run and test

- `cargo build --workspace`, `cargo test --workspace`,
  `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --all`.
- Frontend, all from `ui/`: `npm ci`, `npm run build`, `npm run typecheck`,
  `npm test`.
- `scripts/tauri-smoke.sh` — Docker; the runtime tray check (registration, DBusMenu
  service, in-place menu text mutation, click dispatch). It builds the frontend on
  the host first because the container has no node.
- **Run the app with `tauri dev`.** Do not also launch
  `target/debug/bundle/macos/BurnRate.app/Contents/MacOS/burnrate-desktop`: both
  write the same `target/debug/` binary, and the second instance gives you two
  menu-bar icons, two pollers hitting the vendor quota APIs, and two writers to
  `settings.json` and the history files. Likewise `pkill -f burnrate-desktop`
  kills a running `tauri dev` — the app disappears and the CLI sits waiting.
- There is no `devUrl` and no `beforeDevCommand`, so `tauri dev` serves `ui/app` as
  a static directory: a change under `ui/app/` needs a webview reload (or a dev
  restart) and does **not** rebuild Rust, while a change under `src-tauri/` or
  `crates/` rebuilds and restarts on its own. Devtools are available, and the
  app's `eprintln!` diagnostics (`pricing table N entries`,
  `trend history N sample(s), M day(s) of model history, K notifier window(s)`,
  `N widget(s)`, `poll #N providers, …`) print to the terminal — that output is
  the fastest signal when something looks wrong.
- Icons are generated from one source of truth, never hand-drawn:
  `cargo run -p icon-gen` renders the flame+dial geometry in `burnrate_core::dial`
  into `src-tauri/icons/` (the PNG set, `.icns`, `.ico`). The tray mark is *not*
  one of those files — the runtime draws it from the same geometry and hands
  Tauri raw RGBA, because a file would be a second copy to keep in step. Change
  the mark in `dial.rs`, re-run, and every platform follows.
  - **Every icon path `tauri.conf.json` declares must be one the generator
    writes.** The Windows taskbar icon was a stale `32x32.png`: the config asked
    for it, `icon-gen` had since renamed its output, and the file left on disk was
    an older icon with square corners and no inset, which showed up as a broken
    border. A test now compares each declared PNG against a fresh render, because
    "the file exists" is not the same as "the file is current".
  - **The tray mark's colour is per-platform.** macOS gets black and hands the
    image over as a *template*, which the system tints for the menu bar; Windows
    and Linux show the pixels as drawn, so they get white. An invisible tray icon
    is exactly the kind of bug macOS cannot show you, which is why the ink is
    chosen at the call site in `tray_image` and pinned by a test.

## Contributing — PRs only (mandatory)

All changes go through a pull request. Do not commit or push directly to `main`.

- Branch from `main` (e.g. `fix/…`, `feat/…`), commit there, push, open a PR.
- CI must go green before merge.
- Prefer squash/rebase merges; keep PRs focused on one change.
- Conventional commits (`feat:`, `fix:`, `docs:` …) — release-please parses them
  to version and tag releases.
- Exception: nothing. Release-please's own `chore(main): release X.Y.Z` PR is the
  only automated path to `main`.

## Release and versioning

- **One version**, in `[workspace.package]` of the root `Cargo.toml`. It drives the
  bundle (`CFBundleShortVersionString`, `package_info().version`) *and*
  `burnrate_core::VERSION`, so the two numbers About shows cannot disagree.
  `src-tauri/tauri.conf.json` deliberately sets **no** `version`: that field
  overrides the crate version, and the two silently drifted to `1.0.0` while the
  newest release was `0.8.0`. A test fails if the field returns.
- release-please bumps it (`extra-files`, `jsonpath: $.workspace.package.version`),
  so a release PR moves the app version alongside the changelog and the tag. The
  toml updater leaves `Cargo.lock` stale for the local crates; cargo rewrites it on
  the next build and nothing here builds `--locked`.
- **A commit release-please cannot parse is dropped silently** — no changelog
  entry, no version contribution. It happened to the cutover: the squash commit
  was skipped entirely and the release came out as a patch, because the message
  contained `.set_icon(` — release-please reads `(` as the start of a PR reference
  and wants a `)` before the line ends, and it aborts the whole commit on a
  newline instead. The only trace is `commit could not be parsed` in the Action
  log. **Squash commits concatenate every message on the branch**, so one stray
  unbalanced bracket anywhere in a branch's history invalidates the release
  commit. Keep brackets balanced in commit and PR bodies, and after a release
  check that your change is actually in the changelog.
- Manually tagged releases also work (`release.yml` accepts a tag by
  `workflow_dispatch`), but release-please's manifest must be updated by hand to
  match, or the next release PR computes from the wrong version.
- **A commit type release-please does not know is dropped from the changelog with
  no error.** The same silence as an unparseable message, and the reason
  `changelog-sections` in `release-please-config.json` lists every type in use —
  including `sec` for security work. Adding a new type to a commit means adding
  it there too, or the entry never appears.
- `.github/workflows/ci.yml` — the only CI: frontend + `fmt`/`clippy`/`test`, a
  build-and-bundle matrix (macOS `app`, Linux `deb,rpm`, Windows `nsis`), a
  `cargo audit` job, and the Linux tray smoke. Audit *warnings* do not fail the
  build on purpose — two are upstream's to fix, and a permanently red job gets
  ignored. It exits non-zero on advisories that actually affect us.
- `.github/workflows/release.yml` — per-OS bundles: macOS `BurnRate-<ver>-arm64.zip`
  + `.dmg`, Linux `.deb` + `.rpm` + `.AppImage`, Windows `-x64-setup.exe`, then one
  job attaching them all with a combined `SHA256SUMS`. It has a `dry_run` dispatch
  input that builds every platform without touching a release — use it to check
  packaging changes. macOS checks that the bundle version equals the tag. The rpm
  target needs `rpmbuild` (`apt-get install rpm`); without it the bundler fails
  rather than skipping the target.
- **In-app updates** (`burnrate_core::updater` + `src-tauri/src/updater.rs`,
  ported from `Updater.swift`): the app asks GitHub for `releases/latest`, and on
  macOS it downloads the arm64 zip, verifies it against the release's own
  `SHA256SUMS`, unpacks it, **validates** it (bundle id, version,
  `codesign --verify --deep`), swaps the running bundle and relaunches. An
  unverifiable release is refused, not warned about. Checked at launch and daily;
  the tray row becomes `Update to X…` and a click installs it.
  - This is why `release.yml` publishes `SHA256SUMS` over every asset, and why it
    must keep doing so: **a release whose sums do not list the arm64 zip cannot be
    installed in place.** Changing the published asset names therefore breaks
    updates for existing installs, because they look for the name they know.
  - macOS only, as in Swift. Elsewhere the update is reported and the release page
    is opened. Doing it properly on Linux means the Tauri updater plugin, which
    needs a signing keypair and a hosted `latest.json` — and it only updates
    AppImages, so a `.deb`/`.rpm` install would still be manual.
  - `cargo test -p burnrate-desktop -- --ignored real_release` exercises the whole
    chain against the real published release. Run it after a release: it is the
    only check that the *shipped* artifact passes the validation an install
    performs.
  - **Asset URLs are pinned to GitHub's hosts**, so a manipulated API response
    cannot point the download elsewhere. Defence in depth: the checksum is still
    the load-bearing check.
  - **There is no signature, and that is the one real gap.** The anchor is HTTPS
    to GitHub plus the release's own `SHA256SUMS`; `codesign --verify` on an
    *ad-hoc* signature proves internal consistency, not authorship, so a
    compromised GitHub account or release could ship a malicious update. Closing
    it needs either a Developer ID with `notarytool` credentials as secrets and an
    entitlements file, or the Tauri updater plugin's keypair plus a hosted
    `latest.json`. Both are credentials, not code.
  - **Nothing installs from a single click.** The tray's `Update to X…` row opens
    the About pane, where the version is shown and the Install button is the
    confirmation.
- **Nothing is signed or notarised.** macOS is ad-hoc signed
  (`bundle.macOS.signingIdentity: "-"`), so Gatekeeper quarantines a downloaded
  copy; the README documents the two ways past that. Adding notarisation means a
  Developer ID, `notarytool` credentials as secrets, and an entitlements file.

## Product invariants (do not break)

- Menu-bar icon always present; the app runs in the background. No dock window as
  the primary UI.
- Windows are opened from the tray menu, not a separate launcher flow. The Usage
  Dashboard window carries the charts *and* the settings panes in its sidebar.
- Tray menu shows % remaining per window per provider, with the plan tier in the
  provider header (`Claude - Max 20x`).
- Desktop notifications fire at user-configurable usage milestones.
- The app can spawn additional menu-bar widgets, one per plan. Keep the tray code
  modular: one manager capable of multiple items.
- Polling continues while the app is backgrounded; milestone and burn-rate rules
  are evaluated on every poll.

## Providers and data layers

Two layers per provider, in priority order.

1. **Vendor quota APIs** — authoritative %, resets, no calibration. Reuses the
   credentials the CLIs already stored at login; no auth flow of our own.
   - **Claude**: `GET api.anthropic.com/api/oauth/usage`, Bearer token from
     `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) or, when absent,
     the macOS Keychain (`security find-generic-password -s
     "Claude Code-credentials" -w`, same JSON shape). **Both the token and the plan
     tier go through one `read_credential_oauth`** (file, then Keychain) —
     reading the file alone returned no plan on a Keychain-only install, which is
     the common case. Parse the `limits` array (session / weekly_all /
     weekly_scoped — scoped entries carry `scope.model.display_name`, e.g. Fable)
     and fall back to the flat `five_hour`/`seven_day` keys on older shapes.
     Values are percent **used**. Rate-limits aggressively: min 60s between calls,
     300s backoff on error, reuse the last snapshot.
   - **Plan tier**: `format_plan` maps the subscription type through a fixed table
     (`max`→`Max`, `team`→`Team`, `pro`→`Pro`, `enterprise`→`Enterprise`,
     otherwise verbatim) and takes the multiplier as the `\d+x` **suffix** of
     `rateLimitTier`, so `default_claude_max_20x` → `Max 20x`. It is not string
     concatenation.
   - **OpenCode Go**: `GET opencode.ai/zen/go/v1/usage`, Bearer key from either
     OpenCode version — v1 `auth.json` (`{"opencode-go":{"key":…}}`) or v2
     `account.json` (`{"version":2,"accounts":{…serviceID:"opencode-go"…
     credential.key}}`), searched under `$XDG_DATA_HOME`, `~/.local/share` and
     `$XDG_CONFIG_HOME`; v2's DB `credential` table
     (`integration_id='opencode-go'`) is a fallback. Returns rolling/weekly/monthly
     `percent` (used) + `resetsAt`. Plan shown as "Go".
   - **Zen credit balance**: no public endpoint yet (feature request
     anomalyco/opencode#10448, assigned). Deliberately not implemented — do not
     scrape the web console. Check the issue, then add a `zen/v1/balance` call to
     `OpenCodeGoApiProvider` when it ships.
   - **Codex**: same pattern, `~/.codex/auth.json` — not implemented yet.
2. **Local log parsing** (tokens/cost, fallback) — below.

## Local log parsing (no network)

- **Claude** `~/.claude/projects/**/*.jsonl` — append-only, incremental
  byte-offset cache, skip files untouched for 31 days, lossy UTF-8 reads, and
  **requestId dedupe**: Claude Code rewrites the same request across lines and
  files, so each requestId counts once with its final cumulative usage. Without
  it, totals over-count ~2×.
- **Codex** `~/.codex/sessions/**/*.jsonl` — last cumulative `token_count` event
  per file.
- **OpenCode** `~/.local/share/opencode/opencode.db` — SQLite+WAL, opened
  **read-only** with `rusqlite` (bundled) and a `busy_timeout`, because the CLI is
  actively writing it. Never copy the DB. (The Swift build shelled out to
  `/usr/bin/sqlite3` and had to drain the pipe before `waitUntilExit()` or it
  deadlocked; `rusqlite` removes that class of bug.) Storage was migrated
  upstream: newer turns live in `session_message` (`model:{id,providerID}`,
  `cost`, `tokens`, `type='assistant'`) while older ones are in `message` (flat
  `providerID`/`modelID`); the parser detects which tables exist, reads both, and
  dedupes by row id (the migration copied ids into both tables).
- Local parsing needs **capacities** (weighted tokens: cache read ×0.1, write
  ×1.25) to show %. Capacities are predetermined, keyed
  `provider|windowLabel` with labels Rolling/Weekly/Monthly; there is no UI to
  edit them. Claude data counts cache reads, so a raw token-capacity guess never
  matches the vendor %, which is why the quota API is preferred.

## Notifications and alerts

- The notifier (`burnrate-core::notifier`) decides; delivery is platform-specific.
  macOS posts through `UNUserNotificationCenter` (`src-tauri/src/notifications.rs`)
  — the Tauri plugin's path builds an `NSUserNotification`, which is deprecated and
  inert on modern macOS, so a terminal-launched app shows nothing. Everywhere else
  uses `tauri-plugin-notification`.
- **State persists** (`notifier-state.json`): the account fingerprint, every
  window's last reading and reset time, and the days a spend cap already fired.
  Restoring the baseline is what makes the saved fingerprint load-bearing —
  without both, a switch that happens while the app is closed is invisible,
  because the first poll has nothing to compare against.
- **Milestones** fire on a crossing of a user-configured step.
- **Window reset**: two signals. Primary — the vendor moved the window's reset time
  *forward*, so a fresh window began, however much remaining moved (an old window
  can end above 90% after hours of idle). Fallback — a ≥40-point jump, for sources
  that report no reset time. The old 5-point threshold was not equivalent: a quiet
  window gains 5 points from cache expiry alone.
- **Burn-rate** (`BurnAlert`): notify when a window's remaining drops ≥ N within a
  trailing M-minute window. Per-window history with 6h retention, baseline = oldest
  in-window reading, 30-min cooldown per window after firing. Detection is pure
  (`BurnRateEvaluator`, tested). Note `detect` requires the window to actually
  *span* its minutes, so a 30-minute rule needs ~28 minutes of history.
- **Daily cost** (`CostAlert`): once-per-day USD spend from local logs. Model-burn
  alerts were removed as noise — the per-model charts cover that ground.

## Platform specifics that cost time once

Linux:

- Tauri reaches the tray through **libayatana-appindicator**, so items live at
  `/org/ayatana/NotificationItem/<id with non-alnum → _>` and the menu at
  `<item>/Menu` (`com.canonical.dbusmenu`). There is **no** `/StatusNotifierItem`
  object, unlike the old hand-rolled tray.
- A watcher reports items by **unique bus name** (`:1.2`), not by the
  `org.kde.StatusNotifierItem-<pid>-<n>` well-known name the old tray used.
- A tray menu, once set, **cannot be replaced** — only edited. The real menu is
  built once and its items' text is rewritten every poll; row ids are namespaced by
  generation because the old menu's ids may still be registered.
- `TrayIconBuilder::title` lands in the `XAyatanaLabel` property, not `Title`.
- **Do not use `PredefinedMenuItem::quit`.** On Linux it reports itself disabled
  through DBusMenu, so the row is greyed out and never dispatches and the app
  cannot be quit from its own menu. Use a plain `MenuItem` — this is also why every
  usage row is created `enabled: true` (a disabled item is greyed out on macOS too,
  which is what the usage figures were) and the click is ignored in
  `on_menu_event` instead.
- WebKitGTK in a container needs `WEBKIT_DISABLE_COMPOSITING_MODE=1` and
  `WEBKIT_DISABLE_DMABUF_RENDERER=1`; `scripts/tauri-smoke.sh` sets them.
- **`scripts/tauri-smoke.sh` must build into a container-local
  `CARGO_TARGET_DIR`.** A `target/` shared between the host (macOS) and the
  container (Linux) corrupts the proc-macro artifacts and the build dies with
  `E0463: can't find crate` for every dependency of `tauri-build` and `gtk`.
- Tray ids are `"tray-icon tray app <id>"` with non-alphanumerics replaced by `_`,
  so a widget for "Claude" is at
  `/org/ayatana/NotificationItem/tray_icon_tray_app_widget_Claude`.

macOS:

- `is_dev()` is `!cfg!(feature = "custom-protocol")`. Dev builds attribute
  notifications to the launching terminal; bundles do not.
- The bundle id is **`com.burnrate.desktop`** (was `com.burnrate.app` until Sep
  2026, and `com.burnrate.desktop.tauri` during the rewrite). Notification Centre
  and iconservices cache the **banner icon per bundle id**, and the old id had a
  blank icon cached that no icns change or cache clearing could dislodge — so do
  not change the id casually. Notification permission and any UserDefaults are
  keyed on it, which is why the Tauri app took the Swift app's id at cutover.

## Migrating from the Swift app

The Swift app kept its history in `UserDefaults` under `com.burnrate.desktop`:
`remainingHistory` (7 days of 5-minute polls) and `modelUsageHistory` (30 days of
per-model daily buckets). `src-tauri/src/swift_import.rs` reads them once with
`defaults export <domain> -` then `plutil -extract … raw`, and
`burnrate-core::migration` parses them. Both dates are **seconds since
2001-01-01**, not the Unix epoch — read without the offset, every sample lands 31
years in the past, the retention filter drops the lot, and the migration reports
success while importing nothing. That failure is silent, so it is worth being
loud about.

The import is skipped if either history file already exists, so it runs exactly
once and cannot overwrite live data.

## Deliberate divergences from the Swift app

These were decisions, not omissions. Do not "restore" them without asking.

- **No `Charts…` or `Settings…` tray rows.** The Usage Dashboard window carries
  both the charts and the settings panes, so those rows opened the same window a
  second time. (`StatusMenuBuilder` still models them and takes an
  `includes_charts` flag, but `src-tauri` filters every `Action` out of the row
  plan and builds its own rows — see the follow-up list; it is dead.)
- **Per-provider failure reasons are logged, not surfaced.** The Usage pane lists
  providers that were not detected; each provider's `lastStatus` detail (missing
  credential path, HTTP code) goes to the terminal instead.
- **Claude is not offered a Monthly window** in the milestone or burn-rule
  pickers. Its quota has no monthly window, so the options come from the
  provider's own reported windows (Claude: Rolling/Weekly/Fable; OpenCode Go:
  Rolling/Weekly/Monthly). A hardcoded list survives only as a fallback for a
  provider that has not been detected yet, and it drops Monthly for Claude there
  too. Swift's own `windowLabels(for:)` *does* offer Monthly for Claude,
  contradicting its own usage pane.
- **The app-icon pose is amber**, the pose the shipped icns was drawn at, via
  `dial::SHIPPED_ICON_POSE_REMAINING`. The Swift renderer passed `nil`, which its
  severity ramp read as 70% and painted green.
- **The current day's bar is not faded** in the daily chart. A part-day-opacity
  experiment read as a wrong bar rather than an incomplete one and was removed.

## Known follow-ups

- `StatusMenuAction` (and `StatusMenuEntry::Action`) is **dead code**: the builder
  creates `Charts…`/`Settings…`/`Quit` entries and `src-tauri`'s `row_plan`
  discards every `Action`, then `build_menu` constructs those rows itself. Two
  sources of truth for one menu.
- `crates/burnrate-core/src/alerts.rs`'s doc comments and others name deleted
  Swift files. Kept as provenance; delete the naming if you prefer.
- Zen credit balance (blocked on upstream) and the Codex quota API.
