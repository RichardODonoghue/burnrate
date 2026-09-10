# BurnRate

Track your AI plan subscriptions from the macOS menu bar — **Anthropic Claude**, **OpenCode Go**, and **OpenAI Codex**.

Live % remaining and reset times for every usage window (5-hour, weekly, monthly, model-scoped like Fable), read straight from each vendor's own quota API using the credentials their CLIs already stored on your machine. Nothing to configure, no API keys to paste, no telemetry — everything stays local.

## Features

- **Menu bar dropdown** — per-provider usage: % remaining, reset times, plan tier (e.g. "Team 5x")
- **Vendor-authoritative data** — the same numbers the vendors' own dashboards show
- **Usage by model** — dashboard with daily stacked bars, model ranking, input/output/cache breakdowns and remaining-% trend lines (Swift Charts)
- **Milestone notifications** — desktop alerts when a window drops below a threshold you choose
- **Burn-rate alerts** — detect usage spikes (fast % drops, per-model token surges)
- **Cost alerts** — daily spend caps (OpenCode reports vendor cost; others use LiteLLM list-price estimates)
- **Reset notifications** — know when a window refills to 100%
- **Extra menu-bar widgets** — spawn an additional status item per provider
- **Background operation** — lives in the menu bar, no Dock icon, polls every 5 minutes

Cost figures are list-price estimates (LiteLLM pricing table) where vendors don't report spend — the standard ccusage/tokscale convention.

## Build

Requires macOS 15+ and Swift 6 (Command Line Tools are sufficient).
Targets **Apple Silicon only** (arm64).

```sh
swift build                      # debug build
scripts/test.sh                  # run tests
swift run                        # run the menu-bar app
scripts/make_app.sh [version]    # build dist/BurnRate.app (arm64-only)
```

## Install

Grab `BurnRate-<version>-arm64.zip` (or the `.dmg`) from the
[latest release](https://github.com/RichardODonoghue/burnrate/releases/latest).
Drag `BurnRate.app` to `/Applications` (the DMG includes an Applications
link) and launch it — the menu-bar flame appears.

The bundle is ad-hoc signed, so Gatekeeper warns on first launch:
right-click → **Open**, then Open again. Clearing quarantine also works:
`xattr -dr com.apple.quarantine /Applications/BurnRate.app`.

## Releases

Versions are managed by [release-please](https://github.com/googleapis/release-please):
commit with conventional-commit messages (`feat:`, `fix:` …), and it opens a
"chore(main): release X.Y.Z" PR on `main`. Merging that PR tags the version,
which builds an arm64 `.zip` + `.dmg` and publishes the GitHub Release
automatically. Version = the git tag; `scripts/make_app.sh` stamps it into
the bundle's `CFBundleShortVersionString`.

## How it works

BurnRate reads two kinds of data, no auth flows of its own:

1. **Vendor quota APIs** — for usage % and reset times, reusing the OAuth tokens / API keys that `claude`, `codex`, and `opencode` already saved when you logged in (macOS Keychain or dotfiles). Claude's plan tier (e.g. "Team 5x") comes from the same credential.
2. **Local session logs** — for token statistics, parsed from `~/.claude/projects/`, `~/.codex/sessions/`, and OpenCode's SQLite store.

> **Note:** the quota endpoints are undocumented vendor APIs. They work today but may change or go away without notice.

Providers only appear if they're set up on your machine — no credentials, no entry.

## License

GPL-2.0 — see [LICENSE](LICENSE).
