// BurnRate window: sidebar panes rendered from the Rust snapshot.
//
// No framework and no build step yet — the whole UI is this file plus
// styles.css, loaded directly by Tauri from ui/app. Vite arrives with the
// dashboard, where there is finally something to bundle. Every mutation goes
// back through a #[tauri::command], so the settings file stays the one source of
// truth and the window can never disagree with the tray.

const invoke = (cmd, args) => window.__TAURI_INTERNALS__.invoke(cmd, args);

// The Usage pane lives in usage.js: it is the largest view and the one that has
// to match the Swift build section for section. Loaded as a classic script so
// it shares this file's scope without a bundler.
// usage.js is a classic script, not a module, so it registers its renderer here
// and is handed its helpers in `refresh()`. Deliberately nothing else: an
// `Object.assign` at the top of this file referencing `esc` or `tokenCount`
// would be a temporal-dead-zone error (they are `const`, declared below) and
// would take the whole script — and the whole window — down with it.
window.BurnRate = window.BurnRate || {};

// Titles and order match the Swift build's sidebar, including "Menu Bar Widgets".
const PANES = [
  { id: "usage", title: "Usage" },
  { id: "notifications", title: "Notifications" },
  { id: "widgets", title: "Menu Bar Widgets" },
  { id: "about", title: "About" },
];

// Mirrors SettingsView.color(for:) in the Swift build.
const PROVIDER_COLOURS = {
  Claude: "rgb(217, 120, 87)",
  "OpenCode Go": "rgb(64, 140, 242)",
  OpenCode: "rgb(64, 140, 242)",
  Codex: "rgb(51, 173, 112)",
};

const WINDOW_LABELS = ["Rolling", "Weekly", "Monthly"];

let state = {
  pane: "usage",
  snapshot: null,
  providers: [],
  settingsPath: "",
  busy: false,
  // Chart controls, sent with every snapshot so the payload matches the view.
  // Labels are the Swift build's: 24h / 7d / 30d, defaulting to 7d.
  range: "7d",
  metric: "tokens",
  windowLabel: null,
  providerFilter: null,
};

const el = (id) => document.getElementById(id);
const esc = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
  );

function severityColour(remaining) {
  if (remaining === null || remaining === undefined) return "var(--fg-muted)";
  if (remaining >= 55) return "rgb(143, 224, 122)";
  if (remaining >= 45) return "rgb(255, 194, 75)";
  if (remaining >= 20) return "rgb(255, 138, 92)";
  return "rgb(230, 64, 25)";
}

/** "in 4h" style, matching RelativeTime. */
function relativeTime(resetsAtUnix) {
  if (!resetsAtUnix) return "";
  const seconds = resetsAtUnix - Math.floor(Date.now() / 1000);
  if (seconds <= 0) return "now";
  if (seconds < 3600) return `in ${Math.ceil(seconds / 60)}m`;
  if (seconds < 86400) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    return m > 0 ? `in ${h}h ${m}m` : `in ${h}h`;
  }
  return `in ${Math.ceil(seconds / 86400)}d`;
}

/** Binary search for the point nearest `at`, matching ChartData::nearest_point. */
function nearestPoint(points, at) {
  if (!points.length) return null;
  let low = 0;
  let high = points.length - 1;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (points[mid].x < at) low = mid + 1;
    else high = mid;
  }
  const candidate = points[low];
  if (low > 0) {
    const previous = points[low - 1];
    if (Math.abs(previous.x - at) < Math.abs(candidate.x - at)) return previous;
  }
  return candidate;
}

function tokenCount(value) {
  const units = [
    [1e12, "t"],
    [1e9, "b"],
    [1e6, "m"],
    [1e3, "k"],
  ];
  for (const [size, suffix] of units) {
    if (value >= size) return `${trim(value / size)}${suffix}`;
  }
  return String(value);
}

function trim(value) {
  return value.toFixed(2).replace(/\.?0+$/, "");
}

/**
 * The Swift `Picker(…).pickerStyle(.segmented)`, as a button group.
 *
 * A connected run of buttons with the selection lit — not a menu, so not a
 * `<select>`. Used by the toolbar (Metric, Range) and by the trend card's window
 * picker, so it lives here and is handed to usage.js.
 *
 * `totalWidth` fixes the group's width: the Swift build sets an explicit
 * `.frame(width:)` on both, and a control that reflows as options change reads
 * as a layout bug.
 */
