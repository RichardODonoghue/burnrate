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

const REPO_SLUG = "RichardODonoghue/burnrate";
const REPO_URL = `https://github.com/${REPO_SLUG}`;
const ISSUES_URL = `${REPO_URL}/issues`;

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
 * Icons, drawn rather than typed.
 *
 * These were Unicode glyphs ("◐", "▢") which depend on the font having them — the
 * Widgets item rendered with no icon at all. They mirror the SF Symbols the Swift
 * build uses. Each entry carries its own fill/stroke: an outlined shape drawn
 * with the group's `fill` becomes a solid blob, which is what the About item was.
 */
const ICONS = {
  // chart.bar.doc.horizontal
  usage: `<g fill="currentColor"><path d="M3.2 12.4h2.3v2.8H3.2z"/><path d="M7.85 8.2h2.3v7H7.85z"/><path d="M12.5 4.8h2.3v10.4h-2.3z"/></g>`,
  // bell.badge.fill
  notifications: `<g fill="currentColor"><path d="M9 2.6a4.7 4.7 0 0 0-4.7 4.7c0 3.3-1.4 4.3-1.4 4.3h12.2s-1.4-1-1.4-4.3A4.7 4.7 0 0 0 9 2.6z"/><path d="M7.5 13.4a1.5 1.5 0 0 0 3 0z"/></g><g fill="currentColor" stroke="var(--sidebar)" stroke-width="1.3"><circle cx="13.4" cy="4.6" r="2.4"/></g>`,
  // menubar.dock.rectangle
  widgets: `<g fill="currentColor"><rect x="1.6" y="3.2" width="14.8" height="3.4" rx="1.1"/><rect x="3.5" y="7.4" width="3.1" height="5.8" rx="0.8"/><rect x="7.45" y="7.4" width="3.1" height="5.8" rx="0.8"/><rect x="11.4" y="7.4" width="3.1" height="5.8" rx="0.8"/></g>`,
  // info.circle — outlined, so it must not inherit a fill
  about: `<g fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="9" cy="9" r="6.4"/></g><g fill="currentColor"><circle cx="9" cy="5.9" r="0.95"/><rect x="8.2" y="7.9" width="1.6" height="4.4" rx="0.8"/></g>`,
  // gauge.medium
  gauge: `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2.6 12.9a6.4 6.4 0 1 1 12.8 0"/><path d="M9 12.9 12.1 8.4"/></g><circle cx="9" cy="12.9" r="1.2" fill="currentColor"/>`,
  // bell.badge (outlined)
  bell: `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M9 3.1a4.4 4.4 0 0 0-4.4 4.4c0 3-1.3 4-1.3 4h11.4s-1.3-1-1.3-4A4.4 4.4 0 0 0 9 3.1z"/><path d="M7.6 13.6a1.5 1.5 0 0 0 2.8 0"/></g><circle cx="13.5" cy="4.5" r="2.3" fill="currentColor"/>`,
  // arrow.down.circle
  download: `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="9" r="6.4"/><path d="M9 5.7v6.4"/><path d="M6.4 9.4 9 12l2.6-2.6"/></g>`,
  // checkmark.seal
  seal: `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="9" r="6.4"/><path d="M6.2 9.3 8.1 11.2 12 7.2"/></g>`,
  // internaldrive
  drive: `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><rect x="2.1" y="4.9" width="13.8" height="8.2" rx="1.7"/></g><circle cx="5.1" cy="9" r="0.95" fill="currentColor"/><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M7.9 9h5.5"/></g>`,
  // exclamationmark.bubble
  bubble: `<g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M2.4 4.2h13.2v7.4H8.3L4.9 14.6v-3H2.4z"/></g><g fill="currentColor"><rect x="8.25" y="6" width="1.5" height="3" rx="0.75"/><circle cx="9" cy="10.1" r="0.85"/></g>`,
  // The GitHub mark, filled.
  github: `<path fill="currentColor" d="M9 1.6a7.4 7.4 0 0 0-2.34 14.42c.37.07.5-.16.5-.36v-1.25c-2.06.45-2.49-.99-2.49-.99-.34-.86-.83-1.09-.83-1.09-.67-.46.05-.45.05-.45.75.05 1.14.77 1.14.77.66 1.13 1.73.8 2.15.61.07-.48.26-.8.47-.99-1.64-.19-3.37-.82-3.37-3.66 0-.81.29-1.47.76-1.99-.08-.19-.33-.94.07-1.96 0 0 .62-.2 2.04.76a7.1 7.1 0 0 1 3.71 0c1.42-.96 2.03-.76 2.03-.76.41 1.02.15 1.77.08 1.96.48.52.76 1.18.76 1.99 0 2.85-1.73 3.47-3.38 3.65.27.23.5.68.5 1.38v2.05c0 .2.13.44.51.36A7.4 7.4 0 0 0 9 1.6z"/>`,
};

/** The sidebar's icon for a pane. */
function paneIcon(id) {
  return `<svg class="glyph" viewBox="0 0 18 18" aria-hidden="true">${ICONS[id] ?? ""}</svg>`;
}

/** An icon for a labelled row in the About pane. */
function rowIcon(id) {
  return `<svg class="row-glyph" viewBox="0 0 18 18" aria-hidden="true">${ICONS[id] ?? ""}</svg>`;
}

function renderSidebar() {
  const list = el("pane-list");
  // No counts beside the names: the numbers were a running tally of how many
  // rules or widgets each pane holds, which says nothing about whether anything
  // needs attention.
  list.innerHTML = PANES.map(
    (pane) => `<li><button data-pane="${pane.id}" aria-current="${pane.id === state.pane}">
      ${paneIcon(pane.id)}
      <span>${pane.title}</span>
    </button></li>`
  ).join("");

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
  wireContent();
  // Restored *after* wiring, because wiring is what draws the charts: until
  // `layoutUsage` has filled the plot frames the page is only as tall as its
  // cards, and clamping to that height pinned the reader back at the top on
  // every five-second refresh. Restoring here, once the real height exists,
  // is what makes the offset stick.
  content.scrollTop = Math.max(
    0,
    Math.min(scrollTop, content.scrollHeight - content.clientHeight)
  );
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

  /** One `Label(text, systemImage:)` row, as the Swift cards are built from. */
  const labelled = (icon, text) =>
    `<div class="about-row">${rowIcon(icon)}<span>${esc(text)}</span></div>`;

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
        <button class="action" id="check-updates">Check for Updates</button>
      </div>
      <p class="hint">Opens the releases page. This build does not install updates
      itself.</p>
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

  // About. The hero icon is the shipped bundle icon, as the Swift AboutView
  // uses it — not the live severity-tinted renderer.
  const aboutIcon = el("about-icon");
  if (aboutIcon) {
    invoke("app_icon_data_url", { edge: 144 }).then((url) => {
      aboutIcon.src = url;
    });
  }
  for (const link of content.querySelectorAll("[data-open]")) {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      invoke("open_url", { url: link.dataset.open }).catch((error) => toast(String(error)));
    });
  }
  const checkUpdates = el("check-updates");
  if (checkUpdates) {
    checkUpdates.addEventListener("click", () =>
      invoke("open_url", { url: `${REPO_URL}/releases` }).catch((error) => toast(String(error)))
    );
  }
  const testNotification = el("test-notification");
  if (testNotification) {
    testNotification.addEventListener("click", async () => {
      try {
        toast(await invoke("send_test_notification"));
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
