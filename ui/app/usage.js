// The Usage pane: the Swift `ModelsView`, section for section —
// toolbar (in app.js), three snapshot cards, Remaining over time, Daily usage by
// model, Top models, Breakdown.
//
// Two rules keep this honest, both learned from getting them wrong.
//
// 1. **No number is formatted here.** Domains, ticks, axis labels, annotations
//    and totals all arrive pre-formatted in the snapshot, and this file maps
//    values to pixels. The first version did its own arithmetic and formatting,
//    and that is precisely how the axes and labels drifted from the Swift build.
//    The one exception is `Math.round` on a hovered percentage.
//
// 2. **Charts are drawn at their real pixel width**, not scaled by a viewBox. A
//    scaled SVG stretches the axis text non-uniformly, so the chart looks wrong
//    at every window size except the one it was designed at. `layoutUsage`
//    measures, draws, and redraws on resize.

let deps = {};
const E = (value) => deps.esc(value);
const T = (value) => deps.tokenCount(value);

window.BurnRate = window.BurnRate || {};
Object.assign(window.BurnRate, { configure, renderUsage, layoutUsage, wireUsage });

function configure(shared) {
  deps = shared;
}

/** A card surface, the Swift `Card`. */
function card(title, body, extra = "") {
  return `<section class="card">${title ? `<h2>${E(title)}</h2>` : ""}${body}${extra}</section>`;
}

/**
 * A card whose title row also carries controls on the right — the Swift
 * `HStack { Text(title); Spacer(); Picker }` for the trend chart.
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

function providerColour(provider) {
  return deps.providerColours?.[provider] ?? "var(--accent)";
}

function modelColour(model) {
  return deps.modelColours?.[model] ?? "var(--accent)";
}

/**
 * Maps a chart box in the given pixel space onto the data domain.
 * `pad` keeps a value at exactly 0% / 100% off the plot edge, because a flush
 * mark is half-clipped by the frame and reads as the line leaving the graph.
 */
function projector({ width, height, pad, xDomain, yDomain }) {
  const [xLow, xHigh] = xDomain;
  const [yLow, yHigh] = yDomain;
  const xSpan = Math.max(1e-9, xHigh - xLow);
  const ySpan = Math.max(1e-9, yHigh - yLow);
  const plotWidth = Math.max(1, width - pad.left - pad.right);
  const plotHeight = Math.max(1, height - pad.top - pad.bottom);
  return {
    x: (value) => pad.left + ((value - xLow) / xSpan) * plotWidth,
    y: (value) => pad.top + plotHeight - ((value - yLow) / ySpan) * plotHeight,
    left: pad.left,
    right: width - pad.right,
    top: pad.top,
    bottom: height - pad.bottom,
    plotWidth,
    plotHeight,
  };
}

/**
 * Rough advance width of a label at the chart's 10px tick size.
 *
 * Axis padding is measured from the longest label, and the only way to know how
 * wide a string will be before the browser lays it out is to estimate. It is used
 * for spacing only — never to decide whether a value fits inside the plot, which
 * is why a small error here is harmless.
 */
function textWidth(text) {
  return text.length * 6.2;
}

/** Middle truncation, as the Swift legend's `.truncationMode(.middle)`. */
function middleTruncate(text, limit) {
  if (text.length <= limit) return text;
  const head = Math.ceil((limit - 1) / 2);
  const tail = Math.floor((limit - 1) / 2);
  return `${text.slice(0, head)}…${text.slice(text.length - tail)}`;
}

/** The point closest to `at` on a series, by binary search. */
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

/**
 * Monotone cubic interpolation (Fritsch–Carlson), which is what
 * `.interpolationMethod(.monotone)` draws: cubic, but clamped so the curve never
 * overshoots the points it passes through.
 *
 * Linear is not a substitute for a vendor series — the line is a flat run then a
 * step down at a reset, and the eye reads the steps as events. A plain spline
 * overshoots at every step, and an overshoot on a remaining-percent chart means
 * drawing above 100% or below 0%.
 */
