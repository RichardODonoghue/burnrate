// The Notifications pane: milestone, burn-rate and daily-spend rules, plus the
// window-reset toggle. Mirrors the Swift `MilestonesView`.

import { api } from "../api.js";
import {
  esc,
  el,
  must,
  on,
  onAll,
  splitKey,
  targetChecked,
  targetData,
  targetValue,
} from "../dom.js";
import { mutate, providerColour, state, windowOptions } from "../store.js";
import type { Snapshot } from "../types.js";
import type { PaneContext } from "./usage.js";

export function render(snapshot: Snapshot): string {
  const { settings } = snapshot;
  const providers = state.providers;

  const milestones = settings.milestones
    .map(
      (rule) => `<div class="row">
        <span class="dot" style="background:${providerColour(rule.provider)}"></span>
        <span class="grow">${esc(rule.provider)} · ${esc(rule.windowLabel)}</span>
        <input type="number" data-step="${esc(rule.provider)}|${esc(rule.windowLabel)}"
               min="1" max="50" value="${rule.step}" />
        <span class="label">% step</span>
        <button class="link" data-rm-milestone="${esc(rule.provider)}|${esc(
          rule.windowLabel
        )}">Remove</button>
      </div>`
    )
    .join("");

  const burns = settings.burnAlerts
    .map(
      (rule) => `<div class="row">
        <span class="grow">${esc(rule.provider)} · ${esc(rule.windowLabel)}</span>
        <input type="number" data-drop="${esc(rule.provider)}|${esc(rule.windowLabel)}"
               min="1" max="100" value="${rule.percentDrop}" />
        <span class="label">% drop in</span>
        <input type="number" data-minutes="${esc(rule.provider)}|${esc(rule.windowLabel)}"
               min="1" max="720" value="${rule.minutes}" />
        <span class="label">min</span>
        <button class="link" data-rm-burn="${esc(rule.provider)}|${esc(
          rule.windowLabel
        )}">Remove</button>
      </div>`
    )
    .join("");

  const costs = settings.costAlerts
    .map(
      (rule) => `<div class="row">
        <span class="grow">${esc(rule.provider)}</span>
        <span class="label">over</span>
        <input type="number" data-cost="${esc(rule.provider)}" min="0" step="1"
               value="${rule.dailyLimitUsd}" />
        <span class="label">USD/day</span>
      </div>`
    )
    .join("");

  const providerSelect = (id: string): string =>
    `<select id="${id}">${providers.map((p) => `<option>${esc(p)}</option>`).join("")}</select>`;

  return `<h1>Notifications</h1>
    <p class="sub">Milestones fire each time a window drops past another increment.
    One rule per provider and window. Duplicates are collapsed on save.</p>

    <div class="card">
      <h2>Milestones</h2>
      ${milestones || `<p class="hint">No milestone rules.</p>`}
      <div class="row">
        ${providerSelect("ms-provider")}
        <select id="ms-window">${windowOptions(providers[0] ?? "")}</select>
        <input type="number" id="ms-step" min="1" max="50" value="20" />
        <span class="label">% step</span>
        <button class="action" id="ms-add">Add or replace</button>
      </div>
    </div>

    <div class="card">
      <h2>Burn rate</h2>
      ${burns || `<p class="hint">No burn-rate alerts.</p>`}
      <div class="row">
        ${providerSelect("bn-provider")}
        <select id="bn-window">${windowOptions(providers[0] ?? "")}</select>
        <input type="number" id="bn-drop" min="1" max="100" value="15" />
        <span class="label">% in</span>
        <input type="number" id="bn-minutes" min="1" max="720" value="30" />
        <span class="label">min</span>
        <button class="action" id="bn-add">Add or replace</button>
      </div>
    </div>

    <div class="card">
      <h2>Daily spend</h2>
      ${
        costs ||
        `<p class="hint">No spend caps. Claude's cost is a list-price estimate; OpenCode's is reported.</p>`
      }
      <div class="row">
        ${providerSelect("co-provider")}
        <input type="number" id="co-limit" min="0" step="1" value="20" />
        <span class="label">USD/day</span>
        <button class="action" id="co-save">Save cap</button>
      </div>
    </div>

    <div class="card">
      <h2>Window resets</h2>
      <label class="switch">
        <input type="checkbox" id="notify-reset" ${settings.notifyOnReset ? "checked" : ""} />
        <span>Notify when a window resets (remaining jumps back up)</span>
      </label>
    </div>`;
}

