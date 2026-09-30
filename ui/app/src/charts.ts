// Chart geometry.
//
// The numbers that matter — domains, ticks, axis labels, annotations, totals —
// are computed in Rust (`burnrate-core::charts`) and arrive pre-formatted. This
// file maps values to pixels and strokes paths, and nothing else. The first
// version did its own arithmetic and formatting, and that is precisely how the
// axes and labels drifted from the Swift build.
//
// The one exception is `Math.round` on a hovered percentage.

import { dayLabel } from "./format.js";
import { esc } from "./dom.js";
import { modelColour, providerColour } from "./store.js";
import type { Dashboard, Padding, Projector } from "./types.js";

/** A box in pixel space mapped onto the data domain. */
interface ProjectorSpec {
  width: number;
  height: number;
  pad: Padding;
  xDomain: readonly [number, number];
  yDomain: readonly [number, number];
}

/**
 * `pad` keeps a value at exactly 0% / 100% off the plot edge, because a flush
 * mark is half-clipped by the frame and reads as the line leaving the graph.
 */
export function projector(spec: ProjectorSpec): Projector {
  const [xLow, xHigh] = spec.xDomain;
  const [yLow, yHigh] = spec.yDomain;
  const xSpan = Math.max(1e-9, xHigh - xLow);
  const ySpan = Math.max(1e-9, yHigh - yLow);
  const plotWidth = Math.max(1, spec.width - spec.pad.left - spec.pad.right);
  const plotHeight = Math.max(1, spec.height - spec.pad.top - spec.pad.bottom);
  return {
    x: (value) => spec.pad.left + ((value - xLow) / xSpan) * plotWidth,
    y: (value) => spec.pad.top + plotHeight - ((value - yLow) / ySpan) * plotHeight,
    left: spec.pad.left,
    right: spec.width - spec.pad.right,
    top: spec.pad.top,
    bottom: spec.height - spec.pad.bottom,
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
export function textWidth(text: string): number {
  return text.length * 6.2;
}

/** The widest of a set of labels, or `""`. */
function widest(labels: readonly string[]): string {
  return labels.reduce((longest, label) => (label.length >= longest.length ? label : longest), "");
}

/** Padding sized so the Y labels fit outside the plot on the right. */
function yAxisPad(labels: readonly string[], bottom: number): Padding {
  return { top: 6, right: 8 + textWidth(widest(labels)), bottom, left: 10 };
}

/**
 * Places a tooltip inside its chart frame.
 *
 * `left` was set straight from the pointer, so a tooltip near the right edge
 * rendered past the card and over whatever was beside it. This flips the tooltip
 * to the other side of its anchor when it would overflow, then clamps — a flip
 * alone is not enough at the very edges, where neither side fits.
 */
export function placeTooltip(
  tip: HTMLElement,
  frame: HTMLElement,
  anchorX: number,
  anchorY: number
): void {
  const frameWidth = frame.clientWidth || 0;
  const frameHeight = frame.clientHeight || 0;
  const tipWidth = tip.offsetWidth || 0;
  const tipHeight = tip.offsetHeight || 0;
  const gap = 10;

  let left = anchorX + gap;
  if (left + tipWidth > frameWidth) {
    left = anchorX - gap - tipWidth;
  }
  left = Math.max(0, Math.min(left, Math.max(0, frameWidth - tipWidth)));

  let top = anchorY - tipHeight / 2;
  top = Math.max(0, Math.min(top, Math.max(0, frameHeight - tipHeight)));

  tip.style.left = `${Math.round(left)}px`;
  tip.style.top = `${Math.round(top)}px`;
}

/** Middle truncation, as the Swift legend's `.truncationMode(.middle)`. */
export function middleTruncate(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const head = Math.ceil((limit - 1) / 2);
  const tail = Math.floor((limit - 1) / 2);
  return `${text.slice(0, head)}…${text.slice(text.length - tail)}`;
}

/** The point closest to `at` on a series, by binary search. */
export function nearestPoint(
  points: readonly { x: number; y: number }[],
  at: number
): { x: number; y: number } | null {
  if (!points.length) return null;
  let low = 0;
  let high = points.length - 1;
  while (low < high) {
    const mid = (low + high) >> 1;
    const point = points[mid] as { x: number };
    if (point.x < at) low = mid + 1;
    else high = mid;
  }
  const candidate = points[low] as { x: number; y: number };
  if (low > 0) {
    const previous = points[low - 1] as { x: number; y: number };
    if (Math.abs(previous.x - at) < Math.abs(candidate.x - at)) return previous;
  }
  return candidate;
}

/** A pixel-space point, as `[x, y]`. */
type Px = [number, number];

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
export function monotonePath(points: readonly Px[]): string {
  const count = points.length;
  if (count === 0) return "";
  const first = points[0] as Px;
  if (count === 1) return `M${first[0].toFixed(1)} ${first[1].toFixed(1)}`;

  const dx: number[] = [];
  const delta: number[] = [];
  for (let i = 0; i < count - 1; i += 1) {
    const a = points[i] as Px;
    const b = points[i + 1] as Px;
    dx[i] = b[0] - a[0];
    delta[i] = dx[i] === 0 ? 0 : (b[1] - a[1]) / dx[i];
  }
  const slope: number[] = new Array(count);
  slope[0] = delta[0] as number;
  slope[count - 1] = delta[count - 2] as number;
  for (let i = 1; i < count - 1; i += 1) {
    const before = delta[i - 1] as number;
    const after = delta[i] as number;
    if (before * after <= 0) {
      slope[i] = 0;
    } else {
      const w1 = 2 * (dx[i] as number) + (dx[i - 1] as number);
      const w2 = (dx[i] as number) + 2 * (dx[i - 1] as number);
      slope[i] = (w1 + w2) / (w1 / before + w2 / after);
    }
  }
  let path = `M${first[0].toFixed(1)} ${first[1].toFixed(1)}`;
  for (let i = 0; i < count - 1; i += 1) {
    const a = points[i] as Px;
    const b = points[i + 1] as Px;
    const step = dx[i] as number;
    const c1x = a[0] + step / 3;
    const c1y = a[1] + ((slope[i] as number) * step) / 3;
    const c2x = b[0] - step / 3;
    const c2y = b[1] - ((slope[i + 1] as number) * step) / 3;
    path +=
      ` C${c1x.toFixed(1)} ${c1y.toFixed(1)} ${c2x.toFixed(1)} ${c2y.toFixed(1)}` +
      ` ${b[0].toFixed(1)} ${b[1].toFixed(1)}`;
  }
  return path;
}

/**
 * Thins a series to a point budget while keeping each bucket's extremes, so the
 * envelope and the resets survive. Thirty days of polls is thousands of points
 * per provider, and the shape of a step is exactly what a naive stride drops.
 */
export function decimate(points: readonly Px[], budget = 600): Px[] {
  if (points.length <= budget) return [...points];
  const bucket = Math.ceil(points.length / (budget / 2));
  const out: Px[] = [];
  for (let i = 0; i < points.length; i += bucket) {
    let low = points[i] as Px;
    let high = points[i] as Px;
    for (let j = i; j < Math.min(i + bucket, points.length); j += 1) {
      const point = points[j] as Px;
      if (point[1] < low[1]) low = point;
      if (point[1] > high[1]) high = point;
    }
    if (low[0] <= high[0]) {
      out.push(low, high);
    } else {
      out.push(high, low);
    }
  }
  const last = points[points.length - 1] as Px;
  if (out[out.length - 1] !== last) out.push(last);
  return out;
}

/** A vertical gridline with its label outside the plot. */
function yGrid(map: Projector, labels: readonly string[], ticks: readonly number[]): string {
  return ticks
    .map((value, index) => {
      const y = map.y(value).toFixed(1);
      return `<line class="grid" x1="${map.left}" y1="${y}" x2="${map.right.toFixed(1)}" y2="${y}"/>
        <text class="tick" x="${(map.right + 6).toFixed(1)}" y="${(map.y(value) + 3.5).toFixed(
          1
        )}">${esc(labels[index] ?? "")}</text>`;
    })
    .join("");
}

// ---------------------------------------------------------------- trend chart

function trendSvg(dashboard: Dashboard, width: number): string {
  const height = 180;
  const yLabels = dashboard.yTicks.map((value) => `${Math.round(value)}%`);
  // The Y labels sit outside the plot on the right, so the padding has to fit the
  // widest of them — a fixed padding let cost labels run off the frame.
  const pad = yAxisPad(yLabels, 24);
  const map = projector({
    width,
    height,
    pad,
    xDomain: dashboard.xDomain,
    yDomain: dashboard.yDomain,
  });

  // X gridlines for every tick, but only the labels that fit.
  //
  // Swift Charts thins axis labels that would collide; drawing all of them is
  // what makes this axis a smear — a 30-day span produces 60 ticks (midnight and
  // noon per day), which is one label every ~12px in a 700px plot. The lines
  // stay, so the reader still sees the intervals.
  let lastRight = -Infinity;
  const xMarks = dashboard.xTicks
    .map((tick) => {
      const x = map.x(tick.at);
      const line = `<line class="grid" x1="${x.toFixed(1)}" y1="${pad.top}"
        x2="${x.toFixed(1)}" y2="${map.bottom.toFixed(1)}"/>`;
      const label = esc(tick.label);
      const half = textWidth(label) / 2;
      // The first and last labels must not run past the plot.
      if (x - half < map.left || x + half > map.right) return line;
      if (x - half < lastRight + 8) return line;
      lastRight = x + half;
      return `${line}<text class="tick mid" x="${x.toFixed(1)}"
        y="${(height - 7).toFixed(1)}">${label}</text>`;
    })
    .join("");

  const lines = dashboard.series
    .map((line) => {
      const points = decimate(
        line.points.map((point): Px => [map.x(point.x), map.y(point.y)])
      );
      const dash = line.scoped ? ' stroke-dasharray="6 4"' : "";
      const colour = providerColour(line.provider);
      const opacity = line.scoped ? 0.55 : 1;
      // One sample is a moveto and draws nothing at all. A single poll is the
      // normal state for the first five minutes after launch, and an empty chart
      // is not what "one reading" should look like.
      if (points.length === 1) {
        const [x, y] = points[0] as Px;
        return `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="2.5"
                fill="${colour}" opacity="${opacity}"/>`;
      }
      return `<path d="${monotonePath(points)}" fill="none"
              stroke="${colour}" stroke-width="2"
              stroke-linecap="round" stroke-linejoin="round"
              opacity="${opacity}"${dash}/>`;
    })
    .join("");

  // The selected-time rule, as the Swift chart's `RuleMark`. Drawn once and moved
  // on hover, rather than redrawing the chart under the cursor.
  const rule = `<line class="rule" id="trend-rule" x1="0" y1="${pad.top}"
      x2="0" y2="${map.bottom.toFixed(1)}" visibility="hidden"/>`;

  return `<svg class="chart" id="trend" viewBox="0 0 ${width} ${height}"
      width="${width}" height="${height}" role="img"
      aria-label="Remaining usage over time">
    ${yGrid(map, yLabels, dashboard.yTicks)}${xMarks}${lines}${rule}
  </svg>`;
}

// ---------------------------------------------------------------- daily chart

function dailySvg(dashboard: Dashboard, width: number): string {
  const height = 220;
  const yLabels = dashboard.dailyYLabels;
  const pad = yAxisPad(yLabels, 24);
  const top = Math.max(dashboard.dailyMaximum, 1);
  const map = projector({
    width,
    height,
    pad,
    xDomain: [0, dashboard.daily.length],
    yDomain: [0, top],
  });

  const slot = map.plotWidth / Math.max(1, dashboard.daily.length);
  const barWidth = Math.max(2, Math.min(38, slot - 3));

  const bars = dashboard.daily
    .map((day, index) => {
      const x = map.left + index * slot + (slot - barWidth) / 2;
      let offset = 0;
      const stack = day.bars
        .map((bar) => {
          const barHeight = (bar.value / top) * map.plotHeight;
          const y = map.bottom - offset - barHeight;
          offset += barHeight;
          return `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}"
            width="${barWidth.toFixed(1)}" height="${Math.max(1, barHeight).toFixed(1)}"
            rx="2" fill="${modelColour(bar.key)}"/>`;
        })
        .join("");
      // The transparent full-height rect is the hover target for the whole column.
      return `<g class="day" data-day="${day.day}" data-x="${x.toFixed(1)}"
          data-slot="${slot.toFixed(1)}">${stack}
          <rect x="${(map.left + index * slot).toFixed(1)}" y="${pad.top}"
            width="${slot.toFixed(1)}" height="${map.plotHeight.toFixed(1)}"
            fill="transparent"/>
        </g>`;
    })
    .join("");

  // Day labels: first, middle and last only, so they never collide.
  const lastIndex = dashboard.daily.length - 1;
  const marks = dashboard.daily
    .map((day, index) => {
      if (index !== 0 && index !== lastIndex && index !== Math.floor(dashboard.daily.length / 2)) {
        return "";
      }
      const x = map.left + index * slot + slot / 2;
      return `<text class="tick mid" x="${x.toFixed(1)}" y="${(height - 7).toFixed(1)}">${esc(
        dayLabel(day.day)
      )}</text>`;
    })
    .join("");

  return `<svg class="chart" id="daily" viewBox="0 0 ${width} ${height}"
      width="${width}" height="${height}" role="img"
      aria-label="Daily usage by model">${yGrid(map, yLabels, dashboard.dailyYTicks)}${bars}${marks}</svg>`;
}

// -------------------------------------------------------------- ranking chart

function rankingSvg(dashboard: Dashboard, width: number): string {
  const rows = dashboard.ranking;
  const rowHeight = 34;
  const tokens = dashboard.metric === "tokens";
  const pad: Padding = {
    top: 6,
    right: tokens ? 76 : 66,
    bottom: tokens ? 24 : 8,
    left: 148,
  };
  // The height has to include both paddings. It was `rows * rowHeight + 10`,
  // which ignored them, so with a 24px bottom pad the bars ran straight through
  // the value axis and its labels — the overlap, not a spacing tweak.
  const height = pad.top + rows.length * rowHeight + pad.bottom;
  const top = Math.max(...rows.map((row) => row.value), 1);
  const map = projector({ width, height, pad, xDomain: [0, top], yDomain: [0, 1] });

  // The value axis is drawn for tokens only, as in `ModelsView`: eight bars do
  // not need a dollar scale under them.
  const grid = tokens
    ? dashboard.rankingTicks
        .map((value, index) => {
          const x = map.x(value).toFixed(1);
          return `<line class="grid" x1="${x}" y1="${pad.top}" x2="${x}" y2="${map.bottom.toFixed(
            1
          )}"/>
            <text class="tick mid" x="${x}" y="${(height - 7).toFixed(1)}">${esc(
              dashboard.rankingTickLabels[index] ?? ""
            )}</text>`;
        })
        .join("")
    : "";

  const barHeight = 18;
  const bars = rows
    .map((row, index) => {
      const y = pad.top + index * rowHeight + (rowHeight - barHeight) / 2;
      const barWidth = Math.max(2, (row.value / top) * map.plotWidth);
      return `<g class="rank" data-key="${esc(row.key)}" data-y="${(y + barHeight / 2).toFixed(1)}">
        <title>${esc(row.label)}</title>
        <text class="rank-name" x="${(map.left - 8).toFixed(1)}"
          y="${(y + barHeight - 4).toFixed(1)}">${esc(middleTruncate(row.label, 22))}</text>
        <rect x="${map.left.toFixed(1)}" y="${y.toFixed(1)}"
          width="${barWidth.toFixed(1)}" height="${barHeight}" rx="3"
          fill="${modelColour(row.key)}"/>
        <text class="rank-value" x="${(map.left + barWidth + 7).toFixed(1)}"
          y="${(y + barHeight - 4).toFixed(1)}">${esc(row.annotation)}</text>
      </g>`;
    })
    .join("");

  return `<svg class="chart" id="ranking" viewBox="0 0 ${width} ${height}"
      width="${width}" height="${height}" role="img"
      aria-label="Top models">${grid}${bars}</svg>`;
}

/** Draws the named chart into its plot frame at the frame's measured width. */
export function drawChart(kind: "trend" | "daily" | "ranking", dashboard: Dashboard): void {
  const plot = document.getElementById(`${kind}-plot`);
  if (!plot) return;
  const measured = Math.round(plot.clientWidth || plot.parentElement?.clientWidth || 760);
  const width = Math.max(320, measured);
  const build = kind === "trend" ? trendSvg : kind === "daily" ? dailySvg : rankingSvg;
  plot.innerHTML = build(dashboard, width);
}