function monotonePath(points) {
  const count = points.length;
  if (count === 0) return "";
  if (count === 1) return `M${points[0][0].toFixed(1)} ${points[0][1].toFixed(1)}`;
  const dx = [];
  const delta = [];
  for (let i = 0; i < count - 1; i += 1) {
    dx[i] = points[i + 1][0] - points[i][0];
    delta[i] = dx[i] === 0 ? 0 : (points[i + 1][1] - points[i][1]) / dx[i];
  }
  const slope = new Array(count);
  slope[0] = delta[0];
  slope[count - 1] = delta[count - 2];
  for (let i = 1; i < count - 1; i += 1) {
    if (delta[i - 1] * delta[i] <= 0) {
      slope[i] = 0;
    } else {
      const w1 = 2 * dx[i] + dx[i - 1];
      const w2 = dx[i] + 2 * dx[i - 1];
      slope[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i]);
    }
  }
  let path = `M${points[0][0].toFixed(1)} ${points[0][1].toFixed(1)}`;
  for (let i = 0; i < count - 1; i += 1) {
    const c1x = points[i][0] + dx[i] / 3;
    const c1y = points[i][1] + (slope[i] * dx[i]) / 3;
    const c2x = points[i + 1][0] - dx[i] / 3;
    const c2y = points[i + 1][1] - (slope[i + 1] * dx[i]) / 3;
    path +=
      ` C${c1x.toFixed(1)} ${c1y.toFixed(1)} ${c2x.toFixed(1)} ${c2y.toFixed(1)}` +
      ` ${points[i + 1][0].toFixed(1)} ${points[i + 1][1].toFixed(1)}`;
  }
  return path;
}

/**
 * Thins a series to a point budget while keeping each bucket's extremes, so the
 * envelope and the resets survive. Seven days of 5-minute polls is ~2000 points
 * per provider, and the shape of a step is exactly what a naive stride drops.
 */
function decimate(points, budget = 600) {
  if (points.length <= budget) return points;
  const bucket = Math.ceil(points.length / (budget / 2));
  const out = [];
  for (let i = 0; i < points.length; i += bucket) {
    let low = points[i];
    let high = points[i];
    for (let j = i; j < Math.min(i + bucket, points.length); j += 1) {
      if (points[j][1] < low[1]) low = points[j];
      if (points[j][1] > high[1]) high = points[j];
    }
    if (low[0] <= high[0]) {
      out.push(low, high);
    } else {
      out.push(high, low);
    }
  }
  const last = points[points.length - 1];
  if (out[out.length - 1] !== last) out.push(last);
  return out;
}

// ---------------------------------------------------------------- trend chart

