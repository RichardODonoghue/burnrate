// The About pane, laid out as the Swift `AboutView`: the shipped bundle icon over
// the name and version, then Updates, What it does, Data sources, Links — each row
// a `Label(text, systemImage:)` equivalent.

import { api } from "../api.js";
import { esc, el, must, on, onAll, targetData, toast } from "../dom.js";
import { rowIcon, type IconName } from "../icons.js";
import { ISSUES_URL, RELEASES_URL, REPO_SLUG, REPO_URL } from "../ui.js";
import { state } from "../store.js";
import type { Snapshot } from "../types.js";
import type { PaneContext } from "./usage.js";

/** One `Label(text, systemImage:)` row, as the Swift cards are built from. */
function labelled(icon: IconName, text: string): string {
  return `<div class="about-row">${rowIcon(icon)}<span>${esc(text)}</span></div>`;
}

export function render(snapshot: Snapshot): string {
  const { appVersion, coreVersion, platforms } = snapshot;
  const { updateAvailable, updateState, updateBusy, canInstallUpdate } = snapshot;
  // Both buttons are disabled while a check or download is in flight, so a
  // second click cannot start a second download.
  const busyAttrs = updateBusy ? " disabled" : "";
  const deps = platforms.runtimeDependencies;

  return `<h1>About</h1>
    <p class="sub">BurnRate — AI plan usage in the menu bar.</p>

    <div class="card hero">
      <img id="about-icon" alt="" width="72" height="72" />
      <strong>BurnRate</strong>
      <span class="hint">Version ${esc(appVersion)}</span>
    </div>

    <div class="card">
      <h2>Updates</h2>
      <div class="row">
        <span class="grow label">Version ${esc(appVersion)}</span>
        ${
          updateAvailable && canInstallUpdate
            ? `<button class="action primary" id="install-update"${busyAttrs}>Install ${esc(
                updateAvailable
              )}</button>`
            : ""
        }
        <button class="action" id="check-updates"${busyAttrs}>Check for Updates</button>
      </div>
      <p class="hint" id="update-state">${esc(updateState)}</p>
      ${
        canInstallUpdate
          ? ""
          : `<p class="hint">This platform installs from the
             <a href="#" data-open="${esc(RELEASES_URL)}">releases page</a>.</p>`
      }
    </div>

    <div class="card">
      <h2>What it does</h2>
      ${labelled(
        "gauge",
        "Menu bar: per-provider % remaining, reset countdown and plan tier — no Dock icon"
      )}
      ${labelled(
        "usage",
        "Usage dashboard: remaining-% trends, daily usage by model, model ranking and token/cost breakdowns"
      )}
      ${labelled(
        "bell",
        "Notifications: plan-% milestones, burn-rate spikes, daily cost caps and window resets"
      )}
      ${labelled("widgets", "Optional extra menu-bar widgets, one per provider")}
      ${labelled("download", "Built-in updates from GitHub Releases")}
    </div>

    <div class="card">
      <h2>Data sources</h2>
      ${labelled(
        "seal",
        "Vendor quota APIs — Claude and OpenCode Go percentages, reset times and plan tier, using the credentials their CLIs already stored"
      )}
      ${labelled(
        "drive",
        "Local session logs — Codex usage, plus per-model token statistics and cost estimates (LiteLLM list pricing). Nothing is sent anywhere"
      )}
    </div>

    <div class="card">
      <h2>Links</h2>
      <div class="about-row">
        ${rowIcon("github")}
        <a href="#" data-open="${REPO_URL}">github.com/${REPO_SLUG}</a>
      </div>
      <div class="about-row">
        ${rowIcon("bubble")}
        <a href="#" data-open="${ISSUES_URL}">Report an issue or request a feature</a>
      </div>
    </div>

    <div class="card">
      <h2>Build</h2>
      <div class="row"><span class="grow label">Core</span><span class="value">${esc(
        coreVersion
      )}</span></div>
      <div class="row"><span class="grow label">Platform</span><span class="value">${esc(
        platforms.os
      )}</span></div>
      ${
        deps.length
          ? `<div class="row"><span class="grow label">Runtime deps</span><span class="value">${deps
              .map(esc)
              .join(", ")}</span></div>`
          : ""
      }
      <div class="row">
        <span class="grow label">Notifications</span>
        <button class="action" id="test-notification">Send a test</button>
      </div>
      <div class="row">
        <span class="grow label">Settings file</span>
        <span class="value mono small">${esc(state.settingsPath)}</span>
      </div>
    </div>`;
}

export function wire(_snapshot: Snapshot, context: PaneContext): void {
  // The hero icon is the pane's marker: if it is absent this pane is not up, and
  // everything below it can be required rather than looked up loosely.
  if (!el("about-icon")) return;

  // The shipped bundle icon, as the Swift AboutView uses it — not the live
  // severity-tinted renderer.
  void api.appIconDataUrl(144).then((url) => {
    must<HTMLImageElement>("about-icon").src = url;
  });

  const content = must("content");
  onAll(content, "[data-open]", "click", async (event) => {
    event.preventDefault();
    const url = targetData(event).open;
    if (url) await api.openUrl(url);
  });

  // Checking and installing both own their state in Rust, so the pane re-renders
  // from a fresh snapshot rather than patching itself by hand.
  on(must("check-updates"), "click", async () => {
    const button = must<HTMLButtonElement>("check-updates");
    button.disabled = true;
    button.textContent = "Checking…";
    try {
      const status = await api.checkForUpdates();
      toast(status.state);
    } catch (error) {
      toast(`Could not check for updates: ${String(error)}`);
    }
    context.reload();
  });

  const install = el("install-update");
  if (install) {
    on(install, "click", async () => {
      const button = must<HTMLButtonElement>("install-update");
      button.disabled = true;
      button.textContent = "Downloading…";
      try {
        // On success the app replaces itself and exits, so this never resolves.
        await api.installUpdate();
      } catch (error) {
        toast(`Update failed: ${String(error)}`);
        context.reload();
      }
    });
  }

  on(must("test-notification"), "click", async () => {
    // The command reports what the platform actually did, including the caveat
    // that a dev build's banner is attributed elsewhere.
    toast(await api.testNotification());
  });
}
