// The window shell: sidebar, toolbar, pane routing and the wiring that connects
// them. Owns rendering; the panes only produce markup and attach their own
// handlers.

import { api } from "./api.js";
import { esc, el, on, onAll, targetData, toast } from "./dom.js";
import { paneIcon } from "./icons.js";
import { segmented } from "./ui.js";
import { refresh, state } from "./store.js";
import * as about from "./panes/about.js";
import * as notifications from "./panes/notifications.js";
import * as usage from "./panes/usage.js";
import * as widgets from "./panes/widgets.js";
import type { AppPane, Snapshot } from "./types.js";

// Titles and order match the Swift build's sidebar, including "Menu Bar Widgets".
const PANES: { id: AppPane; title: string }[] = [
  { id: "usage", title: "Usage" },
  { id: "notifications", title: "Notifications" },
  { id: "widgets", title: "Menu Bar Widgets" },
  { id: "about", title: "About" },
];

/** The pane renderers, by id. */
const RENDERERS: Record<AppPane, (snapshot: Snapshot) => string> = {
  usage: usage.render,
  notifications: notifications.render,
  widgets: widgets.render,
  about: about.render,
};

/** Everything the panes need from the shell, so they stay leaves. */
const paneContext = {
  reload: (): void => void reload(),
  selectWindow: (label: string): void => {
    state.windowLabel = label;
    void reload();
  },
};

// ------------------------------------------------------------------- sidebar

function renderSidebar(): void {
  const list = el("pane-list");
  if (!list) return;
  list.innerHTML = PANES.map(
    (pane) => `<li><button data-pane="${pane.id}" aria-current="${pane.id === state.pane}">
      ${paneIcon(pane.id)}
      <span>${pane.title}</span>
    </button></li>`
  ).join("");

  onAll(list, "button", "click", (event) => {
    const pane = targetData(event).pane;
    if (!pane) return;
    state.pane = pane as AppPane;
    render();
    el("content")?.focus();
  });

  const platform = state.snapshot?.platforms;
  const note = el("platform-note");
  if (note) {
    note.textContent = platform ? `${platform.os} · v${state.snapshot?.appVersion ?? ""}` : "";
  }
}

// ------------------------------------------------------------------- toolbar

/**
 * The Swift toolbar: heading left, then provider popup, then two segmented
 * pickers, then a refresh icon button. The picker labels ("Provider", "Metric",
 * "Range") are not rendered — a segmented macOS picker shows only its segments,
 * and showing the labels was making the row read as a form.
 */
function toolbar(snapshot: Snapshot): string {
  const names = snapshot.dashboard.providerNames;
  return `<div class="toolbar">
      <span class="toolbar-title">Usage Dashboard</span>
      <span class="grow"></span>
      <select id="provider-select" class="popup" title="Provider">
        <option value="" ${state.providerFilter ? "" : "selected"}>All providers</option>
        ${names
          .map(
            (name) =>
              `<option value="${esc(name)}" ${
                state.providerFilter === name ? "selected" : ""
              }>${esc(name)}</option>`
          )
          .join("")}
      </select>
      ${segmented(
        "metric-group",
        [
          { value: "tokens", label: "Tokens" },
          { value: "cost", label: "Cost" },
        ],
        state.metric,
        120
      )}
      ${segmented(
        "range-group",
        [
          { value: "24h", label: "24h" },
          { value: "7d", label: "7d" },
          { value: "30d", label: "30d" },
        ],
        state.range,
        180
      )}
      <button class="action icon" id="toolbar-refresh" title="Refresh">↻</button>
    </div>`;
}

// -------------------------------------------------------------------- render

export function render(): void {
  renderSidebar();
  const content = el("content");
  if (!content) return;
  if (!state.snapshot) {
    content.innerHTML = `<div class="empty">Loading…</div>`;
    return;
  }
  // `refresh` runs every five seconds and re-renders by replacing innerHTML, which
  // resets the scroll container to the top — so scrolling down bounced back within
  // a second or two. The offset is captured and put back.
  const scrollTop = content.scrollTop;

  const snapshot = state.snapshot;
  content.innerHTML =
    (state.pane === "usage" ? toolbar(snapshot) : "") + RENDERERS[state.pane](snapshot);
  wireContent(snapshot);
  // Restored *after* wiring, because wiring is what draws the charts: until
  // `usage.layout` has filled the plot frames the page is only as tall as its
  // cards, and clamping to that height pinned the reader back at the top on every
  // five-second refresh. Restoring here, once the real height exists, is what
  // makes the offset stick.
  content.scrollTop = Math.max(
    0,
    Math.min(scrollTop, content.scrollHeight - content.clientHeight)
  );
}

/** Loads a fresh snapshot and redraws. */
export async function reload(): Promise<void> {
  await refresh();
  render();
}

// -------------------------------------------------------------------- wiring

function wireContent(snapshot: Snapshot): void {
  const content = el("content");
  if (!content) return;

  // Usage toolbar. Provider stays a popup (a menu, as in Swift, which uses the
  // default picker style there); Metric and Range are segmented button groups.
  const providerSelect = el<HTMLSelectElement>("provider-select");
  on(providerSelect, "change", () => {
    state.providerFilter = providerSelect?.value || null;
    void reload();
  });
  onAll(content, "#metric-group button", "click", (event) => {
    const value = targetData(event).value;
    if (value) state.metric = value;
    void reload();
  });
  onAll(content, "#range-group button", "click", (event) => {
    const value = targetData(event).value;
    if (value) state.range = value;
    void reload();
  });

  const refreshButton = el<HTMLButtonElement>("toolbar-refresh");
  on(refreshButton, "click", async () => {
    if (refreshButton) refreshButton.disabled = true;
    try {
      await api.refreshNow();
      await reload();
      toast("Refreshed");
    } finally {
      if (refreshButton) refreshButton.disabled = false;
    }
  });

  // The charts are drawn *before* the scroll offset is restored (see `render`):
  // until `layout` has filled the plot frames the page is only as tall as its
  // cards, and clamping to that height pinned the reader back at the top.
  usage.layout(snapshot);

  // Each pane's `wire` no-ops when its elements are absent, so all four can be
  // offered every render without the shell tracking which one is up.
  usage.wire(snapshot, paneContext);
  notifications.wire(snapshot, paneContext);
  widgets.wire(snapshot, paneContext);
  about.wire(snapshot, paneContext);
}

/** Redraws the charts at the frame's current width. Used on resize. */
export function layoutCharts(): void {
  if (state.pane !== "usage" || !state.snapshot) return;
  usage.layout(state.snapshot);
}
