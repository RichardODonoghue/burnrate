// The Usage pane, laid out as the Swift ModelsView is: toolbar, three snapshot
// cards, remaining-over-time, daily usage by model, top models, breakdown table.
//
// Every number, domain and tick arrives pre-computed in the snapshot. This file
// only maps x/y to pixels — the first version of this pane did its own
// arithmetic, and the axes drifted from the Swift build as a result.

/** A plain meter, the shape the Swift build's `Card` content used. */
function card(title, body, extra = "") {
  return `<section class="card">${title ? `<h2>${E(title)}</h2>` : ""}${body}${extra}</section>`;
}

/**
 * A card whose title row also carries controls on the right, the shape the Swift
 * build uses for the trend chart: `HStack { Text(title); Spacer(); Picker }`.
 */
function cardWithControls(title, controls, body) {
  return `<section class="card">
    <div class="card-head">
      <h2>${E(title)}</h2>
      ${controls}
    </div>
    ${body}
  </section>`;
}

// Injected by app.js: {providerColours, modelColours, tokenCount, esc}.
let deps = {};
const E = (value) => deps.esc(value);
const T = (value) => deps.tokenCount(value);
function configure(shared) {
  deps = shared;
}

Object.assign(window.BurnRate, { configure, renderUsage });

/** Provider colour, matching `SettingsView.color(for:)`. */
function providerColour(provider) {
  return deps.providerColours?.[provider] ?? "var(--accent)";
}

/**
 * Maps a chart box in the given pixel space onto the data domain.
 * `pad` keeps data at exactly 0% / 100% off the plot edge, because a flush
 * mark is half-clipped by the frame and reads as the line leaving the graph.
 */
function projector({ width, height, pad, xDomain, yDomain, xTicks, yTicks }) {
  const [xLow, xHigh] = xDomain;
  const [yLow, yHigh] = yDomain;
  const xSpan = Math.max(1, xHigh - xLow);
  const ySpan = Math.max(0.0001, yHigh - yLow);
  const plotW = Math.max(1, width - pad.left - pad.right);
  const plotH = Math.max(1, height - pad.top - pad.bottom);
  return {
    x: (value) => pad.left + ((value - xLow) / xSpan) * plotW,
    y: (value) => pad.top + plotH - ((value - yLow) / ySpan) * plotH,
    left: pad.left,
    right: width - pad.right,
    top: pad.top,
    bottom: height - pad.bottom,
  };
}