function trendSvg(dashboard, width) {
  const height = 180;
  // The Y labels sit outside the plot on the right, so the padding has to fit the
  // widest of them. Cost labels ("$0.858455") are far wider than "100%", and a
  // fixed padding let them run off the SVG in cost mode.
  const yLabels = dashboard.yTicks.map((value) => `${Math.round(value)}%`);
  const pad = {
    top: 6,
    right: 8 + textWidth(yLabels.reduce((a, b) => (a.length >= b.length ? a : b), "")),
    bottom: 24,
    left: 10,
  };
  const map = projector({
    width,
    height,
    pad,
    xDomain: dashboard.xDomain,
    yDomain: dashboard.yDomain,
  });

  const grid = dashboard.yTicks
    .map(
      (value, index) =>
        `<line class="grid" x1="${map.left}" y1="${map.y(value).toFixed(1)}"
           x2="${map.right.toFixed(1)}" y2="${map.y(value).toFixed(1)}"/>
         <text class="tick" x="${(map.right + 6).toFixed(1)}"
           y="${(map.y(value) + 3.5).toFixed(1)}">${E(yLabels[index])}</text>`
    )
    .join("");

  // X gridlines for every tick, but only the labels that fit.
  //
  // Swift Charts thins axis labels that would collide; drawing all of them is
  // what makes this axis a smear — a 30-day span produces 60 ticks (midnight and
  // noon per day), which is one label every ~12px in a 700px plot. The lines
  // stay, so the reader still sees the intervals.
  const xMarks = (() => {
    let lastRight = -Infinity;
    return dashboard.xTicks
      .map((tick) => {
        const x = map.x(tick.at);
        const line = `<line class="grid" x1="${x.toFixed(1)}" y1="${pad.top}"
          x2="${x.toFixed(1)}" y2="${map.bottom.toFixed(1)}"/>`;
        const label = E(tick.label);
        // 6.2px per character at this font size, plus breathing room, and the
        // first and last labels must not run past the plot.
        const half = textWidth(label) / 2;
        if (x - half < map.left || x + half > map.right) return line;
        if (x - half < lastRight + 8) return line;
        lastRight = x + half;
        return `${line}<text class="tick mid" x="${x.toFixed(1)}"
          y="${(height - 7).toFixed(1)}">${label}</text>`;
      })
      .join("");
  })();

  const lines = dashboard.series
    .map((line) => {
      const points = decimate(
        line.points.map((point) => [map.x(point.x), map.y(point.y)])
      );
      const dash = line.scoped ? ' stroke-dasharray="6 4"' : "";
      const colour = providerColour(line.provider);
      const opacity = line.scoped ? 0.55 : 1;
      // One sample is a moveto and draws nothing at all. A single poll is the
      // normal state for the first five minutes after launch, and an empty chart
      // is not what "one reading" should look like.
      if (points.length === 1) {
        const [x, y] = points[0];
        return `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5"
                fill="${colour}" opacity="${opacity}"/>`;
      }
      return `<path d="${monotonePath(points)}" fill="none"
              stroke="${colour}" stroke-width="2"
              stroke-linecap="round" stroke-linejoin="round"
              opacity="${opacity}"${dash}/>`;
    })
    .join("");

  // The selected-time rule, as the Swift chart's `RuleMark`. Drawn once and
  // moved on hover, rather than redrawing the chart under the cursor.
  const rule = `<line class="rule" id="trend-rule" x1="0" y1="${pad.top}"
      x2="0" y2="${map.bottom.toFixed(1)}" visibility="hidden"/>`;

  return `<svg class="chart" id="trend" viewBox="0 0 ${width} ${height}"
      width="${width}" height="${height}" role="img"
      aria-label="Remaining usage over time">
    ${grid}${xMarks}${lines}${rule}
  </svg>`;
}

// ---------------------------------------------------------------- daily chart

function dailySvg(dashboard, width) {
  const height = 220;
  const yLabels = (dashboard.dailyYLabels ?? []).map((label) => String(label));
  const pad = {
    top: 6,
    right: 8 + textWidth(yLabels.reduce((a, b) => (a.length >= b.length ? a : b), "")),
    bottom: 24,
    left: 10,
  };
  const top = Math.max(dashboard.dailyMaximum ?? 0, 1);
  const map = projector({
    width,
    height,
    pad,
    xDomain: [0, dashboard.daily.length],
    yDomain: [0, top],
  });

  const grid = dashboard.dailyYTicks
    .map(
      (value, index) =>
        `<line class="grid" x1="${map.left}" y1="${map.y(value).toFixed(1)}"
           x2="${map.right.toFixed(1)}" y2="${map.y(value).toFixed(1)}"/>
         <text class="tick" x="${(map.right + 6).toFixed(1)}"
           y="${(map.y(value) + 3.5).toFixed(1)}">${E(yLabels[index] ?? "")}</text>`
    )
    .join("");

  const slot = map.plotWidth / Math.max(1, dashboard.daily.length);
  const barWidth = Math.max(2, Math.min(38, slot - 3));

  const bars = dashboard.daily
    .map((day, index) => {
      const x = map.left + index * slot + (slot - barWidth) / 2;
      // Today is not over. Beside complete days a part-day reads as a cliff, so
      // it is drawn faded — the day is there, it is simply not finished.
      const opacity = day.partial ? 0.5 : 1;
      let offset = 0;
      const stack = day.bars
        .map((bar) => {
          const barHeight = (bar.value / top) * map.plotHeight;
          const y = map.bottom - offset - barHeight;
          offset += barHeight;
          return `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}"
            width="${barWidth.toFixed(1)}" height="${Math.max(1, barHeight).toFixed(1)}"
            rx="2" fill="${modelColour(bar.key)}" opacity="${opacity}"/>`;
        })
        .join("");
      return `<g class="day" data-day="${day.day}" data-x="${x.toFixed(1)}"
          data-slot="${slot.toFixed(1)}">${stack}
          <rect x="${(map.left + index * slot).toFixed(1)}" y="${pad.top}"
            width="${slot.toFixed(1)}" height="${map.plotHeight.toFixed(1)}"
            fill="transparent"/>
        </g>`;
    })
    .join("");

  // Day labels: first, middle and last only, so they never collide.
  const last = dashboard.daily.length - 1;
  const marks = dashboard.daily
    .map((day, index) => {
      if (index !== 0 && index !== last && index !== Math.floor(dashboard.daily.length / 2)) {
        return "";
      }
      const x = map.left + index * slot + slot / 2;
      return `<text class="tick mid" x="${x.toFixed(1)}" y="${(height - 7).toFixed(
        1
      )}">${E(dayLabel(day.day))}</text>`;
    })
    .join("");

  return `<svg class="chart" id="daily" viewBox="0 0 ${width} ${height}"
      width="${width}" height="${height}" role="img"
      aria-label="Daily usage by model">${grid}${bars}${marks}</svg>`;
}

