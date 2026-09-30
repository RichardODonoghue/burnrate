// The entry point. The only module with side effects on load, so the test harness
// can import everything else without booting the app.

import { api } from "./api.js";
import { el } from "./dom.js";
import { layoutCharts, reload } from "./shell.js";
import { state } from "./store.js";

export async function boot(): Promise<void> {
  // The app icon comes from the Rust renderer, not a file path: the bundled icons
  // live outside the served ui/app directory.
  const brand = el<HTMLImageElement>("brand-icon");
  if (brand) brand.src = await api.appIconDataUrl(56);

  await reload();

  // The shell's heartbeat is what drives the tick; mirror it here.
  window.setInterval(() => void reload(), 5000);

  // Charts are drawn for the measured pixel width, so they have to be redrawn when
  // that changes. Without this they keep the width they were first drawn at, and
  // every resize leaves the axis text stretched or the plot short.
  let resizeTimer: number | undefined;
  const content = el("content");
  if (content) {
    new ResizeObserver(() => {
      if (state.pane !== "usage" || !state.snapshot) return;
      clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(layoutCharts, 60);
    }).observe(content);
  }
}

void boot();
