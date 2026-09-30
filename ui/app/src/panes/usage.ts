// The Usage pane: the Swift `ModelsView`, section for section — three snapshot
// cards, Remaining over time, Daily usage by model, Top models, Breakdown.
//
// Two rules keep this honest, both learned from getting them wrong.
//
// 1. **No number is formatted here.** Domains, ticks, axis labels, annotations and
//    totals arrive pre-formatted in the snapshot, and this file maps values to
//    pixels. The one exception is `Math.round` on a hovered percentage.
//
// 2. **Charts are drawn at their real pixel width**, not scaled by a viewBox. A
//    scaled SVG stretches the axis text non-uniformly, so the chart looks wrong at
//    every window size except the one it was designed at. `layout` measures,
//    draws, and redraws on resize.

import { drawChart, nearestPoint, placeTooltip } from "../charts.js";
import { esc, el, on } from "../dom.js";
import { dayHeading, tokenCount } from "../format.js";
import { card, cardWithControls, segmented } from "../ui.js";
import { modelColour, providerColour } from "../store.js";
import type { Bar, Dashboard, Snapshot } from "../types.js";

/** Supplied by the shell, so this module never imports the renderer back. */
export interface PaneContext {
  reload: () => void;
  selectWindow: (label: string) => void;
}

// -------------------------------------------------------------- snapshot cards

