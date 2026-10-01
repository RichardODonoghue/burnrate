// Presentation primitives shared by the panes.

import { esc } from "./dom.js";

export const REPO_SLUG = "RichardODonoghue/burnrate";
export const REPO_URL = `https://github.com/${REPO_SLUG}`;
export const ISSUES_URL = `${REPO_URL}/issues`;
/** The newest release, where a platform that cannot self-install sends you. */
export const RELEASES_URL = `${REPO_URL}/releases/latest`;

/** A card surface. */
export function card(title: string, body: string, extra = ""): string {
  return `<section class="card">${title ? `<h2>${esc(title)}</h2>` : ""}${body}${extra}</section>`;
}

/**
 * A card whose title row also carries controls on the right, for the trend
 * chart's window picker.
 */
export function cardWithControls(title: string, controls: string, body: string): string {
  return `<section class="card">
    <div class="card-head">
      <h2>${esc(title)}</h2>
      ${controls}
    </div>
    ${body}
  </section>`;
}

/** One option in a segmented control: a bare string, or a value/label pair. */
export interface Segment {
  value: string;
  label: string;
}

/**
 * A segmented picker, as a button group.
 *
 * A connected run of buttons with the selection lit — not a menu, so not a
 * `<select>`. `totalWidth` fixes the group's width, because a control that
 * reflows as options change reads
 * as a layout bug.
 */
export function segmented(
  id: string,
  options: readonly (string | Segment)[],
  selected: string,
  totalWidth = 0
): string {
  const width = totalWidth ? ` style="width:${totalWidth}px"` : "";
  return `<div class="segmented" id="${id}" role="group"${width}>${options
    .map((option) => {
      const value = typeof option === "string" ? option : option.value;
      const label = typeof option === "string" ? option : option.label;
      const state = value === selected ? ' class="on" aria-pressed="true"' : ' aria-pressed="false"';
      return `<button type="button" data-value="${esc(value)}"${state}>${esc(label)}</button>`;
    })
    .join("")}</div>`;
}
