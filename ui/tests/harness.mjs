// Headless check that the window boots and every pane renders the markup the
// Swift build's view has.
//
// Loads the *emitted* modules against a stubbed DOM and IPC, then asserts the
// resulting markup. Not a unit test of a function's return value: the bug this
// exists to catch is "the script did not run at all", which a direct call cannot
// see.
//
//   npm test          (from ui/)
//
// Run `npm run build` first; this reads app/js, the same files the webview loads.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const appDir = join(here, "..", "app");

// ------------------------------------------------------------------ DOM stub

// The DOM classes the production code narrows against. Without these, any
// `instanceof Element` in a handler throws in Node — and `on`'s error wrapper
// swallows that into a toast, so the handler looks like it ran and did nothing.
class Element {
  closest() {
    return null;
  }
}
class HTMLElement extends Element {}
class HTMLInputElement extends HTMLElement {}
class HTMLSelectElement extends HTMLElement {}
class HTMLImageElement extends HTMLElement {}
// Not `extends Event`: Node's global `Event.target` is a getter-only accessor, so
// a subclass cannot assign it. A plain class is enough for `instanceof MouseEvent`
// and for the handler's reads.
class MouseEvent {
  constructor(init = {}) {
    this.type = "mousemove";
    this.clientX = init.clientX ?? 0;
    this.clientY = init.clientY ?? 0;
    this.target = init.target ?? null;
  }
  preventDefault() {}
}
Object.assign(globalThis, {
  Element,
  HTMLElement,
  HTMLInputElement,
  HTMLSelectElement,
  HTMLImageElement,
  MouseEvent,
});

/** An element-like target with a dataset and a `closest`. */
function fakeTarget(dataset, match) {
  const node = new Element();
  node.dataset = dataset;
  node.closest = (selector) => (selector === match ? node : null);
  return node;
}

const store = new Map();
const listeners = [];

/** Element ids whose markup the charts are drawn into. */
const PLOT_IDS = ["trend-plot", "daily-plot", "ranking-plot"];

function element(id) {
  // A plain object with the right prototype rather than `Object.assign` onto an
  // instance: `assign` copies accessors by *value*, which would flatten the
  // `innerHTML` getter/setter pair into a data property and lose every write.
  const node = {
    id,
    textContent: "",
    _innerHTML: "",
    get innerHTML() {
      return this._innerHTML;
    },
    set innerHTML(value) {
      this._innerHTML = value;
      // Replacing the shell's markup discards the chart SVGs with it, so the page
      // is briefly short. Without this the stub keeps the previous render's charts
      // and the short-page scroll clamp can never be observed.
      if (id === "content") {
        for (const plot of PLOT_IDS) {
          const child = store.get(plot);
          if (child) child._innerHTML = "";
        }
        if (globalThis.__resetScrollOnInnerHTML) this.scrollTop = 0;
      }
    },
    value: "",
    checked: false,
    disabled: false,
    hidden: false,
    src: "",
    scrollTop: 0,
    clientWidth: 700,
    // The scroll container is tall; a chart frame is its drawn height.
    clientHeight: id === "content" ? 600 : 220,
    get scrollHeight() {
      const drawn = (store.get("trend-plot")?._innerHTML ?? "").length > 0;
      return drawn ? 2000 : 700;
    },
    set scrollHeight(_value) {},
    offsetWidth: 150,
    offsetHeight: 70,
    classList: { add() {}, remove() {}, contains: () => false },
    style: {},
    dataset: {},
    className: "",
    querySelectorAll: (selector) =>
      selector === "button" ? globalThis.__windowButtons : [],
    querySelector: () => null,
    addEventListener(type, fn) {
      listeners.push({ id, type, fn });
    },
    removeEventListener() {},
    setAttribute() {},
    appendChild() {},
    focus() {},
    closest: () => null,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 700, height: 220 }),
  };
  Object.setPrototypeOf(node, HTMLElement.prototype);
  return node;
}

globalThis.document = {
  getElementById: (id) => {
    if (!store.has(id)) store.set(id, element(id));
    return store.get(id);
  },
  createElement: () => element("created"),
  addEventListener() {},
};

globalThis.window = globalThis;
globalThis.__resetScrollOnInnerHTML = true;
globalThis.ResizeObserver = class {
  observe() {}
};
globalThis.setInterval = () => 0;
globalThis.clearInterval = () => {};