/** The remaining-over-time chart: one line per provider, scoped ones dashed. */
function trendChart(dashboard) {
  const points = dashboard.series.reduce(
    (total, line) => total + line.points.length,
    0
  );
  if (points < 2) {
    return `<div class="empty empty-short">
      <p class="hint">Collecting history… this chart fills in as BurnRate polls,
      a point every 5 minutes.</p>
    </div>`;
  }

  const W = 760;
  const H = 180;
  const pad = { top: 6, right: 52, bottom: 22, left: 8 };
  const map = projector({
    width: W,
    height: H,
    pad,
    xDomain: dashboard.xDomain,
    yDomain: dashboard.yDomain,
  });

  const grid = dashboard.yTicks
    .map((value) => {
      const y = map.y(value).toFixed(1);
      return `<line class="grid" x1="${pad.left}" y1="${y}" x2="${map.right}" y2="${y}"/>
              <text class="tick" x="${(map.right + 5).toFixed(1)}" y="${y}">${Math.round(value)}%</text>`;
    })
    .join("");

  const xMarks = dashboard.xTicks
    .map((tick) => {
      const x = map.x(tick.at).toFixed(1);
      return `<line class="grid" x1="${x}" y1="${pad.top}" x2="${x}" y2="${map.bottom}"/>
              <text class="tick x" x="${x}" y="${(H - 6).toFixed(1)}">${E(tick.label)}</text>`;
    })
    .join("");

  const lines = dashboard.series
    .map((line) => {
      const colour = providerColour(line.provider);
      const path = line.points
        .map((point, index) => {
          const command = index === 0 ? "M" : "L";
          return `${command}${map.x(point.x).toFixed(1)} ${map.y(point.y).toFixed(1)}`;
        })
        .join(" ");
      const opacity = line.scoped ? 0.55 : 1;
      const dash = line.scoped ? ' stroke-dasharray="6 4"' : "";
      return `<path d="${path}" fill="none" stroke="${colour}" stroke-width="2"
              stroke-linecap="round" stroke-linejoin="round" opacity="${opacity}"${dash}/>`;
    })
    .join("");

  // Points are only hit-tested for the tooltip; they stay invisible.
  const targets = dashboard.series
    .map((line) =>
      line.points
        .map(
          (point) =>
            `<circle class="probe" data-series="${E(line.name)}" data-scoped="${
              line.scoped ? "1" : "0"
            }" data-provider="${E(line.provider)}" cx="${map.x(point.x).toFixed(1)}"
               cy="${map.y(point.y).toFixed(1)}" r="6"/>`
        )
        .join("")
    )
    .join("");

  return `<div class="chart-frame">
      <svg class="chart" viewBox="0 0 ${W} ${H}" id="trend" role="img"
           aria-label="Remaining usage over time">
        ${grid}${xMarks}${lines}${targets}
      </svg>
      <div class="tooltip" id="trend-tip" hidden></div>
    </div>
    <div class="legend">
      ${dashboard.series
        .map(
          (line) =>
            `<span class="key"><i class="dot" style="background:${providerColour(
              line.provider
            )};opacity:${line.scoped ? 0.55 : 1}"></i>${E(line.name)}</span>`
        )
        .join("")}
    </div>`;
}

/** Stacked daily bars, coloured by model, with a hover tooltip per day. */
function dailyChart(dashboard) {
  if (!dashboard.daily.length) {
    return `<p class="hint">No daily usage yet.</p>`;
  }
  const W = 760;
  const H = 220;
  const pad = { top: 6, right: 58, bottom: 22, left: 8 };
  const max = Math.max(
    dashboard.daily.reduce((top, day) => Math.max(top, day.total), 0),
    1
  );
  const yLow = 0;
  const yHigh = max;
  const xLow = 0;
  const xHigh = dashboard.daily.length;
  const map = projector({ width: W, height: H, pad, xDomain: [xLow, xHigh], yDomain: [yLow, yHigh] });

  const grid = dashboard.dailyYTicks
    .map((value) => {
      const y = map.y(value).toFixed(1);
      return `<line class="grid" x1="${pad.left}" y1="${y}" x2="${map.right}" y2="${y}"/>
              <text class="tick" x="${(map.right + 5).toFixed(1)}" y="${y}">${E(
                axisLabel(value, dashboard.metric)
              )}</text>`;
    })
    .join("");

  const slot = (map.right - map.left) / dashboard.daily.length;
  const barWidth = Math.max(2, Math.min(38, slot - 3));

  const bars = dashboard.daily
    .map((day, index) => {
      const x = map.left + index * slot + (slot - barWidth) / 2;
      // Today is not finished. Beside complete days a part-day reads as a
      // cliff, so it is drawn faded — the day is there, it is just not over.
      const opacity = day.partial ? 0.5 : 1;
      let offset = 0;
      const stack = day.bars
        .map((bar) => {
          const height = (bar.value / max) * (map.bottom - map.top);
          const y = map.bottom - offset - height;
          offset += height;
          return `<rect class="bar" x="${x.toFixed(1)}" y="${y.toFixed(1)}"
            width="${barWidth.toFixed(1)}" height="${Math.max(1, height).toFixed(1)}"
            rx="2" fill="${modelColour(bar.key)}" opacity="${opacity}"><title>${E(
            bar.label
          )}: ${E(axisLabel(bar.value, dashboard.metric))}</title></rect>`;
        })
        .join("");
      const label = dayLabel(day.day);
      const suffix = day.partial ? " (in progress)" : "";
      return `<g class="day" data-day="${day.day}" data-x="${x.toFixed(1)}">
          ${stack}
          <title>${E(label + suffix)}: ${E(axisLabel(day.total, dashboard.metric))}</title>
        </g>`;
    })
    .join("");

  // Day labels: first, middle and last only, so they never collide.
  const marks = dashboard.daily
    .map((day, index) => {
      if (
        index !== 0 &&
        index !== dashboard.daily.length - 1 &&
        index !== Math.floor(dashboard.daily.length / 2)
      ) {
        return "";
      }
      const x = map.left + index * slot + slot / 2;
      return `<text class="tick x" x="${x.toFixed(1)}" y="${(H - 6).toFixed(1)}">${E(
        dayLabel(day.day)
      )}</text>`;
    })
    .join("");

  const models = [...new Set(dashboard.daily.flatMap((day) => day.bars.map((bar) => bar.key)))].sort();

  return `<div class="chart-frame">
      <svg class="chart" viewBox="0 0 ${W} ${H}" id="daily" role="img"
           aria-label="Daily usage by model">${grid}${bars}${marks}</svg>
      <div class="tooltip" id="daily-tip" hidden></div>
    </div>
    <div class="legend wrap">
      ${models
        .map(
          (model) =>
            `<span class="key"><i class="dot" style="background:${modelColour(
              model
            )}"></i>${E(model)}</span>`
        )
        .join("")}
    </div>`;
}

/** Top models as horizontal bars, with the value annotated at the end. */
function rankingChart(dashboard) {
  if (!dashboard.ranking.length) {
    return `<p class="hint">No per-model usage in this range.</p>`;
  }
  const max = Math.max(...dashboard.ranking.map((bar) => bar.value), 1);
  return dashboard.ranking
    .map(
      (bar) => `<div class="rank-row">
        <span class="rank-name" title="${E(bar.label)}"><i class="dot" style="background:${modelColour(
        bar.key
      )}"></i>${E(bar.label)}</span>
        <span class="rank-track"><span class="rank-fill" style="width:${(
        (bar.value / max) * 100
      ).toFixed(1)}%;background:${modelColour(bar.key)}"></span></span>
        <span class="rank-value">${E(axisLabel(bar.value, dashboard.metric))}</span>
      </div>`
    )
    .join("");
}

/** The breakdown table: the Swift build's MODEL/INPUT/OUTPUT/CACHE/… columns. */
function breakdownTable(dashboard) {
  if (!dashboard.table.length) {
    return `<p class="hint">Nothing to break down in this range.</p>`;
  }
  const head = ["MODEL", "INPUT", "OUTPUT", "CACHE", "REQUESTS", "TOKENS", "COST"]
    .map((title) => `<span class="th">${title}</span>`)
    .join("");
  const rows = dashboard.table
    .map(
      (bar) => `<div class="tr">
        <span class="td model"><i class="dot" style="background:${modelColour(
        bar.key
      )}"></i>${E(bar.label)}<span class="provider">${E(bar.provider)}</span></span>
        <span class="td">${E(T(bar.tokens))}</span>
        <span class="td">—</span>
        <span class="td">—</span>
        <span class="td">${bar.requests}</span>
        <span class="td strong">${E(T(bar.tokens))}</span>
        <span class="td strong">${bar.cost > 0 ? `$${bar.cost.toFixed(2)}` : "—"}</span>
      </div>`
    )
    .join("");
  return `<div class="table"><div class="tr head">${head}</div>${rows}</div>`;
}

/** Axis label formatting, matching `ModelsView.axisLabel`. */
function rangeLabel(range) {
  return { today: "24h", week: "7d", month: "30d" }[range] ?? range;
}

/**
 * A day bucket's date. `day.day` is the epoch of *local* midnight, so the local
 * fields of that instant are the day — reading UTC fields instead would show
 * yesterday for anyone east of Greenwich.
 */
function dayLabel(day) {
  return new Date(day * 1000).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

function axisLabel(value, metric) {
  if (metric === "cost") {
    return value >= 1 ? `$${value.toFixed(0)}` : `$${value.toFixed(2)}`;
  }
  return T(Math.round(value));
}

/** Model colour, from the Rust palette so all platforms agree. */
function modelColour(model) {
  return deps.modelColours?.[model] ?? "var(--accent)";
}

/** The Swift `Picker(…).pickerStyle(.segmented)`, as a button group. */
function segmented(id, options, selected) {
  return `<div class="segmented" id="${id}" role="group">${options
    .map(
      (option) =>
        `<button type="button" data-value="${E(option)}"${
          option === selected ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"'
        }>${E(option)}</button>`
    )
    .join("")}</div>`;
}

function renderUsage(snapshot) {
  const { usage, dashboard } = snapshot;
  const parts = [];

  if (!usage.length) {
    parts.push(`<div class="empty">
      <strong>No usage data</strong>
      <p class="hint">Usage appears here once the local logs contain data.</p>
    </div>`);
  }

  // --- snapshot cards ---
  const rollingBody = dashboard.rolling.length
    ? dashboard.rolling
        .map(
          (row) => `<div class="figure">
            <i class="dot" style="background:${providerColour(row.key)}"></i>
            <span class="grow">${E(row.label)}</span>
            <span class="value">${E(row.value)}</span>
          </div>`
        )
        .join("")
    : `<p class="hint">Collecting…</p>`;
  parts.push(`<div class="cards">
    ${card(
      "Rolling usage",
      rollingBody
    )}
    ${card(
      "Tokens today",
      `<div class="big">${
        dashboard.tokensToday ? T(dashboard.tokensToday) : "—"
      }</div><p class="hint">${dashboard.requestsToday} requests</p>`
    )}
    ${card(
      "Cost today",
      `<div class="big">${
        dashboard.costToday > 0 ? `$${dashboard.costToday.toFixed(2)}` : "—"
      }</div><p class="hint">list-price estimate</p>`
    )}
  </div>`);

  // --- remaining over time ---
  // Title and window picker share a row, as in the Swift build. The control is a
  // button group rather than a <select>: the Swift Picker is segmented, and a
  // collapsed menu is a different control, not a restyled one.
  const monthlyNote =
    dashboard.windowLabel === "Monthly"
      ? `<p class="hint">Claude has no monthly limit — its windows are 5-hour and weekly.</p>`
      : "";
  parts.push(
    cardWithControls(
      `Remaining over time — ${dashboard.windowLabel}`,
      segmented("window-group", dashboard.windowLabels, dashboard.windowLabel),
      `${monthlyNote}${trendChart(dashboard)}`
    )
  );

  // --- daily, then top models, each full width, in the Swift order ---
  parts.push(card(`Daily usage by model (${dashboard.metric})`, dailyChart(dashboard)));
  parts.push(card(`Top models (${dashboard.rangeLabel})`, rankingChart(dashboard)));

  // --- breakdown ---
  parts.push(card(`Breakdown (${dashboard.rangeLabel})`, breakdownTable(dashboard)));

  return parts.join("");
}