function segmented(id, options, selected, totalWidth = 0) {
  return `<div class="segmented" id="${id}" role="group"${
    totalWidth ? ` style="width:${totalWidth}px"` : ""
  }>${options
    .map(
      (option) =>
        `<button type="button" data-value="${esc(option.value ?? option)}"${
          (option.value ?? option) === selected
            ? ' class="on" aria-pressed="true"'
            : ' aria-pressed="false"'
        }>${esc(option.label ?? option)}</button>`
    )
    .join("")}</div>`;
}

let toastTimer = null;
function toast(message) {
  const node = el("toast");
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.remove("show"), 1800);
}

async function refresh() {
  const [snapshot, providers, settingsPath, modelColours] = await Promise.all([
    invoke("snapshot", {
      pane: state.pane,
      range: state.range,
      metric: state.metric,
      windowLabel: state.windowLabel ?? undefined,
      providerFilter: state.providerFilter,
    }),
    invoke("known_providers"),
    invoke("settings_file_path"),
    invoke("model_colours"),
  ]);
  state.snapshot = snapshot;
  state.providers = providers;
  state.settingsPath = settingsPath;
  window.BurnRate.configure({
    providerColours: PROVIDER_COLOURS,
    modelColours,
    tokenCount,
    esc,
    // The pane draws its own segmented controls and looks up its own frames, so
    // it needs the same helpers the shell uses rather than a second copy.
    segmented,
    el,
    selectWindow(label) {
      state.windowLabel = label;
      refresh();
    },
  });
  render();
}

/** Run a command that persists settings, then re-read the snapshot. */
async function mutate(command, args, message) {
  if (state.busy) return;
  state.busy = true;
  try {
    await invoke(command, args);
    if (message) toast(message);
  } catch (error) {
    toast(String(error));
  } finally {
    state.busy = false;
    await refresh();
  }
}

// ---------- rendering ----------

/**
 * Sidebar icons, drawn rather than typed.
 *
 * These were Unicode glyphs ("◐", "▢") which depend on the font having them —
 * the Widgets item rendered with no icon at all. These mirror the SF Symbols the
 * Swift build uses: `chart.bar.doc.horizontal`, `bell.badge.fill`,
 * `menubar.dock.rectangle`, `info.circle`.
 */
const PANE_ICONS = {
  usage: `<path d="M3 13h2v4H3zM7 9h2v8H7zM11 6h2v11h-2z"/><path d="M15.5 12.5h3.2v3.2h-3.2z"/>`,
  notifications: `<path d="M9 3a4.6 4.6 0 0 0-4.6 4.6c0 3.3-1.4 4.3-1.4 4.3h12s-1.4-1-1.4-4.3A4.6 4.6 0 0 0 9 3z"/><path d="M7.6 14.2a1.5 1.5 0 0 0 2.8 0z"/><circle cx="13.6" cy="4.4" r="2.4"/>`,
  widgets: `<rect x="1.6" y="3.4" width="14.8" height="3.6" rx="1.1"/><path d="M3.4 7.6h3.1v5.9H3.4zM7.6 7.6h3.1v5.9H7.6zM11.8 7.6h3.1v5.9h-3.1z"/>`,
  about: `<circle cx="9" cy="9" r="6.6"/><path d="M9 8.1v4.2"/><circle cx="9" cy="5.9" r="0.9"/>`,
};

function paneIcon(id) {
  return `<svg class="glyph" viewBox="0 0 18 18" aria-hidden="true" fill="currentColor">${
    PANE_ICONS[id] ?? ""
  }</svg>`;
}

function renderSidebar() {
  const list = el("pane-list");
  const settings = state.snapshot?.settings;
  const counts = {
    usage: state.snapshot?.usage?.length ?? 0,
    notifications: (settings?.milestones?.length ?? 0) + (settings?.burnAlerts?.length ?? 0),
    widgets: settings?.widgetProviders?.length ?? 0,
    about: null,
  };

  list.innerHTML = PANES.map((pane) => {
    const count = counts[pane.id];
    return `<li><button data-pane="${pane.id}" aria-current="${pane.id === state.pane}">
      ${paneIcon(pane.id)}
      <span>${pane.title}</span>
      ${count === null ? "" : `<span class="count">${count}</span>`}
    </button></li>`;
  }).join("");

  for (const button of list.querySelectorAll("button")) {
    button.addEventListener("click", () => {
      state.pane = button.dataset.pane;
      render();
      el("content").focus();
    });
  }

  const platform = state.snapshot?.platforms;
  el("platform-note").textContent = platform
    ? `${platform.os} · v${state.snapshot.appVersion}`
    : "";
}