export function wire(snapshot: Snapshot, context: PaneContext): void {
  // The "add milestone" button is this pane's marker: absent means it is not up,
  // and every element below is then required.
  if (!el("ms-add")) return;

  // The window list depends on the provider, so it is rebuilt when the provider
  // changes rather than on a refresh.
  const providerWindows = (providerId: string, windowId: string): void => {
    const provider = el<HTMLSelectElement>(providerId);
    const windows = el<HTMLSelectElement>(windowId);
    if (!provider || !windows) return;
    on(provider, "change", () => {
      windows.innerHTML = windowOptions(provider.value);
    });
  };
  providerWindows("ms-provider", "ms-window");
  providerWindows("bn-provider", "bn-window");

  on(must("ms-add"), "click", async () => {
    await mutate(
      () =>
        api.upsertMilestone(
          mustSelect("ms-provider").value,
          mustSelect("ms-window").value,
          Number(mustInput("ms-step").value)
        ),
      "Milestone saved"
    );
    context.reload();
  });

  on(must("bn-add"), "click", async () => {
    await mutate(
      () =>
        api.upsertBurnAlert(
          mustSelect("bn-provider").value,
          mustSelect("bn-window").value,
          Number(mustInput("bn-drop").value),
          Number(mustInput("bn-minutes").value)
        ),
      "Burn-rate alert saved"
    );
    context.reload();
  });

  on(must("co-save"), "click", async () => {
    await mutate(
      () => api.upsertCostAlert(mustSelect("co-provider").value, Number(mustInput("co-limit").value)),
      "Spend cap saved"
    );
    context.reload();
  });

  const resetToggle = must<HTMLInputElement>("notify-reset");
  on(resetToggle, "change", async (event) => {
    const enabled = targetChecked(event);
    await mutate(
      () => api.setNotifyOnReset(enabled),
      enabled ? "Reset notifications on" : "Reset notifications off"
    );
    context.reload();
  });

  const content = must("content");

  onAll(content, "[data-rm-milestone]", "click", async (event) => {
    const [provider, windowLabel] = splitKey(targetData(event).rmMilestone ?? "");
    await mutate(() => api.removeMilestone(provider, windowLabel), "Milestone removed");
    context.reload();
  });

  onAll(content, "[data-rm-burn]", "click", async (event) => {
    const [provider, windowLabel] = splitKey(targetData(event).rmBurn ?? "");
    await mutate(() => api.removeBurnAlert(provider, windowLabel), "Burn-rate alert removed");
    context.reload();
  });

  // Editing a step in place.
  onAll(content, "[data-step]", "change", async (event) => {
    const [provider, windowLabel] = splitKey(targetData(event).step ?? "");
    await mutate(
      () => api.upsertMilestone(provider, windowLabel, Number(targetValue(event))),
      "Milestone saved"
    );
    context.reload();
  });

  onAll(content, "[data-drop],[data-minutes]", "change", async (event) => {
    const data = targetData(event);
    const key = data.drop ?? data.minutes ?? "";
    const [provider, windowLabel] = splitKey(key);
    const existing = snapshot.settings.burnAlerts.find(
      (rule) => rule.provider === provider && rule.windowLabel === windowLabel
    );
    // Either box can be the one that moved, so the other keeps its current value.
    const drop = el<HTMLInputElement>(`[data-drop="${key}"]`);
    const minutes = el<HTMLInputElement>(`[data-minutes="${key}"]`);
    await mutate(
      () =>
        api.upsertBurnAlert(
          provider,
          windowLabel,
          Number(drop?.value ?? existing?.percentDrop ?? 15),
          Number(minutes?.value ?? existing?.minutes ?? 30)
        ),
      "Burn-rate alert saved"
    );
    context.reload();
  });

  onAll(content, "[data-cost]", "change", async (event) => {
    await mutate(
      () =>
        api.upsertCostAlert(targetData(event).cost ?? "", Number(targetValue(event))),
      "Spend cap saved"
    );
    context.reload();
  });
}

const mustSelect = (id: string): HTMLSelectElement => must<HTMLSelectElement>(id);
const mustInput = (id: string): HTMLInputElement => must<HTMLInputElement>(id);