/**
 * A day bucket's date. `day` is the epoch of *local* midnight, so the local
 * fields of that instant are the day — reading UTC fields instead would show
 * yesterday for anyone east of Greenwich.
 */
function dayLabel(day) {
  return new Date(day * 1000).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

/** A day bucket's date with its weekday, for the daily tooltip header. */
function dayHeading(day) {
  return new Date(day * 1000).toLocaleDateString(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
}

// -------------------------------------------------------------- ranking chart

function rankingSvg(dashboard, width) {
  const rows = dashboard.ranking;
  const rowHeight = 34;
  const tokens = dashboard.metric === "tokens";
  const pad = { top: 6, right: tokens ? 76 : 66, bottom: tokens ? 24 : 8, left: 148 };
  // The height has to include both paddings. It was `rows * rowHeight + 10`,
  // which ignored them, so with a 24px bottom pad the bars ran straight through
  // the value axis and its labels — the overlap, not a spacing tweak.
  const height = pad.top + rows.length * rowHeight + pad.bottom;
  const top = Math.max(...rows.map((row) => row.value), 1);
  const map = projector({
    width,
    height,
    pad,
    xDomain: [0, top],
    yDomain: [0, 1],
  });

  // The value axis is drawn for tokens only, as in `ModelsView`: eight bars do
  // not need a dollar scale under them.
  const grid = tokens
    ? dashboard.rankingTicks
        .map(
          (value, index) =>
            `<line class="grid" x1="${map.x(value).toFixed(1)}" y1="${pad.top}"
               x2="${map.x(value).toFixed(1)}" y2="${map.bottom.toFixed(1)}"/>
             <text class="tick mid" x="${map.x(value).toFixed(1)}"
               y="${(height - 7).toFixed(1)}">${E(
              dashboard.rankingTickLabels?.[index] ?? ""
            )}</text>`
        )
        .join("")
    : "";

  const barHeight = 18;
  const bars = rows
    .map((row, index) => {
      const y = pad.top + index * rowHeight + (rowHeight - barHeight) / 2;
      const barWidth = Math.max(2, (row.value / top) * map.plotWidth);
      const label = middleTruncate(row.label, 22);
      return `<g class="rank" data-key="${E(row.key)}" data-y="${(y + barHeight / 2).toFixed(1)}">
        <title>${E(row.label)}</title>
        <text class="rank-name" x="${(map.left - 8).toFixed(1)}"
          y="${(y + barHeight - 4).toFixed(1)}">${E(label)}</text>
        <rect x="${map.left.toFixed(1)}" y="${y.toFixed(1)}"
          width="${barWidth.toFixed(1)}" height="${barHeight}" rx="3"
          fill="${modelColour(row.key)}"/>
        <text class="rank-value" x="${(map.left + barWidth + 7).toFixed(1)}"
          y="${(y + barHeight - 4).toFixed(1)}">${E(row.annotation)}</text>
      </g>`;
    })
    .join("");

  return `<svg class="chart" id="ranking" viewBox="0 0 ${width} ${height}"
      width="${width}" height="${height}" role="img"
      aria-label="Top models">${grid}${bars}</svg>`;
}

// ------------------------------------------------------------------- legends

function trendLegend(dashboard) {
  return `<div class="legend">${dashboard.series
    .map(
      (line) =>
        `<span class="key"><i class="dot" style="background:${providerColour(
          line.provider
        )};opacity:${line.scoped ? 0.55 : 1}"></i>${E(line.name)}</span>`
    )
    .join("")}</div>`;
}

/**
 * The daily chart's own wrapping legend, as `ModelsView.modelLegend`.
 *
 * The automatic chart legend was hidden there because long model names — local
 * MLX models especially — overflowed the card. Fixed-width columns, middle
 * truncation, full name on hover.
 */
function dailyLegend(dashboard) {
  const models = [
    ...new Set(dashboard.daily.flatMap((day) => day.bars.map((bar) => bar.key))),
  ].sort();
  if (!models.length) return "";
  return `<div class="model-legend">${models
    .map(
      (model) =>
        `<span class="key" title="${E(model)}"><i class="dot" style="background:${modelColour(
          model
        )}"></i>${E(middleTruncate(model, 26))}</span>`
    )
    .join("")}</div>`;
}

// -------------------------------------------------------------- snapshot cards

function snapshotCards(dashboard) {
  const rolling = dashboard.rolling.length
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
  return `<div class="cards">
    ${card("Rolling usage", rolling)}
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
  </div>`;
}

// ------------------------------------------------------------ breakdown table

const BREAKDOWN_COLUMNS = [
  "MODEL",
  "INPUT",
  "OUTPUT",
  "CACHE",
  "REQUESTS",
  "TOKENS",
  "COST",
];

function breakdownTable(dashboard) {
  if (!dashboard.table.length) {
    return `<p class="hint">Nothing to break down in this range.</p>`;
  }
  const head = BREAKDOWN_COLUMNS.map(
    (title) => `<span class="th">${title}</span>`
  ).join("");
  const rows = dashboard.table
    .map(
      (bar) => `<div class="tr">
        <span class="td model" title="${E(bar.label)}">
          <i class="dot" style="background:${modelColour(bar.key)}"></i>
          <span class="model-name">${E(bar.label)}</span>
          <span class="provider">${E(bar.provider)}</span>
        </span>
        <span class="td">${E(T(bar.input))}</span>
        <span class="td">${E(T(bar.output))}</span>
        <span class="td">${E(T(bar.cache))}</span>
        <span class="td">${bar.requests}</span>
        <span class="td strong">${E(T(bar.tokens))}</span>
        <span class="td strong">${bar.cost > 0 ? `$${bar.cost.toFixed(2)}` : "—"}</span>
      </div>`
    )
    .join("");
  return `<div class="table"><div class="tr head">${head}</div>${rows}</div>`;
}

// ------------------------------------------------------------------ the pane

function renderUsage(snapshot) {
  const { dashboard } = snapshot;
  // `filteredDaily.isEmpty` in the Swift view: no entries for this filter in the
  // whole 30 days, which is not the same as an empty chart series — the trend
  // history outlives the model history.
  if (!dashboard.hasData) {
    return `<div class="empty">
      <span class="empty-glyph">▤</span>
      <strong>No usage data</strong>
      <p class="hint">Usage appears here once the local logs contain data.</p>
    </div>`;
  }
  const monthlyNote =
    dashboard.windowLabel === "Monthly"
      ? `<p class="hint note"><span class="glyph">ⓘ</span>Claude has no monthly limit — its windows are 5-hour and weekly.</p>`
      : "";
  const windowPicker = deps.segmented(
    "window-group",
    dashboard.windowLabels,
    dashboard.windowLabel,
    // `max(labels, 3) * 86`, per the Swift view's `.frame(width:)`, so the
    // control keeps its size as options come and go rather than reflowing.
    Math.max(dashboard.windowLabels.length, 3) * 86
  );
  return [
    snapshotCards(dashboard),
    cardWithControls(
      `Remaining over time — ${dashboard.windowLabel}`,
      windowPicker,
      `${monthlyNote}
      <div class="chart-frame" id="trend-frame">
        <div class="plot" id="trend-plot"></div>
        <div class="tooltip" id="trend-tip" hidden></div>
      </div>
      ${trendLegend(dashboard)}`
    ),
    card(
      `Daily usage by model (${dashboard.metricLabel})`,
      `<div class="chart-frame" id="daily-frame">
        <div class="plot" id="daily-plot"></div>
        <div class="tooltip" id="daily-tip" hidden></div>
      </div>
      ${dailyLegend(dashboard)}`
    ),
    card(
      `Top models (${dashboard.rangeLabel})`,
      `<div class="chart-frame" id="ranking-frame">
        <div class="plot" id="ranking-plot"></div>
        <div class="tooltip" id="ranking-tip" hidden></div>
      </div>`
    ),
    card(`Breakdown (${dashboard.rangeLabel})`, breakdownTable(dashboard)),
  ].join("");
}

/**
 * Measures each chart and draws it at that width. Called after every render and
 * on resize, because the frames have no width until they are in the document.
 */
function layoutUsage(snapshot) {
  if (!snapshot?.dashboard?.hasData) return;
  const dashboard = snapshot.dashboard;
  const draw = (plotId, build) => {
    const plot = deps.el?.(plotId) ?? document.getElementById(plotId);
    if (!plot) return;
    const measured = Math.round(plot.clientWidth || plot.parentElement?.clientWidth || 760);
    const width = Math.max(320, measured);
    plot.innerHTML = build(dashboard, width);
  };
  draw("trend-plot", trendSvg);
  draw("daily-plot", dailySvg);
  draw("ranking-plot", rankingSvg);
}

// ---------------------------------------------------------------- interactions

function wireUsage(snapshot) {
  if (!snapshot?.dashboard?.hasData) return;
  const dashboard = snapshot.dashboard;
  const el = (id) => deps.el?.(id) ?? document.getElementById(id);

  // The window picker is a segmented button group, as in Swift's Picker.
  for (const button of (el("window-group")?.querySelectorAll("button") ?? [])) {
    button.addEventListener("click", () => deps.selectWindow(button.dataset.value));
  }

  const frameTip = (plotId, tipId) => {
    const plot = el(plotId);
    const tip = el(tipId);
    if (!plot || !tip) return null;
    return { plot, tip };
  };

  // --- trend: a rule under the cursor and the nearest reading per series ---
  const trend = frameTip("trend-plot", "trend-tip");
  if (trend) {
    const svg = el("trend");
    const rule = el("trend-rule");
    const [xLow, xHigh] = dashboard.xDomain;
    trend.plot.addEventListener("mousemove", (event) => {
      const box = trend.plot.getBoundingClientRect();
      if (!box.width) return;
      const ratio = Math.min(1, Math.max(0, (event.clientX - box.left) / box.width));
      const at = Math.round(xLow + ratio * (xHigh - xLow));
      const rows = dashboard.series
        .map((line) => {
          const point = nearestPoint(line.points, at);
          if (!point) return null;
          return {
            name: line.name,
            provider: line.provider,
            scoped: line.scoped,
            remaining: point.y,
            at: point.x,
          };
        })
        .filter(Boolean);
      if (!rows.length) {
        trend.tip.hidden = true;
        return;
      }
      const stamp = rows.reduce((best, row) =>
        Math.abs(row.at - at) < Math.abs(best.at - at) ? row : best
      ).at;
      trend.tip.innerHTML =
        `<div class="tip-head">${E(
          new Date(stamp * 1000).toLocaleString(undefined, {
            weekday: "short",
            hour: "numeric",
            minute: "2-digit",
          })
        )}</div>` +
        rows
          .map(
            (row) =>
              `<div class="tip-row"><i class="dot" style="background:${providerColour(
                row.provider
              )};opacity:${row.scoped ? 0.55 : 1}"></i><span class="grow">${E(
                row.name
              )}</span><span class="value">${Math.round(row.remaining)}%</span></div>`
          )
          .join("");
      trend.tip.hidden = false;
      const x = (rows.reduce((best, row) =>
        Math.abs(row.at - at) < Math.abs(best.at - at) ? row : best
      ).at - xLow) / (xHigh - xLow);
      trend.tip.style.left = `${x * box.width}px`;
      if (rule && svg) {
        rule.setAttribute("x1", String(x * box.width));
        rule.setAttribute("x2", String(x * box.width));
        rule.setAttribute("visibility", "visible");
      }
    });
    trend.plot.addEventListener("mouseleave", () => {
      trend.tip.hidden = true;
      rule?.setAttribute("visibility", "hidden");
    });
  }

  // --- daily: the hovered column's models, then the day's total ---
  const daily = frameTip("daily-plot", "daily-tip");
  if (daily) {
    daily.plot.addEventListener("mousemove", (event) => {
      const group = event.target.closest?.(".day");
      if (!group) {
        daily.tip.hidden = true;
        return;
      }
      const day = dashboard.daily.find((entry) => entry.day === Number(group.dataset.day));
      if (!day) {
        daily.tip.hidden = true;
        return;
      }
      const rows = day.bars.map(
        (bar) =>
          `<div class="tip-row"><i class="dot" style="background:${modelColour(
            bar.key
          )}"></i><span class="grow">${E(bar.label)}</span><span class="value">${E(
            bar.valueText
          )}</span></div>`
      );
      const total =
        day.bars.length > 1
          ? `<div class="tip-total"><span class="grow">Total</span><span class="value">${E(
              day.totalText
            )}</span></div>`
          : "";
      daily.tip.innerHTML =
        `<div class="tip-head">${E(dayHeading(day.day))}${
          day.partial ? " · in progress" : ""
        }</div>${rows.join("")}${total}`;
      daily.tip.hidden = false;
      const ratio = (Number(group.dataset.x) + Number(group.dataset.slot) / 2) /
        (daily.plot.clientWidth || 1);
      daily.tip.style.left = `${ratio * (daily.plot.clientWidth || 0)}px`;
    });
    daily.plot.addEventListener("mouseleave", () => {
      daily.tip.hidden = true;
    });
  }

  // --- ranking: hovered model's detail ---
  const ranking = frameTip("ranking-plot", "ranking-tip");
  if (ranking) {
    ranking.plot.addEventListener("mousemove", (event) => {
      const group = event.target.closest?.(".rank");
      if (!group) {
        ranking.tip.hidden = true;
        return;
      }
      const row = dashboard.ranking.find((bar) => bar.key === group.dataset.key);
      if (!row) {
        ranking.tip.hidden = true;
        return;
      }
      const reasoning =
        row.reasoning > 0
          ? `<div class="tip-row sub"><span class="grow">Reasoning</span><span class="value">${E(
              T(row.reasoning)
            )}</span></div>`
          : "";
      ranking.tip.innerHTML =
        `<div class="tip-head"><i class="dot" style="background:${modelColour(
          row.key
        )}"></i><strong>${E(row.label)}</strong></div>
         <div class="tip-head sub">${E(row.provider)}</div>
         <div class="tip-row"><span class="grow">${E(dashboard.metric === "tokens" ? "Tokens" : "Cost")}</span><span class="value">${E(
          row.valueText
        )}</span></div>
         <div class="tip-row sub"><span class="grow">Requests</span><span class="value">${
           row.requests
         }</span></div>
         ${reasoning}`;
      ranking.tip.hidden = false;
      ranking.tip.style.left = `${ranking.plot.clientWidth}px`;
      ranking.tip.style.top = `${group.dataset.y}px`;
    });
    ranking.plot.addEventListener("mouseleave", () => {
      ranking.tip.hidden = true;
    });
  }
}
