// Icons, drawn rather than typed.
//
// Drawn rather than typed: Unicode glyphs depend on the font having them, and a
// missing one renders nothing at all. Each entry carries its own fill/stroke,
// because an outlined shape drawn with the group's `fill` becomes a solid blob.
//
// The name is a union rather than a string, so `ICONS.githb` is a compile error
// and a row cannot silently render an empty `<svg>`.

import type { AppPane } from "./types.js";

export type IconName =
  | "usage"
  | "notifications"
  | "widgets"
  | "about"
  | "gauge"
  | "bell"
  | "download"
  | "seal"
  | "drive"
  | "bubble"
  | "github";

const ICONS: Record<IconName, string> = {
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

/**
 * An `<svg>` wrapper around an icon's contents.
 *
 * Always an `<svg>`: the GitHub mark once went into a bare `<span>`, and a
 * `<path>` outside an `<svg>` draws nothing at all.
 */
function svg(className: string, name: IconName): string {
  return `<svg class="${className}" viewBox="0 0 18 18" aria-hidden="true">${ICONS[name]}</svg>`;
}

/** The sidebar's icon for a pane. */
export function paneIcon(name: AppPane): string {
  return svg("glyph", name);
}

/** An icon for a labelled row in the About pane. */
export function rowIcon(name: IconName): string {
  return svg("row-glyph", name);
}