/** The segmented-control buttons, which the window picker's wiring looks up. */
globalThis.__windowButtons = ["Rolling", "Weekly", "Fable"].map((value) => ({
  dataset: { value },
  addEventListener(type, fn) {
    listeners.push({ id: `window:${value}`, type, fn });
  },
}));

// ------------------------------------------------------------------ fixture

const NOW = Math.floor(Date.now() / 1000);
const bar = (key, value) => ({
  key,
  provider: "Claude",
  label: key,
  value,
  cost: 0,
  tokens: value,
  input: Math.round(value * 0.6),
  output: Math.round(value * 0.1),
  cache: Math.round(value * 0.3),
  reasoning: 0,
  requests: 4,
  valueText: `${value}`,
  annotation: `${value} tok`,
});
const day = (offset) => NOW - offset * 86_400;
const daily = [7, 6, 5, 4, 3, 2, 1, 0].map((offset) => {
  const empty = offset === 4;
  const total = empty ? 0 : (offset + 1) * 1e6;
  return {
    day: day(offset),
    total,
    totalText: `${total}`,
    bars: empty ? [] : [bar("claude-opus-5", total)],
  };
});

const snapshot = {
  pane: "usage",
  settings: {
    milestones: [],
    widgetProviders: [],
    burnAlerts: [],
    costAlerts: [],
    notifyOnReset: true,
    pollIntervalSeconds: 300,
  },
  usage: [
    {
      providerName: "Claude",
      plan: null,
      windows: [
        { id: "a", label: "Rolling", tokensUsed: 0, percentRemaining: 73, resetsAt: null },
        { id: "b", label: "Weekly", tokensUsed: 0, percentRemaining: 11, resetsAt: null },
        { id: "c", label: "Fable", tokensUsed: 0, percentRemaining: 100, resetsAt: null },
      ],
    },
    {
      providerName: "OpenCode Go",
      plan: "Go",
      windows: [
        { id: "d", label: "Rolling", tokensUsed: 0, percentRemaining: 93, resetsAt: null },
        { id: "e", label: "Weekly", tokensUsed: 0, percentRemaining: 95, resetsAt: null },
        { id: "f", label: "Monthly", tokensUsed: 0, percentRemaining: 94, resetsAt: null },
      ],
    },
  ],
  missing: [],
  remaining: 73,
  appVersion: "1.0.0",
  coreVersion: "1.0.0",
  updateAvailable: null,
  updateState: "up to date (1.0.0)",
  updateBusy: false,
  canInstallUpdate: true,
  lastPollUnix: NOW,
  pollCount: 3,
  platforms: { os: "macOS", runtimeDependencies: [] },
  spendToday: {},
  dashboard: {
    range: "week",
    rangeLabel: "7d",
    metric: "tokens",
    metricLabel: "Tokens",
    windowLabel: "Weekly",
    providerFilter: null,
    windowLabels: ["Rolling", "Weekly", "Fable"],
    providerNames: ["Claude"],
    rolling: [{ key: "Claude", label: "Claude", value: "73%" }],
    tokensToday: 1_200_000,
    requestsToday: 12,
    costToday: 1.23,
    series: [
      {
        key: "k",
        name: "Claude",
        provider: "Claude",
        scoped: false,
        points: [
          { x: NOW - 3600, y: 90 },
          { x: NOW, y: 80 },
        ],
      },
      {
        key: "s",
        name: "Claude Fable",
        provider: "Claude",
        scoped: true,
        points: [
          { x: NOW - 3600, y: 20 },
          { x: NOW, y: 10 },
        ],
      },
    ],
    xDomain: [NOW - 3600, NOW],
    xStyle: "hourly",
    xTicks: [{ at: NOW, label: "now" }],
    yDomain: [0, 100],
    yTicks: [0, 25, 50, 75, 100],
    daily,
    dailyYTicks: [0, 2e6, 4e6, 6e6, 8e6],
    dailyYLabels: ["0", "2m", "4m", "6m", "8m"],
    dailyMaximum: 8e6,
    hasData: true,
    ranking: [bar("claude-opus-5", 3e6), bar("gpt-5", 1e6)],
    rankingTicks: [0, 1e6, 2e6, 3e6],
    rankingTickLabels: ["0", "1m", "2m", "3m"],
    table: [bar("claude-opus-5", 3e6)],
    unpricedModels: [],
  },
};

// ------------------------------------------------------------------ IPC stub

