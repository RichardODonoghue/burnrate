# BurnRate

Track your AI plan subscriptions from the menu bar — **Anthropic Claude**,
**OpenCode Go**, and **OpenAI Codex**. macOS, Linux and Windows, one Rust + Tauri
application.

Live % remaining and reset times for every usage window (5-hour, weekly, monthly,
model-scoped like Fable). Claude and OpenCode Go are read straight from each
vendor's own quota API using the credentials their CLIs already stored on your
machine; Codex is measured from its local session logs against a built-in
capacity. Nothing to configure, no API keys to paste, no telemetry — everything
stays local.

## Features

- **Menu bar dropdown** — per-provider usage: % remaining, reset times, plan tier
  (e.g. "Max 20x")
- **Vendor-authoritative data** — the same numbers the vendors' own dashboards show
- **Usage by model** — dashboard with daily stacked bars, model ranking,
  input/output/cache breakdowns and remaining-% trend lines
- **Milestone notifications** — desktop alerts each time a window drops past
  another increment you choose (every 10%, 20%…)
- **Burn-rate alerts** — detect usage spikes (fast % drops within a trailing window)
- **Cost alerts** — daily spend caps (OpenCode reports vendor cost; others use
  LiteLLM list-price estimates)
- **Reset notifications** — know when a window refills to 100%
- **Extra menu-bar widgets** — spawn an additional status item per plan
- **Background operation** — lives in the menu bar, no Dock icon, polls every
  5 minutes
- **Self-updating** — checks GitHub Releases at launch and daily; on macOS it
  verifies the download against the release's published checksum and installs it
  in place

Cost figures are list-price estimates (LiteLLM pricing table) where vendors don't
report spend — the standard ccusage/tokscale convention.

## Install

Grab the file for your platform from the
[latest release](https://github.com/RichardODonoghue/burnrate/releases/latest):

| Platform | File | Install |
| --- | --- | --- |
| macOS (Apple Silicon) | `BurnRate-<version>-arm64.dmg` or `-arm64.zip` | Drag `BurnRate.app` to `/Applications`, then see below |
| Linux, Debian/Ubuntu | `BurnRate-<version>-amd64.deb` | `sudo apt install ./BurnRate-<version>-amd64.deb` |
| Linux, Fedora/RHEL | `BurnRate-<version>-x86_64.rpm` | `sudo dnf install ./BurnRate-<version>-x86_64.rpm` |
| Linux, any | `BurnRate-<version>-amd64.AppImage` | `chmod +x` it and run |
| Windows (x64) | `BurnRate-<version>-x64-setup.exe` | Installs the WebView2 runtime if it is missing |

The `.deb` and `.rpm` declare their own dependencies and bring them in. The
AppImage does not, so it needs WebKitGTK 4.1 and an appindicator present:

- Debian/Ubuntu: `libwebkit2gtk-4.1-0 libayatana-appindicator3-1`
- Fedora/RHEL: `webkit2gtk4.1 libayatana-appindicator-gtk3`

The menu-bar icon needs a tray host — on plain GNOME, install an AppIndicator
extension, or the app runs with no visible icon.

**macOS: the app is not signed or notarised**, so Gatekeeper quarantines a
downloaded copy and calls it damaged. Either right-click → **Open**, then Open
again, or clear the flag:

```sh
xattr -dr com.apple.quarantine /Applications/BurnRate.app
```

Upgrading from the old Swift build? Your history is imported automatically on
first launch.

On macOS, **BurnRate updates itself**: when a newer release exists the menu-bar
menu offers `Update to <version>…`, which downloads it, verifies it against the
release's own `SHA256SUMS`, replaces the app and relaunches. On Linux and Windows
the menu offers the release page instead, so upgrades there stay manual.

## Build

Requires a Rust toolchain, Node 22, and the Tauri CLI
(`cargo install tauri-cli --version "^2"`, or use `npx @tauri-apps/cli`).

```sh
cd ui && npm ci          # frontend dependencies (typescript, and nothing else)
npm run build            # tsc → ui/app/js (the webview loads these directly)

tauri dev                # run the app
cargo test --workspace   # the tests that matter
cargo run -p icon-gen    # regenerate src-tauri/icons from burnrate_core::dial
scripts/tauri-smoke.sh   # Linux tray check in a container (needs Docker)
```

`tsc` must run before `cargo build`: `tauri::generate_context!` embeds the
frontend at compile time, and without it the build succeeds and ships a window
that renders nothing.

On Linux, install the build dependencies first:

```sh
sudo apt-get install libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
  librsvg2-dev libxdo-dev libssl-dev
```

## Releases

Versions are managed by [release-please](https://github.com/googleapis/release-please):
commit with conventional-commit messages (`feat:`, `fix:` …) and it opens a
`chore(main): release X.Y.Z` PR on `main`. Merging that tags the version and
builds every platform's bundles onto the GitHub Release.

The version lives in **one** place — `[workspace.package] version` in
`Cargo.toml`. It drives the bundle's version and `burnrate_core::VERSION`, so the
two never disagree.

## How it works

BurnRate reads two kinds of data, with no auth flows of its own:

1. **Vendor quota APIs** — for usage % and reset times, reusing the OAuth tokens /
   API keys that `claude` and `opencode` already saved when you logged in (macOS
   Keychain or dotfiles). Claude's plan tier (e.g. "Max 20x") comes from the same
   credential.
2. **Local session logs** — for token statistics, parsed from `~/.claude/projects/`,
   `~/.codex/sessions/`, and OpenCode's SQLite store. Codex has no quota API here,
   so its % is computed from these logs against a built-in capacity (weighted
   tokens: cache reads count 10%, writes 125%).

> **Note:** the quota endpoints are undocumented vendor APIs. They work today but
> may change or go away without notice.

Providers only appear if they're set up on your machine — no credentials, no entry.

## License

GPL-2.0 — see [LICENSE](LICENSE).
