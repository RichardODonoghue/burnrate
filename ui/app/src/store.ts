// Shared state and the two things that change it.
//
// Deliberately holds no rendering. `refresh` and `mutate` load or write and
// return; the caller re-renders. That is what keeps the module graph acyclic —
// panes import this, the shell imports the panes, and nothing points back the
// other way.

import { api } from "./api.js";
import { esc, toast } from "./dom.js";
import type { AppPane, Snapshot } from "./types.js";

export interface AppState {
  pane: AppPane;
  snapshot: Snapshot | null;
  /** Providers the app has detected, from `known_providers`. */
  providers: string[];
  settingsPath: string;
  modelColours: Record<string, string>;
  /** True while a settings write is in flight, so clicks cannot stack. */
  busy: boolean;
  // Chart controls, sent with every snapshot so the payload matches the view.
  // Labels are 24h / 7d / 30d, defaulting to 7d.
  range: string;
  metric: string;
  windowLabel: string | null;
  providerFilter: string | null;
}

export const state: AppState = {
  pane: "usage",
  snapshot: null,
  providers: [],
  settingsPath: "",
  modelColours: {},
  busy: false,
  range: "7d",
  metric: "tokens",
  windowLabel: null,
  providerFilter: null,
};

/** Provider colours, keyed by provider name. */
export const PROVIDER_COLOURS: Record<string, string> = {
  Claude: "rgb(217, 120, 87)",
  "OpenCode Go": "rgb(64, 140, 242)",
  OpenCode: "rgb(64, 140, 242)",
  Codex: "rgb(51, 173, 112)",
};

export function providerColour(provider: string): string {
  return PROVIDER_COLOURS[provider] ?? "var(--accent)";
}

/** The palette comes from Rust so every platform agrees on a model's colour. */
export function modelColour(model: string): string {
  return state.modelColours[model] ?? "var(--accent)";
}

/**
 * Providers whose quota has no monthly window.
 *
 * Only a fallback: the options are normally read from the provider's own windows
 * in the snapshot. Claude reports Rolling/Weekly (plus the model-scoped Fable),
 * and the usage pane says as much in words — "Claude has no monthly limit".
 * Offering a Monthly rule for it produced a rule that could never fire.
 */
const PROVIDERS_WITHOUT_MONTHLY = new Set(["Claude"]);

const WINDOW_LABELS = ["Rolling", "Weekly", "Monthly"];

/**
 * The window labels a provider can actually be alerted on.
 *
 * Taken from the provider's reported windows so the list cannot drift from what
 * the notifier matches on; the hardcoded fallback is only for a provider that has
 * not been detected yet.
 */
export function windowLabelsFor(provider: string): string[] {
  const reported =
    state.snapshot?.usage.find((entry) => entry.providerName === provider)?.windows ?? [];
  if (reported.length) {
    return reported.map((window) => window.label);
  }
  return PROVIDERS_WITHOUT_MONTHLY.has(provider) ? ["Rolling", "Weekly"] : WINDOW_LABELS;
}

/** The `<option>` list for a window select. */
export function windowOptions(provider: string): string {
  // Escaped because these labels are not all ours: a Claude model-scoped window
  // is labelled with the vendor API's `scope.model.display_name`, and this lands
  // in `innerHTML`. Everything else rendered from the snapshot is escaped for the
  // same reason; this one was not.
  return windowLabelsFor(provider)
    .map((label) => `<option>${esc(label)}</option>`)
    .join("");
}

/**
 * Loads the snapshot and everything that travels with it.
 *
 * Does not render: the caller decides when, which is what lets the shell restore
 * the scroll offset after the charts have been drawn rather than before.
 */
export async function refresh(): Promise<void> {
  const [snapshot, providers, modelColours] = await Promise.all([
    api.snapshot({
      pane: state.pane,
      range: state.range,
      metric: state.metric,
      windowLabel: state.windowLabel ?? undefined,
      providerFilter: state.providerFilter,
    }),
    api.knownProviders(),
    api.modelColours(),
  ]);
  state.snapshot = snapshot;
  state.providers = providers;
  state.settingsPath = snapshot.settingsPath;
  state.modelColours = modelColours;
}

/**
 * Runs a settings write, reports the outcome, then reloads.
 *
 * Takes the call rather than a command name and an argument bag: with typed
 * wrappers in `api`, the argument names and shapes are checked at the call site
 * instead of being a string and an object literal.
 */
export async function mutate(
  action: () => Promise<unknown>,
  message?: string
): Promise<void> {
  if (state.busy) return;
  state.busy = true;
  try {
    await action();
    if (message) toast(message);
  } catch (error) {
    toast(String(error));
  } finally {
    state.busy = false;
  }
}