globalThis.__TAURI_INTERNALS__ = {
  invoke: async (command) => {
    switch (command) {
      case "snapshot":
        return snapshot;
      case "known_providers":
        return ["Claude", "OpenCode Go"];
      case "settings_file_path":
        return "/tmp/settings.json";
      case "model_colours":
        return { "claude-opus-5": "rgb(217,120,87)" };
      case "app_icon_data_url":
        return "data:,";
      default:
        return null;
    }
  },
};

// ------------------------------------------------------------------ the run

const { render, reload } = await import("../app/js/shell.js");
const { state } = await import("../app/js/store.js");

let failures = 0;
function check(name, ok, detail = "") {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
}
const html = () => store.get("content")?._innerHTML ?? "";
const plot = (id) => store.get(id)?._innerHTML ?? "";
const css = readFileSync(join(appDir, "styles.css"), "utf8");

state.snapshot = snapshot;
state.providers = ["Claude", "OpenCode Go"];
state.settingsPath = "/tmp/settings.json";
state.modelColours = { "claude-opus-5": "rgb(217,120,87)" };
render();

console.log("--- usage pane, markup ---");
const usage = html();
check("renders", usage.length > 0, `${usage.length} bytes`);
check("no NaN/undefined", !/NaN|undefined/.test(usage), (usage.match(/NaN|undefined/g) ?? []).join(","));
check("toolbar heading", usage.includes("Usage Dashboard"));
check("provider popup", usage.includes('id="provider-select"'));
check("metric is segmented", usage.includes('id="metric-group"'));
check("range is segmented", usage.includes('id="range-group"'));
check("no <select> for metric/range", !usage.includes("metric-select") && !usage.includes("range-select"));

const windowGroup = usage.slice(usage.indexOf('id="window-group"'));
const order = [...windowGroup.matchAll(/data-value="([^"]+)"/g)].map((m) => m[1]);
check("window order from the snapshot", order.join(",") === "Rolling,Weekly,Fable", order.join(","));

const at = (needle) => usage.indexOf(needle);
check("cards first", at("Rolling usage") < at("Remaining over time"));
check("trend before daily", at("Remaining over time") < at("Daily usage by model"));
check("daily before top models", at("Daily usage by model") < at("Top models"));
check("top models before breakdown", at("Top models") < at("Breakdown"));
check("no cards the Swift build lacks", !usage.includes("Not detected") && !usage.includes("Polling"));

for (const column of ["MODEL", "INPUT", "OUTPUT", "CACHE", "REQUESTS", "TOKENS", "COST"]) {
  check(`breakdown column ${column}`, usage.includes(`>${column}</span>`));
}

console.log("--- charts ---");
const trend = plot("trend-plot");
const dailySvg = plot("daily-plot");
const ranking = plot("ranking-plot");
check("trend drawn", trend.includes('id="trend"'));
check("trend uses the measured width", trend.includes('width="700"'));
check("trend has the selection rule", trend.includes('id="trend-rule"'));
check("scoped series dashed", trend.includes("stroke-dasharray"));
check("trend curves, not polylines", trend.includes(" C"));
const coords = [...trend.matchAll(/[MC]\s*[\d.]+[ ,]([\d.]+)/g)].map((m) => Number(m[1]));
check("every trend coordinate is inside the plot", coords.every((y) => y >= 0 && y <= 180));

check("daily drawn", dailySvg.includes('id="daily"'));
check("daily y labels are pre-formatted", dailySvg.includes(">8m</text>") && !dailySvg.includes("8000000"));
check("daily draws a slot per calendar day", (dailySvg.match(/class="day"/g) ?? []).length === 8);
// No day is faded: the part-day opacity was a divergence from the Swift build
// that nobody asked for, and it made today's bar look wrong rather than
// incomplete.
check("no day is faded", !/opacity="0\.5"/.test(dailySvg), dailySvg.match(/opacity="[\d.]+"/g)?.join(",") ?? "");
const emptyGroup = `class="day"${dailySvg.split('class="day"')[4]}`;
check("daily empty day draws no bar", (emptyGroup.match(/<rect/g) ?? []).length === 1);

check("ranking drawn", ranking.includes('id="ranking"'));
check("ranking annotations carry the unit", ranking.includes("3000000 tok"));
check("ranking has a value axis for tokens", (ranking.match(/class="tick mid"/g) ?? []).length === 4);

