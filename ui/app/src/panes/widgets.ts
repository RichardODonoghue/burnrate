// The Widgets pane: one menu-bar item per enabled provider.
//
// Only providers the app has *detected* are listed. A configured provider whose
// CLI is not installed used to get an entry here — and, worse, a menu-bar item
// that could never show a figure.

import { api } from "../api.js";
import { esc, el, onAll, targetChecked, targetData } from "../dom.js";
import { mutate, providerColour, state } from "../store.js";
import type { Snapshot } from "../types.js";
import type { PaneContext } from "./usage.js";

export function render(snapshot: Snapshot): string {
  const { settings } = snapshot;
  const rows = state.providers
    .map((provider) => {
      const on = settings.widgetProviders.includes(provider);
      return `<div class="row">
        <span class="dot" style="background:${providerColour(provider)}"></span>
        <span class="grow">${esc(provider)}</span>
        <label class="switch">
          <input type="checkbox" data-widget="${esc(provider)}" ${on ? "checked" : ""} />
          <span>${on ? "Shown in the menu bar" : "Hidden"}</span>
        </label>
      </div>`;
    })
    .join("");

  return `<h1>Widgets</h1>
    <p class="sub">Each enabled provider gets its own menu-bar item showing that
    plan's percent, with a menu to remove it again.</p>
    <div class="card">
      <h2>Per-plan items</h2>
      ${
        rows ||
        `<p class="hint">No providers are active. Log in to a supported CLI to see it here.</p>`
      }
    </div>`;
}

export function wire(_snapshot: Snapshot, context: PaneContext): void {
  const content = el("content");
  if (!content) return;
  onAll(content, "[data-widget]", "change", async (event) => {
    const provider = targetData(event).widget ?? "";
    if (!targetChecked(event)) {
      // Nothing to do beyond the write; the label is refreshed by the reload.
    }
    await mutate(() => api.toggleWidget(provider), "Widget updated");
    context.reload();
  });
}