function render() {
  renderSidebar();
  const content = el("content");
  if (!state.snapshot) {
    content.innerHTML = `<div class="empty">Loading…</div>`;
    return;
  }
  // `refresh` runs every five seconds and re-renders by replacing innerHTML,
  // which resets the scroll container to the top — so scrolling down bounced back
  // within a second or two. The offset is captured and put back.
  const scrollTop = content.scrollTop;
  // The Swift toolbar: heading left, then provider popup, then two segmented
  // pickers, then a refresh icon button. The picker labels ("Provider", "Metric",
  // "Range") are not rendered — a segmented macOS picker shows only its
  // segments, and showing the labels was making the row read as a form.
  const toolbar = `
    <div class="toolbar">
      <span class="toolbar-title">Usage Dashboard</span>
      <span class="grow"></span>
      <select id="provider-select" class="popup" title="Provider">
        <option value="" ${state.providerFilter ? "" : "selected"}>All providers</option>
        ${(state.snapshot?.dashboard?.providerNames ?? [])
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
  const renderers = {
    usage: window.BurnRate.renderUsage,
    notifications: renderNotifications,
    widgets: renderWidgets,
    about: renderAbout,
  };
  const renderer = renderers[state.pane];
  if (typeof renderer !== "function") {
    content.innerHTML = `<div class="empty">Pane "${state.pane}" failed to load.</div>`;
    return;
  }
  // The Usage pane is the only one with a toolbar above it, as in the Swift build.
  content.innerHTML = (state.pane === "usage" ? toolbar : "") + renderer(state.snapshot);
  // Restored after the new markup is in place, and clamped in case the new
  // content is shorter than the old.
  content.scrollTop = Math.max(
    0,
    Math.min(scrollTop, content.scrollHeight - content.clientHeight)
  );
  wireContent();
}

function renderNotifications() {
  const { settings } = state.snapshot;
  const providers = state.providers.length ? state.providers : ["Claude", "Codex", "OpenCode Go"];

  const milestones = settings.milestones
    .map(
      (rule) => `<div class="row">
        <span class="dot" style="background:${PROVIDER_COLOURS[rule.provider] ?? "var(--accent)"}"></span>
        <span class="grow">${esc(rule.provider)} · ${esc(rule.windowLabel)}</span>
        <input type="number" data-step="${esc(rule.provider)}|${esc(rule.windowLabel)}"
               min="1" max="50" value="${rule.step}" />
        <span class="label">% step</span>
        <button class="link" data-rm-milestone="${esc(rule.provider)}|${esc(rule.windowLabel)}">Remove</button>
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
        <button class="link" data-rm-burn="${esc(rule.provider)}|${esc(rule.windowLabel)}">Remove</button>
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

  return `<h1>Notifications</h1>
    <p class="sub">Milestones fire each time a window drops past another increment.
    One rule per provider and window — duplicates are collapsed on save.</p>

    <div class="card">
      <h2>Milestones</h2>
      ${milestones || `<p class="hint">No milestone rules.</p>`}
      <div class="row">
        <select id="ms-provider">${providers
          .map((p) => `<option>${esc(p)}</option>`)
          .join("")}</select>
        <select id="ms-window">${WINDOW_LABELS.map(
          (label) => `<option>${label}</option>`
        ).join("")}</select>
        <input type="number" id="ms-step" min="1" max="50" value="20" />
        <span class="label">% step</span>
        <button class="action" id="ms-add">Add or replace</button>
      </div>
    </div>

    <div class="card">
      <h2>Burn rate</h2>
      ${burns || `<p class="hint">No burn-rate alerts.</p>`}
      <div class="row">
        <select id="bn-provider">${providers
          .map((p) => `<option>${esc(p)}</option>`)
          .join("")}</select>
        <select id="bn-window">${WINDOW_LABELS.map(
          (label) => `<option>${label}</option>`
        ).join("")}</select>
        <input type="number" id="bn-drop" min="1" max="100" value="15" />
        <span class="label">% in</span>
        <input type="number" id="bn-minutes" min="1" max="720" value="30" />
        <span class="label">min</span>
        <button class="action" id="bn-add">Add or replace</button>
      </div>
    </div>

    <div class="card">
      <h2>Daily spend</h2>
      ${costs || `<p class="hint">No spend caps. Claude's cost is a list-price estimate; OpenCode's is reported.</p>`}
      <div class="row">
        <select id="co-provider">${providers
          .map((p) => `<option>${esc(p)}</option>`)
          .join("")}</select>
        <input type="number" id="co-limit" min="0" step="1" value="20" />
        <span class="label">USD/day</span>
        <button class="action" id="co-save">Save cap</button>
      </div>
    </div>

    <div class="card">
      <h2>Window resets</h2>
      <label class="switch">
        <input type="checkbox" id="notify-reset" ${
          settings.notifyOnReset ? "checked" : ""
        } />
        <span>Notify when a window resets (remaining jumps back up)</span>
      </label>
    </div>`;
}