console.log("--- y labels clear the plot ---");
for (const [name, svg] of [
  ["trend", trend],
  ["daily", dailySvg],
]) {
  const gridEnds = [...svg.matchAll(/class="grid"[^>]*x2="([\d.]+)"/g)].map((m) => Number(m[1]));
  const plotRight = Math.max(...gridEnds);
  const svgWidth = Number(svg.match(/viewBox="0 0 ([\d.]+)/)[1]);
  const labels = [...svg.matchAll(/<text class="([^"]*)" x="([\d.]+)"[^>]*>([^<]*)</g)]
    .map((m) => ({ classes: m[1], x: Number(m[2]), text: m[3] }))
    .filter((label) => !label.classes.includes("mid"));
  const box = (label) => {
    const width = label.text.length * 6.2;
    const anchor = label.classes.includes("end") ? "end" : "start";
    const left = anchor === "end" ? label.x - width : label.x;
    return { left, right: left + width };
  };
  check(`${name} has y labels`, labels.length > 0, `${labels.length}`);
  check(
    `${name} y labels do not reach into the plot`,
    labels.every((label) => box(label).left >= plotRight),
    `plot right ${plotRight}, leftmost ${Math.min(...labels.map((l) => box(l).left)).toFixed(1)}`
  );
  check(
    `${name} y labels fit the frame`,
    labels.every((label) => box(label).right <= svgWidth),
    `width ${svgWidth}, widest right ${Math.max(...labels.map((l) => box(l).right)).toFixed(0)}`
  );
}

console.log("--- x axis thinning ---");
const realTicks = snapshot.dashboard.xTicks;
const day0 = NOW - 30 * 86_400;
snapshot.dashboard.xTicks = [];
for (let index = 0; index < 30; index += 1) {
  for (const [offset, label] of [
    [0, ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][index % 7]],
    [43_200, "12pm"],
  ]) {
    snapshot.dashboard.xTicks.push({ at: day0 + index * 86_400 + offset, label });
  }
}
snapshot.dashboard.xDomain = [day0, day0 + 30 * 86_400];
render();
const thinned = plot("trend-plot");
const drawn = [...thinned.matchAll(/class="tick mid" x="([\d.]+)"[^>]*>([^<]*)</g)].map((m) => ({
  x: Number(m[1]),
  text: m[2],
}));
check("30d keeps every gridline", (thinned.match(/class="grid"/g) ?? []).length >= 60);
check("30d drops labels that will not fit", drawn.length < 60, `${drawn.length} of 60`);
const gaps = drawn
  .slice(1)
  .map((label, index) => label.x - drawn[index].x - (label.text.length + drawn[index].text.length) * 3.1);
check("no two labels can touch", Math.min(...gaps) >= 0, `closest ${Math.round(Math.min(...gaps))}px`);
snapshot.dashboard.xTicks = realTicks;
snapshot.dashboard.xDomain = [NOW - 3600, NOW];
render();

console.log("--- tooltips ---");
const fire = (id, event) => {
  const bound = listeners.filter((entry) => entry.id === id && entry.type === "mousemove");
  if (!bound.length) return { fired: false, error: "no handler" };
  // `on` reports a throwing handler through the toast, so a handler that "ran"
  // and did nothing is visible here rather than silently passing.
  const toastNode = store.get("toast");
  if (toastNode) toastNode.textContent = "";
  bound[bound.length - 1].fn(event);
  const complained = store.get("toast")?.textContent ?? "";
  return complained ? { fired: false, error: complained } : { fired: true };
};
const firstDay = daily.find((entry) => entry.bars.length);
const cases = [
  ["trend", "trend-plot", "trend-tip", new MouseEvent({ clientX: 699, target: fakeTarget({}, "") })],
  [
    "daily",
    "daily-plot",
    "daily-tip",
    new MouseEvent({
      target: fakeTarget({ day: String(firstDay.day), x: "690", slot: "40" }, ".day"),
    }),
  ],
  [
    "ranking",
    "ranking-plot",
    "ranking-tip",
    new MouseEvent({ target: fakeTarget({ key: "claude-opus-5", y: "210" }, ".rank") }),
  ],
];
for (const [name, plotId, tipId, event] of cases) {
  const result = fire(plotId, event);
  check(`${name} tooltip handler runs`, result.fired, result.error);
  const tip = store.get(tipId);
  check(`${name} tooltip is shown`, tip.hidden === false);
  check(`${name} tooltip has content`, (tip._innerHTML ?? "").length > 40);
  const left = Number.parseFloat(tip.style.left);
  const top = Number.parseFloat(tip.style.top);
  check(
    `${name} tooltip stays inside its frame`,
    left >= 0 && left + tip.offsetWidth <= 700 && top >= 0 && top + tip.offsetHeight <= 220,
    `left ${left} top ${top}`
  );
}

console.log("--- notification windows follow the provider ---");
state.pane = "notifications";
render();
const notif = html();
const msWindow = (notif.match(/<select id="ms-window">([\s\S]*?)<\/select>/) ?? ["", ""])[1];
check("Claude offers no Monthly milestone", !msWindow.includes("Monthly"), msWindow);
check("Claude offers its reported windows, not the fallback", msWindow.includes("Fable"), msWindow);
const bnWindow = (notif.match(/<select id="bn-window">([\s\S]*?)<\/select>/) ?? ["", ""])[1];
check("Claude offers no Monthly burn rule", !bnWindow.includes("Monthly"), bnWindow);
const providerChange = listeners.filter((l) => l.id === "ms-provider" && l.type === "change").pop();
check("the provider select rebuilds the windows", Boolean(providerChange));
if (providerChange) {
  store.get("ms-provider").value = "OpenCode Go";
  providerChange.fn();
  check("OpenCode Go still offers Monthly", store.get("ms-window")._innerHTML.includes("Monthly"));
}

console.log("--- panes match the Swift build ---");
state.pane = "widgets";
render();
check("widgets: no Charts-row setting", !html().includes("includes-charts"));
state.pane = "about";
render();
const about = html();
for (const card of ["Updates", "What it does", "Data sources", "Links"]) {
  check(`about: has the ${card} card`, about.includes(`<h2>${card}</h2>`));
}
check("about: hero names the app", about.includes("BurnRate</strong>"));
check("about: links open through the command", (about.match(/data-open=/g) ?? []).length === 2);
const linkRows = about.slice(about.indexOf("<h2>Links</h2>"));
check("about: both link rows have an svg icon", (linkRows.match(/<svg class="row-glyph"/g) ?? []).length === 2);
check("about: no icon severity ramp", !about.includes("Icon severity"));
check("about: shows the updater state", about.includes("up to date (1.0.0)"));
check(
  "about: offers no install when there is no update",
  !about.includes("install-update")
);
// The pane is the updater's only surface, so it has to offer the install when
// one exists — and say which version, so a stale offer is visible.
snapshot.updateAvailable = "1.1.0";
snapshot.updateState = "1.1.0 is available";
render();
const withUpdate = html();
check(
  "about: offers to install an available update",
  withUpdate.includes('id="install-update"') && withUpdate.includes("Install 1.1.0"),
  withUpdate.slice(withUpdate.indexOf("<h2>Updates</h2>"), withUpdate.indexOf("<h2>What")).slice(0, 300)
);
check("about: names the available version in the state line", withUpdate.includes("1.1.0 is available"));
// A platform that cannot replace itself points at the release page instead.
snapshot.canInstallUpdate = false;
snapshot.updateAvailable = null;
snapshot.updateState = "up to date (1.0.0)";
render();
check(
  "about: a platform that cannot self-install links the release page",
  html().includes("releases/latest")
);
snapshot.canInstallUpdate = true;

console.log("--- sidebar ---");
state.pane = "usage";
render();
const sidebar = store.get("pane-list")._innerHTML;
check("every sidebar item has an svg icon", (sidebar.match(/<svg class="glyph"/g) ?? []).length === 4);
check("widgets item is named as in Swift", sidebar.includes("Menu Bar Widgets"));
check("no count badges", !sidebar.includes('class="count"'));
check("no brand sub-line", !html().includes("menu bar</span>"));

console.log("--- scroll survives a refresh ---");
render();
store.get("content").scrollTop = 420;
render();
check("offset is restored after a re-render", store.get("content").scrollTop === 420, String(store.get("content").scrollTop));
check(
  "offset survives the short-page clamp (restore runs after the charts draw)",
  store.get("content").scrollTop === 420,
  String(store.get("content").scrollTop)
);

console.log("--- reload wiring ---");
state.snapshot = null;
await reload();
check("reload loads a snapshot", state.snapshot !== null);
check("reload renders it", html().length > 0);

console.log(failures ? `\n${failures} FAILURE(S)` : "\nall checks passed");
process.exit(failures ? 1 : 0);