function snapshotCards(dashboard: Dashboard): string {
  const rolling = dashboard.rolling.length
    ? dashboard.rolling
        .map(
          (row) => `<div class="figure">
            <i class="dot" style="background:${providerColour(row.key)}"></i>
            <span class="grow">${esc(row.label)}</span>
            <span class="value">${esc(row.value)}</span>
          </div>`
        )
        .join("")
    : `<p class="hint">Collecting…</p>`;
  return `<div class="cards">
    ${card("Rolling usage", rolling)}
    ${card(
      "Tokens today",
      `<div class="big">${
        dashboard.tokensToday ? tokenCount(dashboard.tokensToday) : "—"
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

// ------------------------------------------------------------------- legends

function trendLegend(dashboard: Dashboard): string {
  return `<div class="legend">${dashboard.series
    .map(
      (line) =>
        `<span class="key"><i class="dot" style="background:${providerColour(
          line.provider
        )};opacity:${line.scoped ? 0.55 : 1}"></i>${esc(line.name)}</span>`
    )
    .join("")}</div>`;
}

/**
 * The daily chart's own wrapping legend, as `ModelsView.modelLegend`.
 *
 * The automatic chart legend was hidden there because long model names — local MLX
 * models especially — overflowed the card. Fixed-width columns, middle truncation,
 * full name on hover.
 */
function dailyLegend(dashboard: Dashboard): string {
  const models = [...new Set(dashboard.daily.flatMap((day) => day.bars.map((bar) => bar.key)))].sort();
  if (!models.length) return "";
  return `<div class="model-legend">${models
    .map(
      (model) =>
        `<span class="key" title="${esc(model)}"><i class="dot" style="background:${modelColour(
          model
        )}"></i>${esc(model.length > 26 ? `${model.slice(0, 13)}…${model.slice(-12)}` : model)}</span>`
    )
    .join("")}</div>`;
}

// ------------------------------------------------------------ breakdown table

const BREAKDOWN_COLUMNS = ["MODEL", "INPUT", "OUTPUT", "CACHE", "REQUESTS", "TOKENS", "COST"];

function breakdownTable(dashboard: Dashboard): string {
  if (!dashboard.table.length) {
    return `<p class="hint">Nothing to break down in this range.</p>`;
  }
  const head = BREAKDOWN_COLUMNS.map((title) => `<span class="th">${title}</span>`).join("");
  const rows = dashboard.table
    .map(
      (bar) => `<div class="tr">
        <span class="td model" title="${esc(bar.label)}">
          <i class="dot" style="background:${modelColour(bar.key)}"></i>
          <span class="model-name">${esc(bar.label)}</span>
          <span class="provider">${esc(bar.provider)}</span>
        </span>
        <span class="td">${esc(tokenCount(bar.input))}</span>
        <span class="td">${esc(tokenCount(bar.output))}</span>
        <span class="td">${esc(tokenCount(bar.cache))}</span>
        <span class="td">${bar.requests}</span>
        <span class="td strong">${esc(tokenCount(bar.tokens))}</span>
        <span class="td strong">${bar.cost > 0 ? `$${bar.cost.toFixed(2)}` : "—"}</span>
      </div>`
    )
    .join("");
  // A dash in the COST column means "no list price for this model", which is worth
  // saying out loud: the column is otherwise a silent row of dashes.
  const note = dashboard.unpricedModels.length
    ? `<p class="hint">No list price for ${dashboard.unpricedModels
        .map(esc)
        .join(", ")} — their cost shows as “—”.</p>`
    : "";
  return `<div class="table"><div class="tr head">${head}</div>${rows}</div>${note}`;
}

// ------------------------------------------------------------------ the pane

export function render(snapshot: Snapshot): string {
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
  const windowPicker = segmented(
    "window-group",
    dashboard.windowLabels,
    dashboard.windowLabel,
    // `max(labels, 3) * 86`, per the Swift view's `.frame(width:)`, so the control
    // keeps its size as options come and go rather than reflowing.
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
 * Measures each chart and draws it at that width. Called after every render and on
 * resize, because the frames have no width until they are in the document.
 */
export function layout(snapshot: Snapshot): void {
  if (!snapshot.dashboard.hasData) return;
  drawChart("trend", snapshot.dashboard);
  drawChart("daily", snapshot.dashboard);
  drawChart("ranking", snapshot.dashboard);
}

/** The tooltip pair for a chart, or `null` when the pane is not rendered. */
function frame(
  plotId: string,
  tipId: string
): { plot: HTMLElement; tip: HTMLElement } | null {
  const plot = el(plotId);
  const tip = el(tipId);
  return plot && tip ? { plot, tip } : null;
}

/** The bar under the cursor, from the nearest row on the trend chart. */
function nearestRows(dashboard: Dashboard, at: number) {
  return dashboard.series.flatMap((line) => {
    const point = nearestPoint(line.points, at);
    return point ? [{ line, at: point.x, remaining: point.y }] : [];
  });
}

/** The row closest in time, which is what the tooltip's header shows. */
function closestAt(rows: { at: number }[], at: number): number {
  return rows.reduce((best, row) => (Math.abs(row.at - at) < Math.abs(best.at - at) ? row : best)).at;
}

export function wire(snapshot: Snapshot, context: PaneContext): void {
  const dashboard = snapshot.dashboard;
  if (!dashboard.hasData) return;

  // The window picker is a segmented button group, as in Swift's Picker.
  for (const button of el("window-group")?.querySelectorAll("button") ?? []) {
    on(button, "click", () => {
      const label = (button as HTMLButtonElement).dataset.value;
      if (label) context.selectWindow(label);
    });
  }

  // --- trend: a rule under the cursor and the nearest reading per series ---
  const trend = frame("trend-plot", "trend-tip");
  if (trend) {
    const rule = el("trend-rule");
    const [xLow, xHigh] = dashboard.xDomain;
    on<MouseEvent>(trend.plot, "mousemove", (event) => {
      const box = trend.plot.getBoundingClientRect();
      if (!box.width) return;
      const ratio = Math.min(1, Math.max(0, (event.clientX - box.left) / box.width));
      const at = Math.round(xLow + ratio * (xHigh - xLow));
      const rows = nearestRows(dashboard, at);
      if (!rows.length) {
        trend.tip.hidden = true;
        return;
      }
      const stamp = closestAt(rows, at);
      trend.tip.innerHTML =
        `<div class="tip-head">${esc(
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
                row.line.provider
              )};opacity:${row.line.scoped ? 0.55 : 1}"></i><span class="grow">${esc(
                row.line.name
              )}</span><span class="value">${Math.round(row.remaining)}%</span></div>`
          )
          .join("");
      trend.tip.hidden = false;
      const x = (stamp - xLow) / (xHigh - xLow);
      placeTooltip(trend.tip, trend.plot, x * box.width, box.height / 2);
      rule?.setAttribute("x1", String(x * box.width));
      rule?.setAttribute("x2", String(x * box.width));
      rule?.setAttribute("visibility", "visible");
    });
    on(trend.plot, "mouseleave", () => {
      trend.tip.hidden = true;
      rule?.setAttribute("visibility", "hidden");
    });
  }

  // --- daily: the hovered column's models, then the day's total ---
  const daily = frame("daily-plot", "daily-tip");
  if (daily) {
    on<MouseEvent>(daily.plot, "mousemove", (event) => {
      const group =
        event.target instanceof Element ? event.target.closest<HTMLElement>(".day") : null;
      const day = group
        ? dashboard.daily.find((entry) => entry.day === Number(group.dataset.day))
        : undefined;
      if (!day) {
        daily.tip.hidden = true;
        return;
      }
      const rows = day.bars.map(
        (bar) =>
          `<div class="tip-row"><i class="dot" style="background:${modelColour(
            bar.key
          )}"></i><span class="grow">${esc(bar.label)}</span><span class="value">${esc(
            bar.valueText
          )}</span></div>`
      );
      const total =
        day.bars.length > 1
          ? `<div class="tip-total"><span class="grow">Total</span><span class="value">${esc(
              day.totalText
            )}</span></div>`
          : "";
      daily.tip.innerHTML = `<div class="tip-head">${esc(
        dayHeading(day.day)
      )}</div>${rows.join("")}${total}`;
      daily.tip.hidden = false;
      placeTooltip(
        daily.tip,
        daily.plot,
        Number(group?.dataset.x) + Number(group?.dataset.slot) / 2,
        (daily.plot.clientHeight || 0) / 2
      );
    });
    on(daily.plot, "mouseleave", () => {
      daily.tip.hidden = true;
    });
  }

  // --- ranking: hovered model's detail ---
  const ranking = frame("ranking-plot", "ranking-tip");
  if (ranking) {
    on<MouseEvent>(ranking.plot, "mousemove", (event) => {
      const group =
        event.target instanceof Element ? event.target.closest<HTMLElement>(".rank") : null;
      const row: Bar | undefined = group
        ? dashboard.ranking.find((bar) => bar.key === group.dataset.key)
        : undefined;
      if (!row) {
        ranking.tip.hidden = true;
        return;
      }
      const reasoning =
        row.reasoning > 0
          ? `<div class="tip-row sub"><span class="grow">Reasoning</span><span class="value">${esc(
              tokenCount(row.reasoning)
            )}</span></div>`
          : "";
      ranking.tip.innerHTML =
        `<div class="tip-head"><i class="dot" style="background:${modelColour(
          row.key
        )}"></i><strong>${esc(row.label)}</strong></div>
         <div class="tip-head sub">${esc(row.provider)}</div>
         <div class="tip-row"><span class="grow">${esc(
           dashboard.metric === "tokens" ? "Tokens" : "Cost"
         )}</span><span class="value">${esc(row.valueText)}</span></div>
         <div class="tip-row sub"><span class="grow">Requests</span><span class="value">${
           row.requests
         }</span></div>
         ${reasoning}`;
      ranking.tip.hidden = false;
      placeTooltip(
        ranking.tip,
        ranking.plot,
        ranking.plot.clientWidth || 0,
        Number(group?.dataset.y)
      );
    });
    on(ranking.plot, "mouseleave", () => {
      ranking.tip.hidden = true;
    });
  }
}