function renderWidgets() {
  const settings = state.snapshot.settings;
  const providers = state.providers;
  const rows = providers
    .map((provider) => {
      const on = settings.widgetProviders.includes(provider);
      return `<div class="row">
        <span class="dot" style="background:${PROVIDER_COLOURS[provider] ?? "var(--accent)"}"></span>
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
    </div>
`;
}

function renderAbout() {
  const { appVersion, coreVersion, platforms } = state.snapshot;
  const deps = platforms.runtimeDependencies ?? [];
  return `<h1>About</h1>
    <p class="sub">BurnRate — AI plan usage in the menu bar.</p>

    <div class="card">
      <h2>Build</h2>
      <div class="row"><span class="grow label">App</span><span class="value">${esc(
        appVersion
      )}</span></div>
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
      <p class="hint">macOS asks for permission the first time a banner is posted.</p>
    </div>

    <div class="card">
      <h2>Settings file</h2>
      <p class="hint mono">${esc(state.settingsPath)}</p>
      <p class="hint">Written on every change. A Swift install's settings migrate on
      first read.</p>
    </div>
`;
}

// ---------- event wiring ----------

function splitKey(key) {
  const index = key.lastIndexOf("|");
  return [key.slice(0, index), key.slice(index + 1)];
}

function wireContent() {
  const content = el("content");

  const on = (selector, event, handler) => {
    for (const node of content.querySelectorAll(selector)) {
      node.addEventListener(event, handler);
    }
  };

  // Usage toolbar. Provider stays a popup (a menu, as in Swift, which uses the
  // default picker style there); Metric and Range are segmented button groups.
  const providerSelect = el("provider-select");
  if (providerSelect) {
    providerSelect.addEventListener("change", () => {
      state.providerFilter = providerSelect.value || null;
      refresh();
    });
  }
  for (const button of content.querySelectorAll("#metric-group button")) {
    button.addEventListener("click", () => {
      state.metric = button.dataset.value;
      refresh();
    });
  }
  for (const button of content.querySelectorAll("#range-group button")) {
    button.addEventListener("click", () => {
      state.range = button.dataset.value;
      refresh();
    });
  }
  const refreshButton = el("toolbar-refresh");
  if (refreshButton) {
    refreshButton.addEventListener("click", async () => {
      refreshButton.disabled = true;
      try {
        await invoke("refresh_now");
        await refresh();
        toast("Refreshed");
      } catch (error) {
        toast(String(error));
      } finally {
        refreshButton.disabled = false;
      }
    });
  }

  // The Usage pane owns its own charts and tooltips: they are the bulk of this
  // file's old size, and they belong next to the markup that produces them.
  window.BurnRate.layoutUsage?.(state.snapshot);
  window.BurnRate.wireUsage?.(state.snapshot);

  // About
  const testNotification = el("test-notification");
  if (testNotification) {
    testNotification.addEventListener("click", async () => {
      try {
        await invoke("send_test_notification");
        toast("Test notification sent");
      } catch (error) {
        toast(`Notification failed: ${error}`);
      }
    });
  }

  // Notifications
  const msAdd = el("ms-add");
  if (msAdd) {
    msAdd.addEventListener("click", () =>
      mutate(
        "upsert_milestone",
        {
          provider: el("ms-provider").value,
          windowLabel: el("ms-window").value,
          step: Number(el("ms-step").value),
        },
        "Milestone saved"
      )
    );
  }

  const bnAdd = el("bn-add");
  if (bnAdd) {
    bnAdd.addEventListener("click", () =>
      mutate(
        "upsert_burn_alert",
        {
          provider: el("bn-provider").value,
          windowLabel: el("bn-window").value,
          percentDrop: Number(el("bn-drop").value),
          minutes: Number(el("bn-minutes").value),
        },
        "Burn-rate alert saved"
      )
    );
  }

  const coSave = el("co-save");
  if (coSave) {
    coSave.addEventListener("click", () =>
      mutate(
        "upsert_cost_alert",
        {
          provider: el("co-provider").value,
          dailyLimitUsd: Number(el("co-limit").value),
        },
        "Spend cap saved"
      )
    );
  }

  const resetToggle = el("notify-reset");
  if (resetToggle) {
    resetToggle.addEventListener("change", () =>
      mutate(
        "set_notify_on_reset",
        { enabled: resetToggle.checked },
        resetToggle.checked ? "Reset notifications on" : "Reset notifications off"
      )
    );
  }

  on("[data-rm-milestone]", "click", (event) => {
    const [provider, windowLabel] = splitKey(event.currentTarget.dataset.rmMilestone);
    mutate("remove_milestone", { provider, windowLabel }, "Milestone removed");
  });

  on("[data-rm-burn]", "click", (event) => {
    const [provider, windowLabel] = splitKey(event.currentTarget.dataset.rmBurn);
    mutate("remove_burn_alert", { provider, windowLabel }, "Burn-rate alert removed");
  });

  // Editing a step in place
  on("[data-step]", "change", (event) => {
    const [provider, windowLabel] = splitKey(event.currentTarget.dataset.step);
    mutate(
      "upsert_milestone",
      { provider, windowLabel, step: Number(event.currentTarget.value) },
      "Milestone saved"
    );
  });

  on("[data-drop],[data-minutes]", "change", (event) => {
    const key = event.currentTarget.dataset.drop ?? event.currentTarget.dataset.minutes;
    const [provider, windowLabel] = splitKey(key);
    const settings = state.snapshot.settings;
    const existing = settings.burnAlerts.find(
      (rule) => rule.provider === provider && rule.windowLabel === windowLabel
    );
    mutate(
      "upsert_burn_alert",
      {
        provider,
        windowLabel,
        percentDrop: Number(el(`[data-drop="${key}"]`)?.value ?? existing?.percentDrop ?? 15),
        minutes: Number(el(`[data-minutes="${key}"]`)?.value ?? existing?.minutes ?? 30),
      },
      "Burn-rate alert saved"
    );
  });

  on("[data-cost]", "change", (event) => {
    mutate(
      "upsert_cost_alert",
      { provider: event.currentTarget.dataset.cost, dailyLimitUsd: Number(event.currentTarget.value) },
      "Spend cap saved"
    );
  });

  // Widgets
  on("[data-widget]", "change", (event) => {
    const provider = event.currentTarget.dataset.widget;
    mutate("toggle_widget", { provider }, "Widget updated");
  });

}

// Chart layout and tooltips live in usage.js, next to the markup that produces
// them.

// ---------- boot ----------

async function main() {
  // The app icon comes from the Rust renderer, not a file path: the bundled
  // icons live outside the served ui/app directory.
  el("brand-icon").src = await invoke("app_icon_data_url", { edge: 56 });
  el("brand-sub").textContent = "menu bar";
  await refresh();
  // The shell's heartbeat is what drives the tick; mirror it here.
  setInterval(refresh, 5000);

  // Charts are drawn for the measured pixel width, so they have to be redrawn
  // when that changes. Without this they keep the width they were first drawn
  // at, and every resize leaves the axis text stretched or the plot short.
  let resizeTimer = null;
  new ResizeObserver(() => {
    if (state.pane !== "usage" || !state.snapshot) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      window.BurnRate.layoutUsage?.(state.snapshot);
    }, 60);
  }).observe(el("content"));
}

main();
