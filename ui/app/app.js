// BurnRate window: sidebar panes rendered from the Rust snapshot.
//
// No framework and no build step yet — the whole UI is this file plus
// styles.css, loaded directly by Tauri from ui/app. Vite arrives with the
// dashboard, where there is finally something to bundle. Every mutation goes
// back through a #[tauri::command], so the settings file stays the one source of
// truth and the window can never disagree with the tray.

const invoke = (cmd, args) => window.__TAURI_INTERNALS__.invoke(cmd, args);

const PANES = [
  { id: "usage", title: "Usage", glyph: "◐" },
  { id: "notifications", title: "Notifications", glyph: "◔" },
  { id: "widgets", title: "Widgets", glyph: "▢" },
  { id: "about", title: "About", glyph: "ⓘ" },
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
  iconStates: [],
  settingsPath: "",
  busy: false,
};

const el = (id) => document.getElementById(id);
const esc = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
  );

const fmtPercent = (value) =>
  value === null || value === undefined ? "--" : `${Math.round(value)}%`;

/** Severity ramp, mirroring StatusIcon.tint's stops. */
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

let toastTimer = null;
function toast(message) {
  const node = el("toast");
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.remove("show"), 1800);
}

async function refresh() {
  const [snapshot, providers, iconStates, settingsPath] = await Promise.all([
    invoke("snapshot", { pane: state.pane }),
    invoke("known_providers"),
    invoke("icon_states"),
    invoke("settings_file_path"),
  ]);
  state.snapshot = snapshot;
  state.providers = providers;
  state.iconStates = iconStates;
  state.settingsPath = settingsPath;
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
      <span class="glyph">${pane.glyph}</span>
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
  const renderers = {
    usage: renderUsage,
    notifications: renderNotifications,
    widgets: renderWidgets,
    about: renderAbout,
  };
  content.innerHTML = renderers[state.pane]();
  wireContent();
}

