// The IPC surface, typed.
//
// Every call into Rust goes through here, so the command names and argument
// shapes are in one place. `invoke("snapshot", { range })` used to be a string
// with an untyped bag: a typo in the command name or an argument was silent.
//
// Once specta generates bindings this file becomes a thin re-export, and the
// argument names come from the Rust signatures.

import type { Snapshot, Settings, UpdateStatus } from "./types.js";

interface TauriInternals {
  invoke<T>(command: string, args?: Record<string, unknown>): Promise<T>;
}

/**
 * The bridge Tauri installs on the global object.
 *
 * Read off `globalThis` rather than `window` so the test harness — which is Node,
 * with no `window` — can install the same stub.
 */
function bridge(): TauriInternals {
  const internals = (globalThis as { __TAURI_INTERNALS__?: TauriInternals })
    .__TAURI_INTERNALS__;
  if (!internals) {
    throw new Error("no Tauri IPC bridge; this page is not running under Tauri");
  }
  return internals;
}

export function invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  return bridge().invoke<T>(command, args);
}

/** The whole window payload, for the current view state. */
export interface SnapshotQuery {
  pane: string;
  range: string;
  metric: string;
  windowLabel?: string | undefined;
  providerFilter: string | null;
}

export const api = {
  snapshot: (query: SnapshotQuery): Promise<Snapshot> => invoke("snapshot", { ...query }),
  knownProviders: (): Promise<string[]> => invoke("known_providers"),
  settingsFilePath: (): Promise<string> => invoke("settings_file_path"),
  modelColours: (): Promise<Record<string, string>> => invoke("model_colours"),
  appIconDataUrl: (edge: number): Promise<string> => invoke("app_icon_data_url", { edge }),
  refreshNow: (): Promise<void> => invoke("refresh_now"),
  openUrl: (url: string): Promise<void> => invoke("open_url", { url }),
  testNotification: (): Promise<string> => invoke("send_test_notification"),
  checkForUpdates: (): Promise<UpdateStatus> => invoke("check_for_updates"),
  installUpdate: (): Promise<void> => invoke("install_update"),

  upsertMilestone: (provider: string, windowLabel: string, step: number): Promise<void> =>
    invoke("upsert_milestone", { provider, windowLabel, step }),
  removeMilestone: (provider: string, windowLabel: string): Promise<void> =>
    invoke("remove_milestone", { provider, windowLabel }),
  upsertBurnAlert: (
    provider: string,
    windowLabel: string,
    percentDrop: number,
    minutes: number
  ): Promise<void> =>
    invoke("upsert_burn_alert", { provider, windowLabel, percentDrop, minutes }),
  removeBurnAlert: (provider: string, windowLabel: string): Promise<void> =>
    invoke("remove_burn_alert", { provider, windowLabel }),
  upsertCostAlert: (provider: string, dailyLimitUsd: number): Promise<void> =>
    invoke("upsert_cost_alert", { provider, dailyLimitUsd }),
  toggleWidget: (provider: string): Promise<void> => invoke("toggle_widget", { provider }),
  setNotifyOnReset: (enabled: boolean): Promise<void> =>
    invoke("set_notify_on_reset", { enabled }),
  saveSettings: (settings: Settings): Promise<Settings> => invoke("save_settings", { settings }),
};