function renderUsage() {
  const { usage, missing, settings } = state.snapshot;
  const parts = [`<h1>Usage</h1>
    <p class="sub">Plan windows for each detected provider, and the icon severity they drive.</p>`];

  if (!usage.length) {
    parts.push(`<div class="empty">
      <strong>No providers found yet.</strong>
      <p class="hint">The quota providers land in the next port step. Until then this
      window shows the shell: settings, widgets and the icon ramp below all work.</p>
    </div>`);
  }

  for (const provider of usage) {
    const colour = PROVIDER_COLOURS[provider.providerName] ?? "var(--accent)";
    const rows = (provider.windows ?? [])
      .map((window) => {
        const percent = window.percentRemaining;
        const reset = relativeTime(window.resetsAt);
        return `<div class="window">
          <div class="head">
            <span>${esc(window.label)}</span>
            <span>
              <strong style="color:${severityColour(percent)}">${fmtPercent(percent)}</strong>
              ${reset ? `<span class="reset"> · resets ${reset}</span>` : ""}
            </span>
          </div>
          <div class="meter">
            <span style="width:${percent == null ? 0 : Math.max(0, Math.min(100, percent))}%;background:${severityColour(percent)}"></span>
          </div>
          <div class="reset">${tokenCount(window.tokensUsed ?? 0)} tokens</div>
        </div>`;
      })
      .join("");
    parts.push(`<div class="card">
      <div class="provider-head">
        <span class="dot" style="background:${colour}"></span>
        ${esc(provider.providerName)}
        ${provider.plan ? `<span class="pill">${esc(provider.plan)}</span>` : ""}
      </div>
      ${rows || `<p class="hint">No quota windows reported.</p>`}
    </div>`);
  }

  if (missing.length) {
    parts.push(`<div class="card">
      <h2>Not detected</h2>
      ${missing.map((line) => `<div class="row"><span class="grow missing">${esc(line)}</span></div>`).join("")}
    </div>`);
  }

  parts.push(`<div class="card">
    <h2>Polling</h2>
    <div class="row">
      <span class="grow label">Interval</span>
      <input type="number" id="poll-interval" min="30" max="3600" step="30"
             value="${settings.pollIntervalSeconds}" />
      <span class="label">seconds</span>
      <button class="action" id="poll-save">Save</button>
    </div>
    <p class="hint">Tick ${state.snapshot.tick} · last poll ${
      state.snapshot.lastPollUnix
        ? new Date(state.snapshot.lastPollUnix * 1000).toLocaleTimeString()
        : "—"
    }</p>
  </div>`);

  return parts.join("");
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
      ${costs || `<p class="hint">No spend caps. Only OpenCode reports cost today.</p>`}
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
  const providers = state.providers.length ? state.providers : ["Claude", "Codex", "OpenCode Go"];
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
      ${rows || `<p class="hint">No providers known yet.</p>`}
    </div>
    <div class="card">
      <h2>Charts row</h2>
      <label class="switch">
        <input type="checkbox" id="includes-charts" ${
          settings.includesCharts ? "checked" : ""
        } />
        <span>Show “Charts…” in the tray menu</span>
      </label>
      <p class="hint">Off by default on macOS, where this window is the dashboard
      itself. Linux and Windows default it on.</p>
    </div>`;
}

/** The G2 mark at each severity stop, so the ramp is inspectable, not implied. */
function iconStrip() {
  return state.iconStates
    .map((entry) => {
      const angle = entry.needleDegrees;
      return `<div class="icon-swatch">
        <div class="plate">
          <svg viewBox="0 0 72 72" aria-hidden="true">
            <path d="M36 6 C33 14 24 20 19.5 27 C16.5 32 15.5 36.5 15.5 41
                     C15.5 52 24.5 60 36 60 C47.5 60 56.5 52 56.5 41
                     C56.5 36.5 55.5 32 52.5 27 C48 20 39 14 36 6 Z"
                  fill="${entry.tint}"/>
            <circle cx="36" cy="42" r="10.5" fill="#200a02"/>
            <line x1="36" y1="46" x2="${36 + 22 * Math.sin((angle * Math.PI) / 180)}"
                  y2="${46 - 22 * Math.cos((angle * Math.PI) / 180)}"
                  stroke="#fff6ea" stroke-width="2.6" stroke-linecap="round"/>
            <circle cx="36" cy="46" r="2.2" fill="#fff6ea"/>
          </svg>
        </div>
        <div class="cap">${entry.remaining}%</div>
      </div>`;
    })
    .join("");
}

function renderAbout() {
  const { appVersion, coreVersion, platforms, remaining } = state.snapshot;
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
      <div class="row"><span class="grow label">Icon severity</span><span class="value">${fmtPercent(
        remaining
      )} remaining</span></div>
      ${
        deps.length
          ? `<div class="row"><span class="grow label">Runtime deps</span><span class="value">${deps
              .map(esc)
              .join(", ")}</span></div>`
          : ""
      }
    </div>

    <div class="card">
      <h2>Settings file</h2>
      <p class="hint mono">${esc(state.settingsPath)}</p>
      <p class="hint">Written on every change. A Swift install's settings migrate on
      first read.</p>
    </div>

    <div class="card">
      <h2>Icon severity ramp</h2>
      <div class="icon-strip">${iconStrip()}</div>
      <p class="hint">Needle angle and flame tint both track remaining percent. The
      app icon ships at the 45% pose, which is the amber in the shipped
      <code>AppIcon.icns</code>.</p>
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

  // Usage
  const pollSave = el("poll-save");
  if (pollSave) {
    pollSave.addEventListener("click", () =>
      mutate(
        "set_poll_interval",
        { seconds: Number(el("poll-interval").value) },
        "Polling interval saved"
      )
    );
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

  const charts = el("includes-charts");
  if (charts) {
    charts.addEventListener("change", async () => {
      const settings = state.snapshot.settings;
      settings.includesCharts = charts.checked;
      await mutate("save_settings", { settings }, "Tray menu updated");
    });
  }
}

// ---------- boot ----------

async function main() {
  // The app icon comes from the Rust renderer, not a file path: the bundled
  // icons live outside the served ui/app directory.
  el("brand-icon").src = await invoke("app_icon_data_url", { edge: 56 });
  el("brand-sub").textContent = "menu bar";
  await refresh();
  // The shell's heartbeat is what drives the tick; mirror it here.
  setInterval(refresh, 5000);
}

main();
